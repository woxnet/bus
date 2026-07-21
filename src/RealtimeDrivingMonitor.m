classdef RealtimeDrivingMonitor < handle
%REALTIMEDRIVINGMONITOR Bounded causal FIFO driving-event monitor.
    properties (SetAccess = private)
        IsRunning = false
        Config
        SamplesProcessed = 0
        EventsDetected = 0
        DataQualityEventsDetected = 0
        DuplicateSamples = 0
        MissingSamples = 0
        InvalidSamples = 0
        LateSamples = 0
        OverflowDropped = 0
        MaximumCallbackAgeMs = 0
        LastSequence = uint64(0)
        LatestSensorSample = []
        LatestVehicleSample = []
        LatestProcessedSample = []
        LatestEvent = []
        LatestDataQualityEvent = []
        StartedAt = NaT
        StoppedAt = NaT
        LastError = []
    end
    properties
        OnSample = []
        OnEventStarted = []
        OnEventCompleted = []
        OnWarning = []
        OnError = []
        OnStopped = []
    end
    properties (Access = private)
        Imu
        Calibration
        Timer
        LongitudinalFilter
        LateralFilter
        VerticalFilter
        YawRateFilter
        BrakingState
        AccelerationState
        LeftTurnState
        RightTurnState
        VerticalShockState
        SampleHistory
        EventHistory
        SampleHistoryIndex = 0
        SampleHistoryCount = 0
        EventHistoryIndex = 0
        EventHistoryCount = 0
        Recorder
        OwnsRecorder = false
        Dashboard
        StreamSessionId = uint64(0)
        FirstSequence = uint64(0)
        ConsecutiveErrors = 0
        VerticalCalmSamples = 0
        StaleSessionDropped = 0
        MonitorClock
    end
    methods
        function obj = RealtimeDrivingMonitor(imu, calibration, options)
            if nargin < 3, options = struct(); end
            config = getRealtimeDrivingConfig();
            if ~isstruct(options) || ~isscalar(options)
                error('IMU:InvalidRealtimeConfig', 'options must be a scalar struct.');
            end
            unknown = setdiff(fieldnames(options), fieldnames(config));
            if ~isempty(unknown), error('IMU:InvalidRealtimeConfig', 'Unknown option: %s.', unknown{1}); end
            fields = fieldnames(options);
            for index = 1:numel(fields), config.(fields{index}) = options.(fields{index}); end
            obj.Config = validateRealtimeDrivingConfig(config);
            obj.Imu = imu; obj.Calibration = calibration;
            obj.createComponents(); obj.reset();
        end

        function start(obj)
            if obj.IsRunning, error('IMU:RealtimeMonitorAlreadyRunning', 'Monitor is running.'); end
            assertImuRuntimeReady();
            validation = validateImuCalibration(obj.Calibration, ...
                'AllowSynthetic', obj.Config.AllowSyntheticCalibration);
            if ~validation.valid
                error('IMU:InvalidCalibrationFile', '%s', strjoin(validation.errors, ' '));
            end
            if string(obj.Calibration.metadata.imuUid) ~= string(obj.Imu.UID)
                error('IMU:CalibrationDeviceMismatch', 'Calibration UID does not match IMU.');
            end
            actualRate = 1000 / obj.Config.callbackPeriodMs;
            if abs(actualRate-obj.Config.sampleRateHz) > 1e-9
                error('IMU:RealtimeSampleRateMismatch', ...
                    'sampleRateHz and callbackPeriodMs are inconsistent.');
            end
            obj.reset(); obj.Imu.start(obj.Config.callbackPeriodMs);
            stats = obj.Imu.getCallbackStats();
            obj.StreamSessionId = uint64(stats.sessionId);
            obj.StartedAt = datetime('now','TimeZone','UTC');
            obj.MonitorClock = tic; obj.IsRunning = true;
            if obj.Config.enableRecording
                recorderOptions = struct('directory', obj.Config.recordingDirectory, ...
                    'callbackPeriodMs', obj.Config.callbackPeriodMs, ...
                    'maxPollSamples', obj.Config.maximumPollSamples, ...
                    'AllowSynthetic', obj.Config.AllowSyntheticCalibration);
                obj.Recorder = ImuSessionRecorder(obj.Imu,obj.Calibration,recorderOptions);
                obj.Recorder.startExternal(); obj.OwnsRecorder = true;
            end
            if obj.Config.enableLivePlot
                obj.Dashboard = RealtimeDrivingDashboard(obj); obj.Dashboard.open();
            end
            if obj.Config.UseTimer
                obj.Timer = timer('ExecutionMode','fixedSpacing', ...
                    'Period',obj.Config.pollPeriodSeconds,'BusyMode','drop', ...
                    'TimerFcn',@(~,~)obj.timerPoll());
                start(obj.Timer);
            end
        end

        function startManual(obj)
            original = obj.Config.UseTimer; obj.Config.UseTimer = false;
            cleanup = onCleanup(@()obj.restoreTimerOption(original));
            obj.start(); clear cleanup;
        end

        function poll(obj)
            if ~obj.IsRunning, return; end
            try
                stats = obj.Imu.getCallbackStats();
                if double(stats.overflowDropped) > obj.OverflowDropped
                    increment = double(stats.overflowDropped)-obj.OverflowDropped;
                    obj.OverflowDropped = double(stats.overflowDropped);
                    obj.recordQualityWarning(struct('type',"CALLBACK_OVERFLOW",'count',increment, ...
                        'total',obj.OverflowDropped));
                    if obj.Config.stopOnOverflow, obj.stop(); return; end
                end
                if double(stats.staleSessionDropped) > obj.StaleSessionDropped
                    obj.StaleSessionDropped = double(stats.staleSessionDropped);
                    obj.recordQualityWarning(struct('type',"STALE_SESSION_CALLBACK", ...
                        'total',obj.StaleSessionDropped));
                end
                samples = obj.Imu.drainCallbackSamples(obj.Config.maximumPollSamples);
                for index = 1:numel(samples)
                    if ~obj.IsRunning, break; end
                    obj.processSample(samples{index});
                end
                obj.ConsecutiveErrors = 0;
            catch exception
                obj.ConsecutiveErrors = obj.ConsecutiveErrors+1; obj.LastError = exception;
                obj.invokeCallback(obj.OnError, exception);
                if obj.ConsecutiveErrors >= obj.Config.maximumConsecutiveErrors
                    obj.stop();
                end
            end
        end

        function summary = stop(obj)
            if ~obj.IsRunning, summary = obj.getStats(); return; end
            obj.stopTimer();
            obj.finishActiveEvents("monitor_stop",0);
            stats = obj.Imu.getCallbackStats();
            recording = [];
            if obj.OwnsRecorder && ~isempty(obj.Recorder) && obj.Recorder.IsRecording
                recording = obj.Recorder.stopExternal(stats);
            end
            obj.Imu.stop(); obj.IsRunning = false;
            obj.StoppedAt = datetime('now','TimeZone','UTC');
            if ~isempty(obj.Dashboard), obj.Dashboard.close(); end
            summary = obj.getStats(); summary.recording = recording;
            obj.invokeCallback(obj.OnStopped, summary);
        end

        function reset(obj)
            if obj.IsRunning, error('IMU:RealtimeMonitorRunning', 'Stop before reset.'); end
            obj.SamplesProcessed=0; obj.EventsDetected=0;
            obj.DataQualityEventsDetected=0; obj.DuplicateSamples=0;
            obj.MissingSamples=0; obj.InvalidSamples=0; obj.LateSamples=0;
            obj.OverflowDropped=0; obj.StaleSessionDropped=0; obj.LastSequence=uint64(0);
            obj.MaximumCallbackAgeMs=0;
            obj.FirstSequence=uint64(0); obj.LatestSensorSample=[];
            obj.LatestVehicleSample=[]; obj.LatestProcessedSample=[]; obj.LatestEvent=[];
            obj.LatestDataQualityEvent=[];
            obj.StartedAt=NaT; obj.StoppedAt=NaT; obj.LastError=[];
            obj.ConsecutiveErrors=0; obj.VerticalCalmSamples=0;
            obj.resetProcessingState();
            sampleCapacity = max(1,ceil(obj.Config.historySeconds*obj.Config.sampleRateHz));
            obj.SampleHistory=cell(sampleCapacity,1); obj.SampleHistoryIndex=0;
            obj.SampleHistoryCount=0; obj.EventHistory=cell(obj.Config.eventHistoryLimit,1);
            obj.EventHistoryIndex=0; obj.EventHistoryCount=0;
        end

        function sample = latestProcessedSample(obj), sample=obj.LatestProcessedSample; end
        function events = getRecentEvents(obj,maxCount)
            if nargin<2, maxCount=obj.EventHistoryCount; end
            events=obj.orderedBuffer(obj.EventHistory,obj.EventHistoryCount,obj.EventHistoryIndex);
            if numel(events)>maxCount, events=events(end-maxCount+1:end); end
            events=obj.cellBufferToStruct(events);
        end
        function samples = getRecentSamples(obj,maxCount)
            if nargin<2, maxCount=obj.SampleHistoryCount; end
            samples=obj.orderedBuffer(obj.SampleHistory,obj.SampleHistoryCount,obj.SampleHistoryIndex);
            if numel(samples)>maxCount, samples=samples(end-maxCount+1:end); end
            samples=obj.cellBufferToStruct(samples);
        end
        function stats = getStats(obj)
            duration=0;
            if ~isnat(obj.StartedAt)
                endpoint=datetime('now','TimeZone','UTC');
                if ~isnat(obj.StoppedAt), endpoint=obj.StoppedAt; end
                duration=seconds(endpoint-obj.StartedAt);
            end
            frequency=0; if duration>0, frequency=obj.SamplesProcessed/duration; end
            stats=struct('isRunning',obj.IsRunning,'samplesProcessed',obj.SamplesProcessed, ...
                'eventsDetected',obj.EventsDetected, ...
                'dataQualityEventsDetected',obj.DataQualityEventsDetected, ...
                'duplicateSamples',obj.DuplicateSamples, ...
                'missingSamples',obj.MissingSamples,'invalidSamples',obj.InvalidSamples, ...
                'lateSamples',obj.LateSamples,'overflowDropped',obj.OverflowDropped, ...
                'maximumCallbackAgeMs',obj.MaximumCallbackAgeMs, ...
                'staleSessionDropped',obj.StaleSessionDropped,'lastSequence',obj.LastSequence, ...
                'averageFrequencyHz',frequency,'startedAt',obj.StartedAt,'stoppedAt',obj.StoppedAt, ...
                'sampleHistoryCount',obj.SampleHistoryCount, ...
                'eventHistoryCount',obj.EventHistoryCount,'lastError',obj.LastError);
        end

        function delete(obj)
            try
                obj.stop();
            catch exception
                warning('IMU:RealtimeCleanupFailed','%s',exception.message);
            end
            obj.stopTimer();
            if ~isempty(obj.Timer) && isvalid(obj.Timer), delete(obj.Timer); end
            if obj.Config.DisconnectImuOnDelete
                try
                    obj.Imu.disconnect();
                catch exception
                    warning('IMU:RealtimeDisconnectFailed','%s',exception.message);
                end
            end
        end
    end

    methods (Access = private)
        function createComponents(obj)
            filterOptions=struct('medianWindowSamples',obj.Config.medianWindowSamples, ...
                'outlierMadThreshold',obj.Config.outlierMadThreshold);
            args={obj.Config.sampleRateHz,obj.Config.lowPassCutoffHz,filterOptions};
            obj.LongitudinalFilter=RealtimeSignalFilter(args{:});
            obj.LateralFilter=RealtimeSignalFilter(args{:}); obj.VerticalFilter=RealtimeSignalFilter(args{:});
            obj.YawRateFilter=RealtimeSignalFilter(args{:});
            obj.BrakingState=RealtimeEventState("BRAKING_CANDIDATE",obj.Config);
            obj.AccelerationState=RealtimeEventState("ACCELERATION_CANDIDATE",obj.Config);
            obj.LeftTurnState=RealtimeEventState("TURN_LEFT_CANDIDATE",obj.Config);
            obj.RightTurnState=RealtimeEventState("TURN_RIGHT_CANDIDATE",obj.Config);
            obj.VerticalShockState=RealtimeEventState("VERTICAL_SHOCK_CANDIDATE",obj.Config);
        end
        function resetProcessingState(obj)
            components={obj.LongitudinalFilter,obj.LateralFilter,obj.VerticalFilter, ...
                obj.YawRateFilter,obj.BrakingState,obj.AccelerationState,obj.LeftTurnState, ...
                obj.RightTurnState,obj.VerticalShockState};
            for index=1:numel(components), components{index}.reset(); end
            obj.VerticalCalmSamples=0;
        end
        function processSample(obj,sensor)
            if uint64(sensor.sessionId)~=obj.StreamSessionId
                obj.InvalidSamples=obj.InvalidSamples+1; return;
            end
            sequence=uint64(sensor.sequenceNumber);
            if obj.LastSequence>0 && sequence<=obj.LastSequence
                obj.DuplicateSamples=obj.DuplicateSamples+1; return;
            end
            if obj.LastSequence>0 && sequence>obj.LastSequence+1
                missing=double(sequence-obj.LastSequence-1); obj.MissingSamples=obj.MissingSamples+missing;
                obj.finishActiveEvents("sequence_gap",missing); obj.resetProcessingState();
                if obj.Config.stopOnSequenceGap, obj.stop(); return; end
            end
            if obj.FirstSequence==0, obj.FirstSequence=sequence; end
            obj.LastSequence=sequence;
            if sensor.callbackAgeMs>obj.Config.maximumSampleAgeMs, obj.LateSamples=obj.LateSamples+1; end
            obj.MaximumCallbackAgeMs=max(obj.MaximumCallbackAgeMs,double(sensor.callbackAgeMs));
            vehicle=applyMountCalibration(sensor,obj.Calibration, ...
                'AllowSynthetic',obj.Config.AllowSyntheticCalibration);
            processed=obj.filterSample(vehicle);
            obj.LatestSensorSample=sensor; obj.LatestVehicleSample=vehicle;
            obj.LatestProcessedSample=processed; obj.SamplesProcessed=obj.SamplesProcessed+1;
            obj.updateEvents(processed); obj.appendSampleHistory(processed);
            if obj.OwnsRecorder && obj.Recorder.IsRecording
                obj.Recorder.appendSample(sensor,vehicle);
            end
            if ~isempty(obj.Dashboard), obj.Dashboard.update(processed); end
            obj.invokeCallback(obj.OnSample,processed);
        end
        function p=filterSample(obj,v)
            lo=obj.LongitudinalFilter.update(v.longitudinalAcceleration);
            la=obj.LateralFilter.update(v.lateralAcceleration);
            ve=obj.VerticalFilter.update(v.verticalAcceleration);
            ya=obj.YawRateFilter.update(v.yawRate);
            valid=lo.valid&&la.valid&&ve.valid&&ya.valid;
            outlier=lo.outlierReplaced||la.outlierReplaced||ve.outlierReplaced||ya.outlierReplaced;
            quality=1-0.30*double(v.callbackAgeMs>obj.Config.maximumSampleAgeMs) ...
                -0.20*double(outlier)-0.25*double(obj.MissingSamples>0) ...
                -0.25*double(obj.OverflowDropped>0);
            p=struct('source',"realtime",'sessionId',uint64(v.sessionId), ...
                'sequenceNumber',uint64(v.sequenceNumber),'hostTimestamp',v.hostTimestamp, ...
                'elapsedSeconds',double(uint64(v.sequenceNumber)-obj.FirstSequence)/obj.Config.sampleRateHz, ...
                'callbackAgeMs',double(v.callbackAgeMs),'longitudinalRaw',lo.raw, ...
                'longitudinalFiltered',lo.filtered,'longitudinalJerk',lo.derivative, ...
                'lateralRaw',la.raw,'lateralFiltered',la.filtered,'lateralJerk',la.derivative, ...
                'verticalRaw',ve.raw,'verticalFiltered',ve.filtered,'verticalJerk',ve.derivative, ...
                'yawRateRaw',ya.raw,'yawRateFiltered',ya.filtered,'temperature',double(v.temperature), ...
                'outlierReplaced',outlier,'dataValid',valid,'dataQuality',max(0,min(1,quality)), ...
                'overflowDroppedTotal',obj.OverflowDropped,'missingSamplesTotal',obj.MissingSamples);
            if ~valid, obj.InvalidSamples=obj.InvalidSamples+1; end
        end
        function updateEvents(obj,p)
            obj.updateState(obj.BrakingState,p,p.longitudinalFiltered<=obj.Config.brakingStartThreshold, ...
                p.longitudinalFiltered>=obj.Config.brakingStopThreshold);
            obj.updateState(obj.AccelerationState,p,p.longitudinalFiltered>=obj.Config.accelerationStartThreshold, ...
                p.longitudinalFiltered<=obj.Config.accelerationStopThreshold);
            obj.updateState(obj.LeftTurnState,p,p.lateralFiltered>=obj.Config.lateralStartThreshold && ...
                p.yawRateFiltered>=obj.Config.yawRateStartThresholdDegPerSecond, ...
                p.lateralFiltered<=obj.Config.lateralStopThreshold || ...
                p.yawRateFiltered<=obj.Config.yawRateStopThresholdDegPerSecond);
            obj.updateState(obj.RightTurnState,p,p.lateralFiltered<=-obj.Config.lateralStartThreshold && ...
                p.yawRateFiltered<=-obj.Config.yawRateStartThresholdDegPerSecond, ...
                p.lateralFiltered>=-obj.Config.lateralStopThreshold || ...
                p.yawRateFiltered>=-obj.Config.yawRateStopThresholdDegPerSecond);
            shock=abs(p.verticalFiltered)>=obj.Config.verticalShockThreshold || ...
                (isfinite(p.verticalJerk)&&abs(p.verticalJerk)>=obj.Config.jerkCandidateThreshold);
            if obj.VerticalShockState.IsActive
                if shock, obj.VerticalCalmSamples=0; else, obj.VerticalCalmSamples=obj.VerticalCalmSamples+1; end
            end
            stopShock=obj.VerticalShockState.IsActive && ...
                obj.VerticalCalmSamples>=obj.Config.verticalShockReleaseSamples;
            obj.updateState(obj.VerticalShockState,p,shock,stopShock);
        end
        function updateState(obj,state,p,startCondition,stopCondition)
            [changed,event]=state.update(p,startCondition,stopCondition);
            if changed && state.IsActive, obj.invokeCallback(obj.OnEventStarted,state.getPreview()); end
            if ~isempty(event), obj.completeEvent(event); end
        end
        function finishActiveEvents(obj,reason,missing)
            states={obj.BrakingState,obj.AccelerationState,obj.LeftTurnState, ...
                obj.RightTurnState,obj.VerticalShockState};
            for index=1:numel(states)
                event=states{index}.terminate(reason,missing);
                if ~isempty(event), obj.completeEvent(event); end
            end
        end
        function completeEvent(obj,event)
            obj.EventsDetected=obj.EventsDetected+1;
            event.eventId=sprintf('RT-EVT-%06d',obj.EventsDetected);
            obj.LatestEvent=event; obj.EventHistoryIndex=mod(obj.EventHistoryIndex,numel(obj.EventHistory))+1;
            obj.EventHistory{obj.EventHistoryIndex}=event;
            obj.EventHistoryCount=min(obj.EventHistoryCount+1,numel(obj.EventHistory));
            obj.invokeCallback(obj.OnEventCompleted,event);
        end
        function appendSampleHistory(obj,p)
            obj.SampleHistoryIndex=mod(obj.SampleHistoryIndex,numel(obj.SampleHistory))+1;
            obj.SampleHistory{obj.SampleHistoryIndex}=p;
            obj.SampleHistoryCount=min(obj.SampleHistoryCount+1,numel(obj.SampleHistory));
        end
        function values=orderedBuffer(~,buffer,count,lastIndex)
            if count==0, values=cell(0,1); return; end
            capacity=numel(buffer); first=mod(lastIndex-count,capacity)+1;
            indices=mod((first-1)+(0:count-1),capacity)+1; values=buffer(indices);
        end
        function values=cellBufferToStruct(~,values)
            if isempty(values), values=struct.empty(0,1); return; end
            values=vertcat(values{:});
        end
        function invokeCallback(obj,callback,payload)
            if isempty(callback), return; end
            try
                callback(obj,payload);
            catch exception
                obj.LastError=exception;
                warning('IMU:RealtimeUserCallbackFailed','User callback failed: %s',exception.message);
            end
        end
        function recordQualityWarning(obj,info)
            info.source="realtime"; info.status="observed";
            info.timestamp=datetime('now','TimeZone','UTC');
            obj.DataQualityEventsDetected=obj.DataQualityEventsDetected+1;
            obj.LatestDataQualityEvent=info;
            obj.invokeCallback(obj.OnWarning,info);
        end
        function timerPoll(obj), obj.poll(); end
        function stopTimer(obj)
            if ~isempty(obj.Timer) && isvalid(obj.Timer) && strcmp(obj.Timer.Running,'on')
                stop(obj.Timer);
            end
        end
        function restoreTimerOption(obj,value), obj.Config.UseTimer=value; end
    end
end
