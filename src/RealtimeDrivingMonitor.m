classdef RealtimeDrivingMonitor < handle
%REALTIMEDRIVINGMONITOR Bounded causal FIFO driving-event monitor.
    properties (SetAccess=private)
        IsRunning=false
        Config
        SamplesProcessed=0
        EventsDetected=0
        DataQualityEventsDetected=0
        DuplicateSamples=0
        MissingSamples=0
        InvalidSamples=0
        LateSamples=0
        OverflowDropped=0
        MaximumCallbackAgeMs=0
        LastSequence=uint64(0)
        LatestSensorSample=[]
        LatestVehicleSample=[]
        LatestProcessedSample=[]
        LatestEvent=[]
        LatestDataQualityEvent=[]
        StartedAt=NaT
        StoppedAt=NaT
        LastError=[]
    end
    properties
        OnSample=[]
        OnEventStarted=[]
        OnEventCompleted=[]
        OnWarning=[]
        OnError=[]
        OnStopped=[]
    end
    properties(Access=private)
        Imu
        Calibration
        Dependencies
        Timer=[]
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
        SampleHistoryIndex=0
        SampleHistoryCount=0
        EventHistoryIndex=0
        EventHistoryCount=0
        PendingEvents
        Recorder=[]
        OwnsRecorder=false
        Dashboard=[]
        StreamSessionId=uint64(0)
        FirstSequence=uint64(0)
        ConsecutiveErrors=0
        VerticalCalmSamples=0
        StaleSessionDropped=0
        MonitorClock=[]
        AcquisitionDurationSeconds=0
        ShutdownDurationSeconds=0
        FinalCallbackStats=[]
        OverflowSincePreviousPoll=false
        IsStopping=false
        InternalErrors=strings(0,1)
        InternalWarnings=strings(0,1)
        LastStopSummary=[]
        StoppedCallbackInvoked=false
    end

    methods
        function obj=RealtimeDrivingMonitor(imu,calibration,options,dependencies)
            if nargin<3, options=struct(); end
            if nargin<4, dependencies=struct(); end
            config=getRealtimeDrivingConfig();
            if ~isstruct(options) || ~isscalar(options)
                error('IMU:InvalidRealtimeConfig','options must be a scalar struct.');
            end
            unknown=setdiff(fieldnames(options),fieldnames(config));
            if ~isempty(unknown)
                error('IMU:InvalidRealtimeConfig','Unknown option: %s.',unknown{1});
            end
            fields=fieldnames(options);
            for index=1:numel(fields), config.(fields{index})=options.(fields{index}); end
            obj.Config=validateRealtimeDrivingConfig(config);
            obj.Dependencies=obj.mergeDependencies(dependencies);
            obj.Imu=imu; obj.Calibration=calibration;
            obj.createComponents(); obj.reset();
        end

        function start(obj)
            if obj.IsRunning || obj.IsStopping
                error('IMU:RealtimeMonitorAlreadyRunning','Monitor is running.');
            end
            try
                guard=obj.Dependencies.assertRuntimeReady; guard();
                obj.validateStartInputs(); obj.reset();
                clockStart=obj.Dependencies.monotonicClockStart;
                obj.MonitorClock=clockStart();
                obj.Imu.start(obj.Config.callbackPeriodMs);
                stats=obj.Imu.getCallbackStats();
                obj.StreamSessionId=uint64(stats.sessionId);
                obj.StartedAt=datetime('now','TimeZone','UTC');
                if obj.Config.enableRecording
                    recorderOptions=struct('directory',obj.Config.recordingDirectory, ...
                        'callbackPeriodMs',obj.Config.callbackPeriodMs, ...
                        'maxPollSamples',obj.Config.maximumPollSamples, ...
                        'AllowSynthetic',obj.Config.AllowSyntheticCalibration);
                    factory=obj.Dependencies.createRecorder;
                    obj.Recorder=factory(obj.Imu,obj.Calibration,recorderOptions);
                    obj.OwnsRecorder=true; obj.Recorder.startExternal();
                end
                if obj.Config.enableLivePlot
                    factory=obj.Dependencies.createDashboard;
                    obj.Dashboard=factory(obj); obj.Dashboard.open();
                end
                if obj.Config.UseTimer
                    factory=obj.Dependencies.createTimer;
                    obj.Timer=factory('ExecutionMode','fixedSpacing', ...
                        'Period',obj.Config.pollPeriodSeconds,'BusyMode','drop', ...
                        'TimerFcn',@(~,~)obj.timerPoll());
                end
                obj.IsRunning=true;
                if obj.Config.UseTimer, start(obj.Timer); end
            catch exception
                obj.rollbackStart();
                obj.recordInternalError(exception);
                rethrow(exception);
            end
        end

        function startManual(obj)
            original=obj.Config.UseTimer; obj.Config.UseTimer=false;
            cleanup=onCleanup(@()obj.restoreTimerOption(original));
            obj.start(); clear cleanup;
        end

        function poll(obj)
            if ~obj.IsRunning || obj.IsStopping, return; end
            try
                stats=obj.Imu.getCallbackStats();
                overflow=obj.observeCallbackStats(stats);
                if ~obj.IsRunning || obj.IsStopping, return; end
                samples=obj.Imu.drainCallbackSamples(obj.Config.maximumPollSamples);
                for index=1:numel(samples)
                    if ~obj.IsRunning || obj.IsStopping, break; end
                    obj.processSample(samples{index},overflow);
                end
                obj.OverflowSincePreviousPoll=false;
                obj.ConsecutiveErrors=0;
            catch exception
                obj.ConsecutiveErrors=obj.ConsecutiveErrors+1;
                obj.recordInternalError(exception);
                if obj.ConsecutiveErrors>=obj.Config.maximumConsecutiveErrors
                    obj.stop();
                end
            end
        end

        function summary=stop(obj)
            if obj.IsStopping
                if isempty(obj.LastStopSummary), summary=obj.makeSummary([],0,0,false); else, summary=obj.LastStopSummary; end
                return;
            end
            if ~obj.IsRunning
                if isempty(obj.LastStopSummary), summary=obj.makeSummary([],0,0,false); else, summary=obj.LastStopSummary; end
                return;
            end
            obj.IsStopping=true;
            safety=onCleanup(@()obj.forceStoppedState());
            tailSamples=0; drainDuration=0; drainTimedOut=false; recording=[];
            try
                obj.stopTimer();
            catch exception
                obj.recordInternalError(exception);
            end
            try
                stats=obj.Imu.getCallbackStats(); obj.observeCallbackStats(stats);
            catch exception
                obj.recordInternalError(exception);
            end
            try
                obj.Imu.quiesce();
                obj.AcquisitionDurationSeconds=obj.monotonicElapsed();
            catch exception
                obj.recordInternalError(exception);
            end
            try
                [tailSamples,drainDuration,drainTimedOut]=obj.drainTail();
            catch exception
                drainTimedOut=true; obj.recordInternalError(exception);
            end
            finalStats=[];
            try
                finalStats=obj.Imu.getCallbackStats();
                obj.FinalCallbackStats=finalStats;
                obj.observeCallbackStats(finalStats);
            catch exception
                obj.recordInternalError(exception);
            end
            try
                obj.finishActiveEvents("monitor_stop",0); obj.flushPendingEvents();
            catch exception
                obj.recordInternalError(exception);
            end
            if obj.OwnsRecorder && ~isempty(obj.Recorder) && obj.Recorder.IsRecording
                try
                    recording=obj.Recorder.stopExternal(finalStats);
                catch exception
                    obj.recordInternalError(exception);
                    try
                        delete(obj.Recorder);
                    catch cleanupException
                        obj.recordInternalError(cleanupException);
                    end
                end
            end
            try
                obj.Imu.clearCallbackBuffer();
            catch exception
                obj.recordInternalError(exception);
            end
            try
                obj.closeDashboard();
            catch exception
                obj.recordInternalError(exception);
            end
            if obj.AcquisitionDurationSeconds<=0
                obj.AcquisitionDurationSeconds=obj.monotonicElapsed();
            end
            obj.ShutdownDurationSeconds=max(0, ...
                obj.monotonicElapsed()-obj.AcquisitionDurationSeconds);
            obj.StoppedAt=datetime('now','TimeZone','UTC'); obj.IsRunning=false;
            summary=obj.makeSummary(recording,tailSamples,drainDuration,drainTimedOut);
            obj.LastStopSummary=summary; obj.IsStopping=false; clear safety;
            if ~obj.StoppedCallbackInvoked
                obj.StoppedCallbackInvoked=true; obj.invokeCallback(obj.OnStopped,summary);
            end
        end

        function reset(obj)
            if obj.IsRunning || obj.IsStopping
                error('IMU:RealtimeMonitorRunning','Stop before reset.');
            end
            obj.SamplesProcessed=0; obj.EventsDetected=0; obj.DataQualityEventsDetected=0;
            obj.DuplicateSamples=0; obj.MissingSamples=0; obj.InvalidSamples=0;
            obj.LateSamples=0; obj.OverflowDropped=0; obj.StaleSessionDropped=0;
            obj.MaximumCallbackAgeMs=0; obj.LastSequence=uint64(0); obj.FirstSequence=uint64(0);
            obj.LatestSensorSample=[]; obj.LatestVehicleSample=[];
            obj.LatestProcessedSample=[]; obj.LatestEvent=[]; obj.LatestDataQualityEvent=[];
            obj.StartedAt=NaT; obj.StoppedAt=NaT; obj.LastError=[];
            obj.ConsecutiveErrors=0; obj.VerticalCalmSamples=0; obj.MonitorClock=[];
            obj.AcquisitionDurationSeconds=0; obj.ShutdownDurationSeconds=0;
            obj.FinalCallbackStats=[];
            obj.OverflowSincePreviousPoll=false;
            obj.InternalErrors=strings(0,1); obj.InternalWarnings=strings(0,1);
            obj.LastStopSummary=[]; obj.StoppedCallbackInvoked=false;
            obj.Recorder=[]; obj.OwnsRecorder=false; obj.Dashboard=[]; obj.Timer=[];
            obj.resetProcessingState(); obj.PendingEvents=cell(5,1);
            sampleCapacity=max(1,ceil(obj.Config.historySeconds*obj.Config.sampleRateHz));
            obj.SampleHistory=cell(sampleCapacity,1); obj.SampleHistoryIndex=0; obj.SampleHistoryCount=0;
            obj.EventHistory=cell(obj.Config.eventHistoryLimit,1); obj.EventHistoryIndex=0; obj.EventHistoryCount=0;
        end

        function sample=latestProcessedSample(obj), sample=obj.LatestProcessedSample; end
        function events=getRecentEvents(obj,maxCount)
            if nargin<2, maxCount=obj.EventHistoryCount; end
            events=obj.orderedBuffer(obj.EventHistory,obj.EventHistoryCount,obj.EventHistoryIndex);
            if numel(events)>maxCount, events=events(end-maxCount+1:end); end
            events=obj.cellBufferToStruct(events);
        end
        function samples=getRecentSamples(obj,maxCount)
            if nargin<2, maxCount=obj.SampleHistoryCount; end
            samples=obj.orderedBuffer(obj.SampleHistory,obj.SampleHistoryCount,obj.SampleHistoryIndex);
            if numel(samples)>maxCount, samples=samples(end-maxCount+1:end); end
            samples=obj.cellBufferToStruct(samples);
        end
        function stats=getStats(obj)
            stats=obj.makeSummary([],0,0,false);
        end
        function delete(obj)
            try
                obj.stop();
            catch exception
                warning('IMU:RealtimeCleanupFailed','%s',exception.message);
            end
            try
                obj.stopTimer();
            catch exception
                warning('IMU:RealtimeTimerCleanupFailed','%s',exception.message);
            end
            if obj.Config.DisconnectImuOnDelete
                try
                    obj.Imu.disconnect();
                catch exception
                    warning('IMU:RealtimeDisconnectFailed','%s',exception.message);
                end
            end
        end
    end

    methods(Access=private)
        function dependencies=mergeDependencies(~,custom)
            defaults=struct('assertRuntimeReady',@assertImuRuntimeReady, ...
                'createTimer',@timer, ...
                'createDashboard',@(monitor)RealtimeDrivingDashboard(monitor), ...
                'createRecorder',@(imu,calibration,options)ImuSessionRecorder(imu,calibration,options), ...
                'monotonicClockStart',@tic,'monotonicClockElapsed',@toc, ...
                'sleep',@pause);
            if ~isstruct(custom) || ~isscalar(custom)
                error('IMU:InvalidRealtimeDependencies','dependencies must be a scalar struct.');
            end
            unknown=setdiff(fieldnames(custom),fieldnames(defaults));
            if ~isempty(unknown), error('IMU:InvalidRealtimeDependencies','Unknown dependency: %s.',unknown{1}); end
            dependencies=defaults; fields=fieldnames(custom);
            for index=1:numel(fields), dependencies.(fields{index})=custom.(fields{index}); end
            names=fieldnames(dependencies);
            for index=1:numel(names)
                if ~isa(dependencies.(names{index}),'function_handle')
                    error('IMU:InvalidRealtimeDependencies','%s must be a function handle.',names{index});
                end
            end
        end
        function validateStartInputs(obj)
            validation=validateImuCalibration(obj.Calibration, ...
                'AllowSynthetic',obj.Config.AllowSyntheticCalibration);
            if ~validation.valid, error('IMU:InvalidCalibrationFile','%s',strjoin(validation.errors,' ')); end
            if string(obj.Calibration.metadata.imuUid)~=string(obj.Imu.UID)
                error('IMU:CalibrationDeviceMismatch','Calibration UID does not match IMU.');
            end
            actualRate=1000/obj.Config.callbackPeriodMs;
            if abs(actualRate-obj.Config.sampleRateHz)>1e-9
                error('IMU:RealtimeSampleRateMismatch','sampleRateHz and callbackPeriodMs are inconsistent.');
            end
        end
        function createComponents(obj)
            options=struct('medianWindowSamples',obj.Config.medianWindowSamples, ...
                'outlierMadThreshold',obj.Config.outlierMadThreshold);
            args={obj.Config.sampleRateHz,obj.Config.lowPassCutoffHz,options};
            obj.LongitudinalFilter=RealtimeSignalFilter(args{:}); obj.LateralFilter=RealtimeSignalFilter(args{:});
            obj.VerticalFilter=RealtimeSignalFilter(args{:}); obj.YawRateFilter=RealtimeSignalFilter(args{:});
            obj.BrakingState=RealtimeEventState("BRAKING_CANDIDATE",obj.Config);
            obj.AccelerationState=RealtimeEventState("ACCELERATION_CANDIDATE",obj.Config);
            obj.LeftTurnState=RealtimeEventState("TURN_LEFT_CANDIDATE",obj.Config);
            obj.RightTurnState=RealtimeEventState("TURN_RIGHT_CANDIDATE",obj.Config);
            obj.VerticalShockState=RealtimeEventState("VERTICAL_SHOCK_CANDIDATE",obj.Config);
        end
        function resetProcessingState(obj)
            components={obj.LongitudinalFilter,obj.LateralFilter,obj.VerticalFilter,obj.YawRateFilter, ...
                obj.BrakingState,obj.AccelerationState,obj.LeftTurnState,obj.RightTurnState,obj.VerticalShockState};
            for index=1:numel(components), components{index}.reset(); end
            obj.VerticalCalmSamples=0;
        end
        function overflow=observeCallbackStats(obj,stats)
            overflow=double(stats.overflowDropped)>obj.OverflowDropped;
            if overflow
                increment=double(stats.overflowDropped)-obj.OverflowDropped;
                obj.OverflowDropped=double(stats.overflowDropped); obj.OverflowSincePreviousPoll=true;
                obj.finishActiveEvents("overflow",0); obj.flushPendingEvents(); obj.resetProcessingState();
                obj.recordQualityWarning(struct('type',"CALLBACK_OVERFLOW",'count',increment,'total',obj.OverflowDropped));
                if obj.Config.stopOnOverflow && obj.IsRunning && ~obj.IsStopping, obj.stop(); end
            end
            if double(stats.staleSessionDropped)>obj.StaleSessionDropped
                obj.StaleSessionDropped=double(stats.staleSessionDropped);
                obj.recordQualityWarning(struct('type',"STALE_SESSION_CALLBACK",'total',obj.StaleSessionDropped));
            end
        end
        function processSample(obj,sensor,overflowFlag)
            if nargin<3, overflowFlag=false; end
            if ~obj.validSequenceMetadata(sensor)
                obj.handleInvalidSample("INVALID_CALLBACK_METADATA",[]); return;
            end
            if uint64(sensor.sessionId)~=obj.StreamSessionId
                obj.handleInvalidSample("INVALID_CALLBACK_METADATA",[]); return;
            end
            sequence=uint64(sensor.sequenceNumber);
            if obj.LastSequence>0 && sequence<=obj.LastSequence
                obj.DuplicateSamples=obj.DuplicateSamples+1; return;
            end
            gapBefore=false;
            if obj.LastSequence>0 && sequence>obj.LastSequence+1
                gapBefore=true; missing=double(sequence-obj.LastSequence-1);
                obj.MissingSamples=obj.MissingSamples+missing;
                obj.finishActiveEvents("sequence_gap",missing); obj.flushPendingEvents(); obj.resetProcessingState();
                if obj.Config.stopOnSequenceGap && obj.IsRunning && ~obj.IsStopping, obj.stop(); return; end
            end
            if obj.FirstSequence==0, obj.FirstSequence=sequence; end
            obj.LastSequence=sequence;
            if ~obj.validSampleMetadata(sensor)
                obj.handleInvalidSample("INVALID_CALLBACK_METADATA",[]); return;
            end
            late=double(sensor.callbackAgeMs)>obj.Config.maximumSampleAgeMs;
            obj.LateSamples=obj.LateSamples+double(late);
            obj.MaximumCallbackAgeMs=max(obj.MaximumCallbackAgeMs,double(sensor.callbackAgeMs));
            try
                vehicle=applyMountCalibration(sensor,obj.Calibration,'AllowSynthetic',obj.Config.AllowSyntheticCalibration);
                processed=obj.filterSample(vehicle,gapBefore,logical(overflowFlag),late);
            catch exception
                obj.handleInvalidSample("INVALID_SAMPLE",exception); return;
            end
            if ~processed.dataValid
                obj.handleInvalidSample("INVALID_SAMPLE",[]); return;
            end
            obj.LatestSensorSample=sensor; obj.LatestVehicleSample=vehicle;
            obj.LatestProcessedSample=processed; obj.SamplesProcessed=obj.SamplesProcessed+1;
            obj.publishExpiredPending(processed); obj.updateEvents(processed); obj.appendSampleHistory(processed);
            if obj.OwnsRecorder && ~isempty(obj.Recorder) && obj.Recorder.IsRecording
                obj.Recorder.appendSample(sensor,vehicle);
            end
            if ~isempty(obj.Dashboard), obj.Dashboard.update(processed); end
            obj.invokeCallback(obj.OnSample,processed);
        end
        function valid=validSequenceMetadata(~,sample)
            required={'sessionId','sequenceNumber','hostTimestamp'};
            valid=isstruct(sample) && isscalar(sample) && all(isfield(sample,required));
            if ~valid, return; end
            valid=isnumeric(sample.sessionId) && isscalar(sample.sessionId) && ...
                isfinite(double(sample.sessionId)) && double(sample.sessionId)>=0 && ...
                isnumeric(sample.sequenceNumber) && isscalar(sample.sequenceNumber) && ...
                isfinite(double(sample.sequenceNumber)) && double(sample.sequenceNumber)>=1 && ...
                isa(sample.hostTimestamp,'datetime') && isscalar(sample.hostTimestamp) && ~isnat(sample.hostTimestamp);
        end
        function valid=validSampleMetadata(~,sample)
            valid=isfield(sample,'callbackAgeMs') && isnumeric(sample.callbackAgeMs) && ...
                isscalar(sample.callbackAgeMs) && isfinite(double(sample.callbackAgeMs)) && ...
                double(sample.callbackAgeMs)>=0;
        end
        function handleInvalidSample(obj,type,exception)
            obj.InvalidSamples=obj.InvalidSamples+1;
            obj.finishActiveEvents("invalid_sample",0); obj.flushPendingEvents(); obj.resetProcessingState();
            info=struct('type',string(type),'invalidMetadata',type=="INVALID_CALLBACK_METADATA");
            obj.recordQualityWarning(info);
            if ~isempty(exception), obj.recordInternalError(exception); end
        end
        function p=filterSample(obj,v,gapBefore,overflowFlag,late)
            lo=obj.LongitudinalFilter.update(v.longitudinalAcceleration);
            la=obj.LateralFilter.update(v.lateralAcceleration); ve=obj.VerticalFilter.update(v.verticalAcceleration);
            ya=obj.YawRateFilter.update(v.yawRate);
            valid=lo.valid&&la.valid&&ve.valid&&ya.valid;
            outlier=lo.outlierReplaced||la.outlierReplaced||ve.outlierReplaced||ya.outlierReplaced;
            quality=1-0.30*double(late)-0.20*double(outlier)-0.25*double(gapBefore)-0.25*double(overflowFlag);
            p=struct('source',"realtime",'sessionId',uint64(v.sessionId), ...
                'sequenceNumber',uint64(v.sequenceNumber),'hostTimestamp',v.hostTimestamp, ...
                'elapsedSeconds',double(uint64(v.sequenceNumber)-obj.FirstSequence)/obj.Config.sampleRateHz, ...
                'callbackAgeMs',double(v.callbackAgeMs),'longitudinalRaw',lo.raw, ...
                'longitudinalFiltered',lo.filtered,'longitudinalJerk',lo.derivative, ...
                'lateralRaw',la.raw,'lateralFiltered',la.filtered,'lateralJerk',la.derivative, ...
                'verticalRaw',ve.raw,'verticalFiltered',ve.filtered,'verticalJerk',ve.derivative, ...
                'yawRateRaw',ya.raw,'yawRateFiltered',ya.filtered,'temperature',double(v.temperature), ...
                'gapBeforeSample',logical(gapBefore),'overflowSincePreviousPoll',logical(overflowFlag), ...
                'lateSample',logical(late),'outlierReplaced',outlier,'invalidMetadata',false, ...
                'dataValid',valid,'dataQuality',max(0,min(1,quality)), ...
                'overflowDroppedTotal',obj.OverflowDropped,'missingSamplesTotal',obj.MissingSamples);
        end
        function updateEvents(obj,p)
            obj.updateState(obj.BrakingState,p,p.longitudinalFiltered<=obj.Config.brakingStartThreshold, ...
                p.longitudinalFiltered>=obj.Config.brakingStopThreshold);
            obj.updateState(obj.AccelerationState,p,p.longitudinalFiltered>=obj.Config.accelerationStartThreshold, ...
                p.longitudinalFiltered<=obj.Config.accelerationStopThreshold);
            obj.updateState(obj.LeftTurnState,p,p.lateralFiltered>=obj.Config.lateralStartThreshold && ...
                p.yawRateFiltered>=obj.Config.yawRateStartThresholdDegPerSecond, ...
                p.lateralFiltered<=obj.Config.lateralStopThreshold || p.yawRateFiltered<=obj.Config.yawRateStopThresholdDegPerSecond);
            obj.updateState(obj.RightTurnState,p,p.lateralFiltered<=-obj.Config.lateralStartThreshold && ...
                p.yawRateFiltered<=-obj.Config.yawRateStartThresholdDegPerSecond, ...
                p.lateralFiltered>=-obj.Config.lateralStopThreshold || p.yawRateFiltered>=-obj.Config.yawRateStopThresholdDegPerSecond);
            shock=abs(p.verticalFiltered)>=obj.Config.verticalShockThreshold || ...
                (isfinite(p.verticalJerk)&&abs(p.verticalJerk)>=obj.Config.jerkCandidateThreshold);
            if obj.VerticalShockState.IsActive
                if shock, obj.VerticalCalmSamples=0; else, obj.VerticalCalmSamples=obj.VerticalCalmSamples+1; end
            end
            stopShock=obj.VerticalShockState.IsActive && obj.VerticalCalmSamples>=obj.Config.verticalShockReleaseSamples;
            obj.updateState(obj.VerticalShockState,p,shock,stopShock);
        end
        function updateState(obj,state,p,startCondition,stopCondition)
            [changed,event]=state.update(p,startCondition,stopCondition);
            if changed && state.IsActive, obj.invokeCallback(obj.OnEventStarted,state.getPreview()); end
            if ~isempty(event), obj.queueEvent(event); end
        end
        function finishActiveEvents(obj,reason,missing)
            states={obj.BrakingState,obj.AccelerationState,obj.LeftTurnState,obj.RightTurnState,obj.VerticalShockState};
            for index=1:numel(states)
                event=states{index}.terminate(reason,missing);
                if ~isempty(event), obj.queueEvent(event); end
            end
        end
        function queueEvent(obj,event)
            index=obj.eventTypeIndex(event.type); pending=obj.PendingEvents{index};
            if ~isempty(pending)
                silence=event.startElapsedSeconds-pending.endElapsedSeconds;
                if silence>=0 && silence<=obj.Config.maximumEventSilenceSeconds
                    event=obj.mergeEvents(pending,event);
                else
                    obj.publishEvent(pending);
                end
            end
            obj.PendingEvents{index}=event;
        end
        function publishExpiredPending(obj,p)
            for index=1:numel(obj.PendingEvents)
                event=obj.PendingEvents{index};
                if isempty(event) || obj.eventStateActive(index), continue; end
                if p.elapsedSeconds-event.endElapsedSeconds>obj.Config.maximumEventSilenceSeconds
                    obj.publishEvent(event); obj.PendingEvents{index}=[];
                end
            end
        end
        function flushPendingEvents(obj)
            for index=1:numel(obj.PendingEvents)
                if ~isempty(obj.PendingEvents{index}), obj.publishEvent(obj.PendingEvents{index}); obj.PendingEvents{index}=[]; end
            end
        end
        function publishEvent(obj,event)
            obj.EventsDetected=obj.EventsDetected+1; event.eventId=sprintf('RT-EVT-%06d',obj.EventsDetected);
            obj.LatestEvent=event; obj.EventHistoryIndex=mod(obj.EventHistoryIndex,numel(obj.EventHistory))+1;
            obj.EventHistory{obj.EventHistoryIndex}=event;
            obj.EventHistoryCount=min(obj.EventHistoryCount+1,numel(obj.EventHistory));
            obj.invokeCallback(obj.OnEventCompleted,event);
        end
        function merged=mergeEvents(obj,first,second)
            merged=first; total=first.sampleCount+second.sampleCount;
            merged.endSequence=second.endSequence; merged.endTimestamp=second.endTimestamp;
            merged.endElapsedSeconds=second.endElapsedSeconds;
            merged.durationSeconds=merged.endElapsedSeconds-merged.startElapsedSeconds+ ...
                1/obj.Config.sampleRateHz;
            merged.meanAcceleration=(first.meanAcceleration*first.sampleCount+ ...
                second.meanAcceleration*second.sampleCount)/max(1,total);
            merged.peakAcceleration=obj.selectPeakByAbsoluteValue( ...
                first.peakAcceleration,second.peakAcceleration);
            merged.peakAbsoluteAcceleration=max(first.peakAbsoluteAcceleration,second.peakAbsoluteAcceleration);
            merged.peakJerk=obj.selectPeakByAbsoluteValue(first.peakJerk,second.peakJerk);
            merged.peakYawRate=obj.selectPeakByAbsoluteValue(first.peakYawRate,second.peakYawRate);
            merged.integratedAcceleration=first.integratedAcceleration+second.integratedAcceleration;
            merged.sampleCount=total; merged.missingSamplesInside=first.missingSamplesInside+second.missingSamplesInside;
            merged.outlierSamplesInside=first.outlierSamplesInside+second.outlierSamplesInside;
            merged.maximumCallbackAgeMs=max(first.maximumCallbackAgeMs,second.maximumCallbackAgeMs);
            merged.dataQuality=min(first.dataQuality,second.dataQuality);
            merged.terminationReason=second.terminationReason;
        end
        function peak=selectPeakByAbsoluteValue(~,firstPeak,secondPeak)
            if ~isfinite(firstPeak), peak=secondPeak; return; end
            if ~isfinite(secondPeak), peak=firstPeak; return; end
            peak=firstPeak;
            if abs(secondPeak)>abs(firstPeak), peak=secondPeak; end
        end
        function index=eventTypeIndex(~,type)
            types=["BRAKING_CANDIDATE","ACCELERATION_CANDIDATE","TURN_LEFT_CANDIDATE", ...
                "TURN_RIGHT_CANDIDATE","VERTICAL_SHOCK_CANDIDATE"];
            index=find(types==string(type),1);
        end
        function active=eventStateActive(obj,index)
            states={obj.BrakingState,obj.AccelerationState,obj.LeftTurnState,obj.RightTurnState,obj.VerticalShockState};
            active=states{index}.IsActive;
        end
        function appendSampleHistory(obj,p)
            obj.SampleHistoryIndex=mod(obj.SampleHistoryIndex,numel(obj.SampleHistory))+1;
            obj.SampleHistory{obj.SampleHistoryIndex}=p;
            obj.SampleHistoryCount=min(obj.SampleHistoryCount+1,numel(obj.SampleHistory));
        end
        function [count,duration,timedOut]=drainTail(obj)
            count=0; emptyPasses=0; startTime=obj.monotonicElapsed();
            while emptyPasses<obj.Config.stopDrainEmptyPasses
                if obj.monotonicElapsed()-startTime>=obj.Config.stopDrainTimeoutSeconds, break; end
                samples=obj.Imu.drainCallbackSamples(obj.Config.maximumPollSamples);
                if isempty(samples)
                    emptyPasses=emptyPasses+1;
                    if emptyPasses<obj.Config.stopDrainEmptyPasses
                        obj.Dependencies.sleep(obj.Config.stopDrainPollIntervalSeconds);
                    end
                    continue;
                end
                emptyPasses=0;
                for index=1:numel(samples), obj.processSample(samples{index},obj.OverflowSincePreviousPoll); end
                count=count+numel(samples); obj.OverflowSincePreviousPoll=false;
            end
            duration=max(0,obj.monotonicElapsed()-startTime);
            timedOut=emptyPasses<obj.Config.stopDrainEmptyPasses;
        end
        function duration=monotonicElapsed(obj)
            if isempty(obj.MonitorClock), duration=0; return; end
            elapsed=obj.Dependencies.monotonicClockElapsed; duration=double(elapsed(obj.MonitorClock));
        end
        function summary=makeSummary(obj,recording,tailSamples,drainDuration,drainTimedOut)
            duration=obj.AcquisitionDurationSeconds;
            if obj.IsRunning && ~obj.IsStopping, duration=obj.monotonicElapsed(); end
            frequency=0; if duration>0, frequency=obj.SamplesProcessed/duration; end
            success=isempty(obj.InternalErrors) && ~drainTimedOut;
            summary=struct('success',success,'errors',obj.InternalErrors,'warnings',obj.InternalWarnings, ...
                'isRunning',obj.IsRunning,'samplesProcessed',obj.SamplesProcessed, ...
                'eventsDetected',obj.EventsDetected,'dataQualityEventsDetected',obj.DataQualityEventsDetected, ...
                'duplicateSamples',obj.DuplicateSamples,'missingSamples',obj.MissingSamples, ...
                'invalidSamples',obj.InvalidSamples,'lateSamples',obj.LateSamples, ...
                'overflowDropped',obj.OverflowDropped,'maximumCallbackAgeMs',obj.MaximumCallbackAgeMs, ...
                'staleSessionDropped',obj.StaleSessionDropped,'lastSequence',obj.LastSequence, ...
                'durationSeconds',duration,'acquisitionDurationSeconds',duration, ...
                'shutdownDurationSeconds',obj.ShutdownDurationSeconds, ...
                'averageFrequencyHz',frequency, ...
                'startedAt',obj.StartedAt,'stoppedAt',obj.StoppedAt, ...
                'sampleHistoryCount',obj.SampleHistoryCount,'eventHistoryCount',obj.EventHistoryCount, ...
                'tailSamplesDrained',double(tailSamples),'stopDrainDurationSeconds',double(drainDuration), ...
                'stopDrainTimedOut',logical(drainTimedOut),'recording',recording,'lastError',obj.LastError);
            summary.finalCallbackStats=obj.FinalCallbackStats;
        end
        function recordInternalError(obj,exception)
            obj.LastError=exception;
            obj.InternalErrors(end+1,1)=string(exception.identifier)+": "+string(exception.message);
            obj.invokeCallback(obj.OnError,exception);
        end
        function recordQualityWarning(obj,info)
            info.source="realtime"; info.status="observed"; info.timestamp=datetime('now','TimeZone','UTC');
            obj.DataQualityEventsDetected=obj.DataQualityEventsDetected+1; obj.LatestDataQualityEvent=info;
            obj.InternalWarnings(end+1,1)=string(info.type); obj.invokeCallback(obj.OnWarning,info);
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
        function rollbackStart(obj)
            obj.cleanupAction(@()obj.stopTimer(),"timer rollback");
            obj.cleanupAction(@()obj.closeDashboard(),"dashboard rollback");
            if obj.OwnsRecorder && ~isempty(obj.Recorder)
                obj.cleanupAction(@()delete(obj.Recorder),"recorder rollback");
            end
            obj.cleanupAction(@()obj.Imu.quiesce(),"IMU quiesce rollback");
            obj.cleanupAction(@()obj.Imu.clearCallbackBuffer(),"IMU buffer rollback");
            obj.IsRunning=false; obj.IsStopping=false;
        end
        function forceStoppedState(obj)
            if ~(obj.IsRunning || obj.IsStopping), return; end
            obj.cleanupAction(@()obj.stopTimer(),"timer final cleanup");
            obj.cleanupAction(@()obj.Imu.quiesce(),"IMU quiesce final cleanup");
            if obj.OwnsRecorder && ~isempty(obj.Recorder) && isvalid(obj.Recorder)
                obj.cleanupAction(@()delete(obj.Recorder),"recorder final cleanup");
            end
            obj.cleanupAction(@()obj.Imu.clearCallbackBuffer(),"IMU buffer final cleanup");
            obj.cleanupAction(@()obj.closeDashboard(),"dashboard final cleanup");
            obj.IsRunning=false; obj.IsStopping=false;
        end
        function cleanupAction(~,action,label)
            try
                action();
            catch exception
                warning('IMU:RealtimeRollbackFailure','%s failed: %s',label,exception.message);
            end
        end
        function stopTimer(obj)
            if isempty(obj.Timer), return; end
            timerObject=obj.Timer; obj.Timer=[];
            if isvalid(timerObject)
                try
                    stop(timerObject);
                catch exception
                    try
                        delete(timerObject);
                    catch deleteException
                        warning('IMU:RealtimeTimerCleanupFailed','%s',deleteException.message);
                    end
                    rethrow(exception);
                end
                delete(timerObject);
            end
        end
        function closeDashboard(obj)
            if isempty(obj.Dashboard), return; end
            dashboard=obj.Dashboard; obj.Dashboard=[]; dashboard.close();
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
        function timerPoll(obj), obj.poll(); end
        function restoreTimerOption(obj,value), obj.Config.UseTimer=value; end
    end
end
