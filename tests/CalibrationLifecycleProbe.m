classdef CalibrationLifecycleProbe < handle
    properties
        CloseCalls=0
        CancelledCount=0
        ErrorCount=0
    end
    methods
        function closeDuringSampling(obj,controller,status)
            if obj.CloseCalls==0 && (status.state=="STATIONARY_SAMPLING" || ...
                    status.phase=="verification_stationary")
                obj.CloseCalls=obj.CloseCalls+1;
                controller.close();
            end
        end
        function cancelled(obj,~,~), obj.CancelledCount=obj.CancelledCount+1; end
        function error(obj,~,~), obj.ErrorCount=obj.ErrorCount+1; end
    end
end
