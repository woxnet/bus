classdef MockShutdownImu < handle
    properties
        Log
    end

    methods
        function obj = MockShutdownImu(log)
            obj.Log = log;
        end
        function stop(obj), obj.record("stop"); end
        function clearCallbackBuffer(obj), obj.record("clearCallbackBuffer"); end
        function disconnect(obj), obj.record("disconnect"); end
        function delete(obj), obj.record("delete"); end
    end

    methods (Access = private)
        function record(obj, value)
            if ~isempty(obj.Log), obj.Log.Calls(end+1, 1) = value; end
        end
    end
end
