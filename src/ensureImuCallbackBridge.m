function bridge = ensureImuCallbackBridge()
%ENSUREIMUCALLBACKBRIDGE Load and instantiate the Java callback bridge.
%   The bridge avoids MATLAB Java Bean callbacks, which are broken on some
%   newer MATLAB/JVM combinations, while still consuming the official
%   Tinkerforge AllDataListener callback.

outputDirectory = getImuCallbackBridgePath();
dynamicPath = javaclasspath('-dynamic');
if ~any(strcmp(dynamicPath, outputDirectory)), javaaddpath(outputDirectory); end
config = getImuConfig();
bridge = javaObject('bus.imu.ImuAllDataBuffer', ...
    int32(config.callbackBufferCapacity));
end
