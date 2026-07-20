function [jarFile, buildInfo] = buildImuCallbackBridgeJar()
%BUILDIMUCALLBACKBRIDGEJAR Rebuild the distributable Java 8 bridge JAR.
%   This developer command requires a JDK. Normal runtime uses the checked-in
%   JAR and does not invoke javac.

root = fileparts(fileparts(mfilename('fullpath')));
[classesDirectory, buildInfo] = buildImuCallbackBridge();
outputDirectory = fullfile(root, 'lib-generated');
if ~isfolder(outputDirectory), mkdir(outputDirectory); end
jarFile = fullfile(outputDirectory, 'imu-callback-bridge.jar');

[toolStatus, toolOutput] = system('jar --version');
if toolStatus ~= 0
    error('IMU:JavaArchiverUnavailable', ...
        'The JDK jar tool is unavailable: %s', toolOutput);
end
command = sprintf('jar cf "%s" -C "%s" bus', jarFile, classesDirectory);
[status, output] = system(command);
if status ~= 0
    error('IMU:CallbackBridgePackagingFailed', ...
        'Java callback bridge packaging failed: %s', output);
end
fprintf('Created %s\n', jarFile);
end
