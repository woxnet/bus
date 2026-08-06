classdef MutableMonotonicClock < handle
    properties
        Value=0
    end
    methods
        function value=start(~), value=uint64(1); end
        function value=elapsed(obj,~), value=obj.Value; end
        function advance(obj,duration), obj.Value=obj.Value+double(duration); end
    end
end
