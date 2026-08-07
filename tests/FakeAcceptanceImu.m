classdef FakeAcceptanceImu < handle
    properties
        Disconnected=false
    end
    methods
        function value=readOnce(~), value=struct(); end
        function value=getIdentity(~)
            value=struct('uid',"fake-uid",'firmwareVersion',[1 2 3]);
        end
        function value=getSensorFusionMode(~), value=1; end
        function disconnect(obj), obj.Disconnected=true; end
    end
end
