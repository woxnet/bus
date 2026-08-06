classdef SyntheticBusDrivingSystemController < handle
%SYNTHETICBUSDRIVINGSYSTEMCONTROLLER Timer-driven hardware-free demonstration.
    properties(SetAccess=private)
        TelemetryHub
        State="IDLE"
        CurrentStage=""
        SimulatedSeconds=0
        SimulationSpeed=10
        SimulationDurationSeconds=60
        IsSimulationRunning=false
        IsSimulationComplete=false
        TransitionHistory=strings(0,1)
        WarningHistory=strings(0,1)
        TimerErrors=strings(0,1)
    end
    properties(Access=private)
        SimulationTimer=[]
        SimulationClock=[]
        NextSampleIndex=1
        EventIndex=1
        AppliedTransitions=false(1,20)
        Summary
    end
    methods
        function obj=SyntheticBusDrivingSystemController(config)
            if nargin<1, config=getBusDrivingSystemDashboardConfig(); end
            obj.TelemetryHub=BusDrivingSystemTelemetryHub(config);
            obj.TelemetryHub.updateMetadata(struct('checkoutCommit',"SYNTHETIC", ...
                'busId',"SYNTHETIC BUS",'imuUid',"SYNTHETIC IMU"));
            obj.Summary=obj.makeSummary(false);
        end
        function startSimulation(obj,durationSeconds,simulationSpeed)
            if nargin>=2 && ~isempty(durationSeconds), obj.SimulationDurationSeconds=durationSeconds; end
            if nargin>=3 && ~isempty(simulationSpeed), obj.SimulationSpeed=simulationSpeed; end
            if obj.IsSimulationRunning, return; end
            obj.resetSimulation(); obj.IsSimulationRunning=true; obj.SimulationClock=tic;
            obj.SimulationTimer=timer('ExecutionMode','fixedSpacing','BusyMode','drop','Period',0.02, ...
                'TimerFcn',@(~,~)obj.advanceSimulation(),'ErrorFcn',@(~,event)obj.captureTimerError(event));
            start(obj.SimulationTimer);
        end
        function summary=simulate(obj,durationSeconds)
            if nargin<2, durationSeconds=60; end
            obj.startSimulation(durationSeconds,10);
            while obj.IsSimulationRunning, pause(0.02); end
            summary=obj.getSimulationSummary();
        end
        function waitForCompletion(obj,timeoutSeconds)
            if nargin<2, timeoutSeconds=obj.SimulationDurationSeconds/obj.SimulationSpeed+5; end
            started=tic;
            while obj.IsSimulationRunning && toc(started)<timeoutSeconds, pause(0.02); end
            if obj.IsSimulationRunning, error('IMU:SyntheticSimulationTimeout','Synthetic simulation timed out.'); end
        end
        function summary=getSimulationSummary(obj), summary=obj.Summary; end
        function status=getStatus(obj)
            status=struct('lifecycleState',obj.State,'currentStage',obj.CurrentStage, ...
                'stageProgress',min(1,obj.SimulatedSeconds/max(1,obj.SimulationDurationSeconds)), ...
                'message',"SYNTHETIC DEMONSTRATION - NOT A HARDWARE ACCEPTANCE", ...
                'mode',"synthetic",'startedAt',NaT,'completedAt',NaT,'lastError',[], ...
                'isRealtimeRunning',obj.State=="STREAMING",'isCalibrationRunning',obj.State=="CALIBRATING", ...
                'isAcceptanceRunning',obj.State=="RUNNING_ACCEPTANCE",'isClosed',false,'isConnected',false);
            state=obj.State; running=obj.IsSimulationRunning;
            status.actions=struct('canStartSystem',~running && any(state==["IDLE","STOPPED","COMPLETED"]), ...
                'canRunPreflight',false,'canStartCalibration',false,'canConfirmCalibration',false, ...
                'canRejectCalibration',false,'canStartRealtime',false,'canStopRealtime',state=="STREAMING", ...
                'canRunAcceptance',false,'canSaveSnapshot',true,'canClose',true);
        end
        function snapshot=getTelemetrySnapshot(obj), snapshot=obj.TelemetryHub.getSnapshot(); end
        function snapshot=getSummarySnapshot(obj)
            snapshot=obj.TelemetryHub.getSummarySnapshot(); status=obj.getStatus(); snapshot.actions=status.actions;
        end
        function startSystem(obj), obj.setState("BOOTSTRAP","Bootstrap"); end
        function runPreflight(obj), obj.setState("PREFLIGHT","Preflight"); end
        function startCalibration(obj), obj.setState("CALIBRATING","Calibration"); end
        function confirmCurrentStep(~), end
        function rejectCurrentStep(~), end
        function startRealtime(obj), obj.setState("STREAMING","Realtime"); end
        function summary=stopRealtime(obj), obj.setState("STOPPED","Result"); summary=struct('success',true); end
        function runFullAcceptance(obj), obj.setState("COMPLETED","Result"); end
        function close(obj)
            obj.stopSimulationTimer(); obj.IsSimulationRunning=false;
            if obj.State=="STREAMING", obj.stopRealtime(); end
        end
        function delete(obj), obj.close(); end
    end
    methods(Access=private)
        function resetSimulation(obj)
            obj.stopSimulationTimer(); obj.State="IDLE"; obj.CurrentStage=""; obj.SimulatedSeconds=0;
            obj.IsSimulationComplete=false; obj.NextSampleIndex=1; obj.EventIndex=1;
            obj.AppliedTransitions=false(1,20); obj.TransitionHistory=strings(0,1);
            obj.WarningHistory=strings(0,1); obj.TimerErrors=strings(0,1); obj.Summary=obj.makeSummary(false);
        end
        function advanceSimulation(obj)
            obj.SimulatedSeconds=min(obj.SimulationDurationSeconds,toc(obj.SimulationClock)*obj.SimulationSpeed);
            obj.applyScenarioTransitions(); obj.generateSamples();
            if obj.SimulatedSeconds>=obj.SimulationDurationSeconds, obj.finishSimulation(); end
        end
        function applyScenarioTransitions(obj)
            schedule=[0 2 4 7 10 13 45 48 50 51 52 53 54 55 56 57 58 59 60];
            for index=1:numel(schedule)
                if ~obj.AppliedTransitions(index) && obj.SimulatedSeconds>=schedule(index)
                    obj.AppliedTransitions(index)=true; obj.applyTransition(index);
                end
            end
        end
        function applyTransition(obj,index)
            switch index
                case 1, obj.setState("BOOTSTRAP","Bootstrap"); obj.stage("Bootstrap","PASSED",1,"Bootstrap complete.");
                case 2, obj.setState("PREFLIGHT","Preflight"); obj.stage("Preflight","PASSED",1,"Preflight complete.");
                case 3
                    obj.setState("CALIBRATION_REQUIRED","Calibration");
                    obj.TelemetryHub.ingestCalibration(struct('state',"REQUIRED",'phase',"operator",'progress',0, ...
                        'samplesRequired',500,'samplesCollected',0,'samplesRemaining',500));
                case 4
                    obj.setState("CALIBRATING","Calibration");
                    obj.TelemetryHub.ingestCalibration(struct('state',"SAMPLING",'phase',"stationary",'progress',.65, ...
                        'samplesRequired',500,'samplesCollected',325,'samplesRemaining',175));
                case 5
                    obj.setState("CALIBRATION_VERIFYING","Verification");
                    obj.TelemetryHub.ingestCalibrationResult(struct('verificationPerformed',true,'verificationPassed',true, ...
                        'verificationScore',.94,'activationAttempted',true,'activationVerified',true, ...
                        'rotationVehicleFromSensor',eye(3),'bias',[.01 -.02 .03],'qualityScore',.96));
                case 6, obj.setState("STREAMING","Realtime");
                case 7
                    value=struct('type',"SYNTHETIC_DATA_QUALITY",'message',"Synthetic callback age warning.");
                    obj.WarningHistory(end+1,1)=string(value.message); obj.TelemetryHub.ingestWarning(value);
                case 8, obj.ingestRecordingGuard();
                case 9, obj.setState("STOP_DEFERRED","Stopping");
                case 10, obj.setState("STOPPING","Stopping");
                case 11, obj.setState("QUIESCING","Stopping");
                case 12, obj.setState("DRAINING_TAIL","Stopping");
                case 13, obj.setState("FINAL_STATS","Stopping");
                case 14, obj.setState("FINALIZING_EVENTS","Stopping");
                case 15, obj.setState("CLEARING_BUFFER","Stopping");
                case 16, obj.setState("RELEASING_OWNER","Stopping");
                case 17, obj.setState("STOPPED","Result");
                case 18, obj.setState("RUNNING_ACCEPTANCE","summary_validation");
                case 19
                    acceptance=struct('success',true,'failurePhase',"",'infrastructureFailure',false, ...
                        'matlabRestartRequired',false,'commitMatch',true,'uidMatch',true,'busIdMatch',true, ...
                        'sensorFusionModeMatch',true,'calibrationVerified',true,'runtimeTailComplete',true, ...
                        'runtimeBufferEmpty',true,'runtimeSuccess',true,'realtimeSuccess',true, ...
                        'matFile',"synthetic.mat",'jsonFile',"synthetic.json",'errors',strings(0,1), ...
                        'warnings',strings(0,1),'observerWarnings',strings(0,1));
                    obj.TelemetryHub.ingestAcceptanceResult(acceptance);
                    obj.stage("summary_validation","PASSED",1,"Synthetic acceptance complete.");
                    obj.setState("COMPLETED","Result");
            end
        end
        function generateSamples(obj)
            if obj.SimulatedSeconds<13, return; end
            target=floor(obj.SimulatedSeconds*100)+1;
            eventTypes=["BRAKING_CANDIDATE","TURN_LEFT_CANDIDATE","VERTICAL_SHOCK_CANDIDATE"];
            eventTimes=[20 30 40];
            while obj.NextSampleIndex<=target
                t=(obj.NextSampleIndex-1)/100;
                obj.TelemetryHub.ingestSample(obj.sample(t,obj.NextSampleIndex));
                if obj.EventIndex<=3 && t>=eventTimes(obj.EventIndex)
                    event=obj.event(eventTypes(obj.EventIndex),t,obj.NextSampleIndex,obj.EventIndex);
                    obj.TelemetryHub.ingestEventStarted(event); obj.TelemetryHub.ingestEventCompleted(event);
                    obj.EventIndex=obj.EventIndex+1;
                end
                obj.NextSampleIndex=obj.NextSampleIndex+1;
            end
        end
        function ingestRecordingGuard(obj)
            count=obj.NextSampleIndex-1;
            recording=struct('enabled',true,'status',"controlled_stop",'sessionId',"synthetic", ...
                'directory',"synthetic",'samplesWritten',count,'bytesWritten',count*256, ...
                'estimatedBufferedBytes',0,'maximumSessionBytes',count*256,'freeDiskBytes',2^30, ...
                'minimumFreeDiskBytes',2^30,'durationSeconds',obj.SimulatedSeconds, ...
                'maximumDurationSeconds',obj.SimulationDurationSeconds,'stopReason',"maximum_recording_duration");
            status=struct('lifecycleState',"STOP_DEFERRED",'callbackStats',struct('sessionId',1, ...
                'received',count,'buffered',0,'capacity',4096,'overflowDropped',0,'coalesced',0, ...
                'staleSessionDropped',0,'lastSequence',count),'samplesProcessed',count, ...
                'acquisitionDurationSeconds',obj.SimulatedSeconds,'recording',recording, ...
                'activeEvents',struct.empty(0,1),'dataQuality',struct('lateSamples',1), ...
                'currentCallbackAgeMs',24,'maximumCallbackAgeMs',24);
            obj.TelemetryHub.ingestMonitorStatus(status);
        end
        function finishSimulation(obj)
            obj.IsSimulationRunning=false; obj.IsSimulationComplete=true; obj.Summary=obj.makeSummary(true);
            obj.stopSimulationTimer();
        end
        function summary=makeSummary(obj,success)
            summary=struct('success',success,'synthetic',true,'durationSeconds',obj.SimulationDurationSeconds, ...
                'events',max(0,obj.EventIndex-1),'warningShown',~isempty(obj.WarningHistory), ...
                'safeStop',any(obj.TransitionHistory=="STOPPED"),'acceptanceCompleted',obj.State=="COMPLETED");
        end
        function setState(obj,state,stage)
            obj.State=string(state); obj.CurrentStage=string(stage); obj.TransitionHistory(end+1,1)=obj.State;
            obj.TelemetryHub.ingestState(obj.getStatus());
        end
        function stage(obj,name,state,progress,message)
            obj.CurrentStage=string(name); obj.TelemetryHub.ingestStage(struct( ...
                'timestamp',datetime('now','TimeZone','UTC'),'type',"stage_completed", ...
                'stage',string(name),'state',string(state),'progress',progress, ...
                'message',string(message),'payload',struct(),'startedAt',datetime('now','TimeZone','UTC'), ...
                'completedAt',datetime('now','TimeZone','UTC'),'elapsedSeconds',0));
        end
        function captureTimerError(obj,event)
            message="Synthetic timer error";
            try, message=string(event.Data.message); catch, end
            obj.TimerErrors(end+1,1)=message; obj.IsSimulationRunning=false; obj.stopSimulationTimer();
        end
        function stopSimulationTimer(obj)
            if isempty(obj.SimulationTimer), return; end
            value=obj.SimulationTimer; obj.SimulationTimer=[];
            try, if isvalid(value), stop(value); delete(value); end, catch, end
        end
        function s=sample(~,t,k)
            braking=-3.2*exp(-((t-20)/1.5)^2); turn=2.5*exp(-((t-30)/2)^2); shock=5*exp(-((t-40)/.15)^2);
            s=struct('elapsedSeconds',t,'sequenceNumber',uint64(k),'longitudinalRaw',braking+.08*sin(t*9), ...
                'longitudinalFiltered',braking,'lateralRaw',turn+.05*cos(t*7),'lateralFiltered',turn, ...
                'verticalRaw',shock+.03*sin(t*5),'verticalFiltered',shock,'yawRateRaw',turn*12, ...
                'yawRateFiltered',turn*12,'longitudinalJerk',-braking,'lateralJerk',turn/2, ...
                'verticalJerk',shock*3,'dataQuality',double(t<45)+.65*double(t>=45), ...
                'callbackAgeMs',4+20*double(t>=45),'effectiveFrequencyHz',50);
        end
        function e=event(~,type,t,k,index)
            e=struct('eventId',"SYN-"+index,'type',type,'startTimestamp',t,'startElapsedSeconds',t, ...
                'durationSeconds',1.2,'peakAcceleration',3+index,'peakJerk',7+index, ...
                'peakYawRate',20+index,'sampleCount',120,'dataQuality',.9, ...
                'terminationReason',"threshold",'status',"completed",'startSequence',uint64(k));
        end
    end
end
