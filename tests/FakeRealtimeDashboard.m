classdef FakeRealtimeDashboard < handle
    properties
        FailOnOpen=false
        IsOpen=false
        CloseCount=0
        FailOnUpdate=false
        UpdateCount=0
    end
    methods
        function obj=FakeRealtimeDashboard(failOnOpen), obj.FailOnOpen=failOnOpen; end
        function open(obj)
            if obj.FailOnOpen, error('Test:DashboardOpenFailure','Injected dashboard failure.'); end
            obj.IsOpen=true;
        end
        function update(obj,~)
            obj.UpdateCount=obj.UpdateCount+1;
            if obj.FailOnUpdate, error('Test:DashboardUpdateFailure','Injected dashboard update failure.'); end
        end
        function close(obj), obj.IsOpen=false; obj.CloseCount=obj.CloseCount+1; end
    end
end
