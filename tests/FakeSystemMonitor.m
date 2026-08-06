classdef FakeSystemMonitor < handle
    properties
        IsRunning=false
        OnLifecycleChanged=[]
        OnSample=[]
        OnEventStarted=[]
        OnEventCompleted=[]
        OnWarning=[]
        OnError=[]
        OnStopped=[]
        StartAction=@()[]
        StopAction=@()[]
        Received=0
        Buffered=0
        CallbackAgeMs=0
        MaximumCallbackAgeMs=0
        SamplesWritten=0
        BytesWritten=0
        RecordingDurationSeconds=0
        FreeDiskBytes=NaN
        RecordingStopReason=""
        RecordingEnabled=true
    end
    properties(SetAccess=private)
        DrainCalls=0
        StatusCalls=0
    end
    methods
        function start(obj), obj.StartAction(); obj.IsRunning=true; obj.lifecycle("STREAMING"); end
        function summary=stop(obj,varargin)
            obj.StopAction();
            for state=["STOP_DEFERRED","STOPPING","QUIESCING","DRAINING_TAIL","FINAL_STATS", ...
                    "FINALIZING_EVENTS","FINALIZING_RECORDING","CLEARING_BUFFER","RELEASING_OWNER"]
                obj.lifecycle(state);
            end
            obj.IsRunning=false; obj.lifecycle("STOPPED"); summary=struct('success',true,'stopReason',"operator_stop");
            if ~isempty(obj.OnStopped), obj.OnStopped(obj,summary); end
        end
        function status=getStatus(obj)
            obj.StatusCalls=obj.StatusCalls+1;
            lifecycle="STOPPED"; if obj.IsRunning, lifecycle="STREAMING"; end
            status=struct('lifecycleState',lifecycle, ...
                'isRunning',obj.IsRunning,'isStopping',false,'batchProcessing',false, ...
                'streamSessionId',1,'streamOwner',"RealtimeDrivingMonitor", ...
                'samplesProcessed',0,'eventsDetected',0,'activeEvents',struct.empty(0,1), ...
                'latestEvent',[],'callbackStats',struct('sessionId',1,'received',obj.Received,'buffered',obj.Buffered, ...
                'capacity',10,'overflowDropped',0,'coalesced',0,'staleSessionDropped',0,'lastSequence',0), ...
                'dataQuality',struct('missingSamples',0,'duplicateSamples',0,'invalidSamples',0, ...
                    'lateSamples',0,'overflowDropped',0,'staleSessionDropped',0, ...
                    'maximumCallbackAgeMs',obj.MaximumCallbackAgeMs), ...
                'recording',struct('enabled',obj.RecordingEnabled,'status',"recording", ...
                    'samplesWritten',obj.SamplesWritten,'bytesWritten',obj.BytesWritten, ...
                    'estimatedBufferedBytes',0,'durationSeconds',obj.RecordingDurationSeconds, ...
                    'freeDiskBytes',obj.FreeDiskBytes,'stopReason',obj.RecordingStopReason), ...
                'stopReason',obj.RecordingStopReason,'acquisitionDurationSeconds',obj.RecordingDurationSeconds, ...
                'shutdownDurationSeconds',0,'currentCallbackAgeMs',obj.CallbackAgeMs, ...
                'maximumCallbackAgeMs',obj.MaximumCallbackAgeMs);
            if ~obj.IsRunning, status.lifecycleState="STOPPED"; end
        end
        function resetStatusCalls(obj), obj.StatusCalls=0; end
    end
    methods(Access=private)
        function lifecycle(obj,state)
            status=obj.getStatus(); status.lifecycleState=state;
            if ~isempty(obj.OnLifecycleChanged), obj.OnLifecycleChanged(obj,status); end
        end
    end
end
