classdef RealtimeCallbackProbe < handle
    properties
        SampleCount=0
        StartedCount=0
        CompletedCount=0
        WarningCount=0
        ErrorCount=0
        StoppedCount=0
        ThrowOnSample=false
        LastWarning=[]
    end
    methods
        function sample(obj,~,~)
            obj.SampleCount=obj.SampleCount+1;
            if obj.ThrowOnSample, error('Test:CallbackFailure','Injected callback failure.'); end
        end
        function started(obj,~,~), obj.StartedCount=obj.StartedCount+1; end
        function completed(obj,~,~), obj.CompletedCount=obj.CompletedCount+1; end
        function warning(obj,~,info), obj.WarningCount=obj.WarningCount+1; obj.LastWarning=info; end
        function error(obj,~,~), obj.ErrorCount=obj.ErrorCount+1; end
        function stopped(obj,~,~), obj.StoppedCount=obj.StoppedCount+1; end
    end
end
