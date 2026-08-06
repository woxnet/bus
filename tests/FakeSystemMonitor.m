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
    end
    properties(SetAccess=private)
        DrainCalls=0
    end
    methods
        function start(obj), obj.IsRunning=true; obj.lifecycle("STREAMING"); end
        function summary=stop(obj,varargin)
            for state=["STOP_DEFERRED","STOPPING","QUIESCING","DRAINING_TAIL","FINAL_STATS", ...
                    "FINALIZING_EVENTS","FINALIZING_RECORDING","CLEARING_BUFFER","RELEASING_OWNER"]
                obj.lifecycle(state);
            end
            obj.IsRunning=false; obj.lifecycle("STOPPED"); summary=struct('success',true,'stopReason',"operator_stop");
            if ~isempty(obj.OnStopped), obj.OnStopped(obj,summary); end
        end
        function status=getStatus(obj)
            lifecycle="STOPPED"; if obj.IsRunning, lifecycle="STREAMING"; end
            status=struct('lifecycleState',lifecycle, ...
                'isRunning',obj.IsRunning,'isStopping',false,'batchProcessing',false, ...
                'streamSessionId',1,'streamOwner',"RealtimeDrivingMonitor", ...
                'samplesProcessed',0,'eventsDetected',0,'activeEvents',struct.empty(0,1), ...
                'latestEvent',[],'callbackStats',struct('sessionId',1,'received',0,'buffered',0, ...
                'capacity',10,'overflowDropped',0,'coalesced',0,'staleSessionDropped',0,'lastSequence',0), ...
                'dataQuality',struct(),'recording',struct(),'stopReason',"", ...
                'acquisitionDurationSeconds',0,'shutdownDurationSeconds',0);
            if ~obj.IsRunning, status.lifecycleState="STOPPED"; end
        end
    end
    methods(Access=private)
        function lifecycle(obj,state)
            status=obj.getStatus(); status.lifecycleState=state;
            if ~isempty(obj.OnLifecycleChanged), obj.OnLifecycleChanged(obj,status); end
        end
    end
end
