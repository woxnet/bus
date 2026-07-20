function outputDirectory = buildImuCallbackBridge()
%BUILDIMUCALLBACKBRIDGE Compile the Java listener bridge when needed.
root = fileparts(fileparts(mfilename('fullpath')));
jarFile = fullfile(root, 'lib', 'Tinkerforge.jar');
sourceFile = fullfile(root, 'java', 'bus', 'imu', 'ImuAllDataBuffer.java');
outputDirectory = fullfile(root, '.build', 'java');
classFile = fullfile(outputDirectory, 'bus', 'imu', 'ImuAllDataBuffer.class');
releaseMarker = fullfile(outputDirectory, '.release8');
if ~isfile(sourceFile), error('IMU:CallbackBridgeSourceMissing', 'Не найден Java bridge: %s', sourceFile); end
if ~isfolder(outputDirectory), mkdir(outputDirectory); end
needsBuild = ~isfile(classFile) || ~isfile(releaseMarker) || ...
    dir(classFile).datenum < dir(sourceFile).datenum;
if needsBuild
    command = sprintf('javac --release 8 -cp "%s" -d "%s" "%s"', ...
        jarFile, outputDirectory, sourceFile);
    [status, output] = system(command);
    if status ~= 0, error('IMU:CallbackBridgeBuildFailed', 'Не удалось собрать callback bridge: %s', output); end
    fileId = fopen(releaseMarker, 'w');
    if fileId >= 0, fclose(fileId); end
end
end
