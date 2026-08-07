classdef FakeSystemImu < handle
    properties
        UID="synthetic-imu"
        DisconnectCalls=0
    end
    methods
        function disconnect(obj), obj.DisconnectCalls=obj.DisconnectCalls+1; end
    end
end
