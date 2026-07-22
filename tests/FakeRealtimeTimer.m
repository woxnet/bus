classdef FakeRealtimeTimer < handle
    properties
        Running="off"
        FailOnStart=false
        StopCount=0
        DeleteCount=0
        TimerFcn=[]
    end
    methods
        function obj=FakeRealtimeTimer(failOnStart,varargin)
            obj.FailOnStart=logical(failOnStart);
            for index=1:2:numel(varargin)
                if strcmpi(varargin{index},'TimerFcn'), obj.TimerFcn=varargin{index+1}; end
            end
        end
        function start(obj)
            if obj.FailOnStart, error('Test:TimerStartFailure','Injected timer start failure.'); end
            obj.Running="on";
        end
        function stop(obj), obj.StopCount=obj.StopCount+1; obj.Running="off"; end
        function fire(obj), obj.TimerFcn([],[]); end
        function delete(obj), obj.DeleteCount=obj.DeleteCount+1; obj.Running="off"; end
    end
end
