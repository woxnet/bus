function bridge = ensureImuCallbackBridge()
%ENSUREIMUCALLBACKBRIDGE Build and instantiate the Java callback bridge.
%   The bridge avoids MATLAB Java Bean callbacks, which are broken on some
%   newer MATLAB/JVM combinations, while still consuming the official
%   Tinkerforge AllDataListener callback.

outputDirectory = buildImuCallbackBridge();
dynamicPath = javaclasspath('-dynamic');
if ~any(strcmp(dynamicPath, outputDirectory)), javaaddpath(outputDirectory); end
bridge = javaObject('bus.imu.ImuAllDataBuffer');
end
