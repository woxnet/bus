function [outputDirectory, buildInfo] = buildImuCallbackBridge(options)
%BUILDIMUCALLBACKBRIDGE Reproducibly compile the bounded Java listener bridge.
%   The optional scalar OPTIONS structure is intended for isolated tests.

root = fileparts(fileparts(mfilename('fullpath')));
defaults = struct( ...
    'jarFile', fullfile(root, 'lib', 'Tinkerforge.jar'), ...
    'sourceFile', fullfile(root, 'java', 'bus', 'imu', 'ImuAllDataBuffer.java'), ...
    'outputDirectory', fullfile(root, '.build', 'java'), ...
    'javacCommand', 'javac', ...
    'commandRunner', @system);
if nargin < 1, options = struct(); end
options = mergeOptions(defaults, options);
outputDirectory = char(options.outputDirectory);
classFile = fullfile(outputDirectory, 'bus', 'imu', 'ImuAllDataBuffer.class');
markerFile = fullfile(outputDirectory, '.imu-callback-build');

if ~isfile(options.sourceFile)
    error('IMU:CallbackBridgeSourceMissing', ...
        'Java bridge source was not found: %s', options.sourceFile);
end
if ~isfile(options.jarFile)
    error('IMU:TinkerforgeJarMissing', ...
        'Tinkerforge JAR was not found: %s', options.jarFile);
end

versionCommand = sprintf('"%s" -version 2>&1', options.javacCommand);
[versionStatus, versionOutput] = options.commandRunner(versionCommand);
if versionStatus ~= 0
    error('IMU:JavaCompilerUnavailable', ...
        'javac is unavailable. Install JDK 8 or newer. Details: %s', versionOutput);
end
majorVersion = parseJavacMajorVersion(versionOutput);
compilerFlags = selectJava8CompilerFlags(majorVersion);
sourceHash = fileSha256(options.sourceFile);
jarHash = fileSha256(options.jarFile);
signature = sprintf([ ...
    'compiler=%s\nmajor=%d\nflags=%s\n', ...
    'source=%s|sha256=%s\njar=%s|sha256=%s\n'], ...
    strtrim(versionOutput), majorVersion, compilerFlags, ...
    char(options.sourceFile), sourceHash, ...
    char(options.jarFile), jarHash);

previousSignature = "";
if isfile(markerFile)
    previousSignature = replace(string(fileread(markerFile)), ...
        string(char([13 10])), string(newline));
end
needsBuild = ~isfile(classFile) || previousSignature ~= string(signature);
command = sprintf('"%s" %s -cp "%s" -d "%s" "%s"', ...
    options.javacCommand, compilerFlags, options.jarFile, ...
    outputDirectory, options.sourceFile);
if needsBuild
    if ~isfolder(outputDirectory), mkdir(outputDirectory); end
    [status, output] = options.commandRunner(command);
    if status ~= 0
        error('IMU:CallbackBridgeBuildFailed', ...
            'Java callback bridge compilation failed: %s', output);
    end
    writeText(markerFile, signature);
end

buildInfo = struct('javacVersion', string(strtrim(versionOutput)), ...
    'javacMajorVersion', majorVersion, 'compilerFlags', string(compilerFlags), ...
    'sourceSha256', string(sourceHash), 'jarSha256', string(jarHash), ...
    'command', string(command), 'classFile', string(classFile), ...
    'markerFile', string(markerFile), 'rebuilt', logical(needsBuild));
end

function options = mergeOptions(defaults, custom)
if ~isstruct(custom) || ~isscalar(custom)
    error('IMU:InvalidBuildOptions', 'Build options must be a scalar structure.');
end
options = defaults;
names = fieldnames(custom);
unknown = setdiff(names, fieldnames(defaults));
if ~isempty(unknown)
    error('IMU:InvalidBuildOptions', 'Unknown build option: %s', unknown{1});
end
for index = 1:numel(names), options.(names{index}) = custom.(names{index}); end
end

function writeText(filename, content)
fileId = fopen(filename, 'w');
if fileId < 0, error('IMU:CallbackBridgeBuildFailed', 'Cannot write %s.', filename); end
cleanup = onCleanup(@()fclose(fileId));
fprintf(fileId, '%s', content);
clear cleanup;
end
