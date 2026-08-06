classdef MutableUtcClock < handle
    properties
        Value
    end
    methods
        function obj=MutableUtcClock(value)
            obj.Value=value;
        end
        function value=now(obj)
            value=obj.Value;
        end
        function advance(obj,duration)
            obj.Value=obj.Value+duration;
        end
    end
end
