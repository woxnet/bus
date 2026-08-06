classdef SyntheticBusDrivingSystemController < handle
%SYNTHETICBUSDRIVINGSYSTEMCONTROLLER Hardware-free dashboard demonstration source.
    properties(SetAccess=private)
        TelemetryHub
        State="IDLE"
        CurrentStage=""
        SimulatedSeconds=0
    end
    methods
        function obj=SyntheticBusDrivingSystemController(config)
            if nargin<1, config=getBusDrivingSystemDashboardConfig(); end
            obj.TelemetryHub=BusDrivingSystemTelemetryHub(config);
        end
        function summary=simulate(obj,durationSeconds)
            if nargin<2, durationSeconds=60; end
            stages=["Bootstrap","Preflight","Calibration","Verification","Realtime","Recording","Stopping","Result"];
            for k=1:numel(stages), obj.stage(stages(k),"PASSED",1,stages(k)+" completed."); end
            obj.State="CALIBRATION_REQUIRED"; obj.CurrentStage="Calibration";
            obj.TelemetryHub.ingestState(obj.getStatus());
            obj.TelemetryHub.ingestCalibration(struct('state',"REQUIRED",'phase',"operator",'progress',0, ...
                'samplesRequired',500,'samplesCollected',0,'samplesRemaining',500));
            obj.State="CALIBRATING"; obj.TelemetryHub.ingestCalibration(struct('state',"SAMPLING", ...
                'phase',"stationary",'progress',.65,'samplesRequired',500,'samplesCollected',325,'samplesRemaining',175));
            obj.State="CALIBRATION_VERIFYING"; obj.TelemetryHub.ingestCalibration(struct('state',"VERIFYING", ...
                'phase',"verification",'progress',.9,'quality',.96,'verification',.94));
            obj.State="STREAMING"; obj.CurrentStage="Realtime";
            eventTypes=["BRAKING_CANDIDATE","TURN_LEFT_CANDIDATE","VERTICAL_SHOCK_CANDIDATE"];
            eventTimes=[15 31 47]; eventIndex=1;
            count=max(1,round(durationSeconds*100));
            for k=1:count
                t=(k-1)/100; obj.SimulatedSeconds=t;
                sample=obj.sample(t,k); obj.TelemetryHub.ingestSample(sample);
                if eventIndex<=3 && t>=eventTimes(eventIndex)
                    event=obj.event(eventTypes(eventIndex),t,k,eventIndex);
                    obj.TelemetryHub.ingestEventStarted(event); obj.TelemetryHub.ingestEventCompleted(event);
                    eventIndex=eventIndex+1;
                end
            end
            warningInfo=struct('type',"SYNTHETIC_DATA_QUALITY",'message',"Synthetic callback age warning.");
            obj.TelemetryHub.ingestWarning(warningInfo);
            recording=struct('enabled',true,'status',"controlled_stop",'sessionId',"synthetic", ...
                'directory',"synthetic",'samplesWritten',count,'bytesWritten',count*256, ...
                'estimatedBufferedBytes',0,'maximumSessionBytes',count*256, ...
                'freeDiskBytes',2^30,'minimumFreeDiskBytes',2^30,'durationSeconds',durationSeconds, ...
                'maximumDurationSeconds',durationSeconds,'stopReason',"maximum_recording_duration");
            status=struct('lifecycleState',"STOP_DEFERRED",'callbackStats',struct('sessionId',1, ...
                'received',count,'buffered',0,'capacity',4096,'overflowDropped',0,'coalesced',0, ...
                'staleSessionDropped',0,'lastSequence',count),'samplesProcessed',count, ...
                'acquisitionDurationSeconds',durationSeconds,'recording',recording, ...
                'activeEvents',struct.empty(0,1),'dataQuality',struct('lateSamples',1));
            obj.TelemetryHub.ingestMonitorStatus(status);
            stopStates=["STOP_REQUESTED","QUIESCING","DRAINING_TAIL","FINALIZING_RECORDING","RELEASING_STREAM","STOPPED"];
            for state=stopStates, obj.State=state; obj.CurrentStage="Stopping"; obj.TelemetryHub.ingestState(obj.getStatus()); end
            obj.State="COMPLETED"; obj.CurrentStage="Result"; obj.stage("summary_validation","PASSED",1,"Synthetic acceptance complete.");
            summary=struct('success',true,'synthetic',true,'durationSeconds',durationSeconds, ...
                'events',3,'warningShown',true,'safeStop',true,'acceptanceCompleted',true);
        end
        function status=getStatus(obj)
            status=struct('lifecycleState',obj.State,'currentStage',obj.CurrentStage, ...
                'stageProgress',1,'message',"SYNTHETIC DEMONSTRATION - NOT A HARDWARE ACCEPTANCE", ...
                'mode',"synthetic",'startedAt',NaT,'completedAt',NaT,'lastError',[], ...
                'isRealtimeRunning',obj.State=="STREAMING");
        end
        function snapshot=getTelemetrySnapshot(obj)
            obj.TelemetryHub.ingestState(obj.getStatus()); snapshot=obj.TelemetryHub.getSnapshot();
            snapshot.checkoutCommit="SYNTHETIC"; snapshot.busId="SYNTHETIC BUS"; snapshot.imuUid="SYNTHETIC IMU";
        end
        function startSystem(obj), obj.State="BOOTSTRAP"; end
        function runPreflight(obj), obj.State="PREFLIGHT"; end
        function startCalibration(obj), obj.State="CALIBRATING"; end
        function confirmCurrentStep(~), end
        function rejectCurrentStep(~), end
        function startRealtime(obj), obj.State="STREAMING"; end
        function summary=stopRealtime(obj), obj.State="STOPPED"; summary=struct('success',true); end
        function runFullAcceptance(obj), obj.State="COMPLETED"; end
        function close(obj), if obj.State=="STREAMING", obj.stopRealtime(); end, end
    end
    methods(Access=private)
        function stage(obj,name,state,progress,message)
            obj.CurrentStage=string(name); obj.TelemetryHub.ingestStage(struct( ...
                'timestamp',datetime('now','TimeZone','UTC'),'type',"stage_completed", ...
                'stage',string(name),'state',string(state),'progress',progress, ...
                'message',string(message),'payload',struct()));
        end
        function s=sample(~,t,k)
            braking=-3.2*exp(-((t-15)/1.5)^2); turn=2.5*exp(-((t-31)/2)^2); shock=5*exp(-((t-47)/.15)^2);
            s=struct('elapsedSeconds',t,'sequenceNumber',uint64(k),'longitudinalRaw',braking+.08*sin(t*9), ...
                'longitudinalFiltered',braking,'lateralRaw',turn+.05*cos(t*7),'lateralFiltered',turn, ...
                'verticalRaw',shock+.03*sin(t*5),'verticalFiltered',shock,'yawRateRaw',turn*12, ...
                'yawRateFiltered',turn*12,'longitudinalJerk',-braking,'lateralJerk',turn/2, ...
                'verticalJerk',shock*3,'dataQuality',double(t<45)+.65*double(t>=45), ...
                'callbackAgeMs',4+20*double(t>=45));
        end
        function e=event(~,type,t,k,index)
            e=struct('eventId',"SYN-"+index,'type',type,'startTimestamp',t, ...
                'startElapsedSeconds',t, ...
                'durationSeconds',1.2,'peakAcceleration',3+index,'peakJerk',7+index, ...
                'peakYawRate',20+index,'sampleCount',120,'dataQuality',.9, ...
                'terminationReason',"threshold",'status',"completed",'startSequence',uint64(k));
        end
    end
end
