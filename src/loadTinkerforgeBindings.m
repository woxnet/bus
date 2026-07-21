function status = loadTinkerforgeBindings(jarFile, dependencies)
%LOADTINKERFORGEBINDINGS Idempotently validate and load IMU Java classes.
%   This function never constructs IPConnection or BrickIMUV2 instances.

if nargin < 2, dependencies = struct(); end
dependencies = mergeDependencies(dependencies);
info = inspectTinkerforgeJar(jarFile);
expectedJar = canonicalPath(jarFile);
status = initialStatus(info, expectedJar, '');

if ~info.exists || info.fileSizeBytes <= 0 || ~info.signatureValid
    status = failUnavailable(status, ...
        "Tinkerforge bindings are missing, empty, or invalid: " + string(jarFile));
    return;
end
if ~tinkerforgeJarHasRequiredClasses(jarFile)
    status = failUnavailable(status, ...
        "Tinkerforge JAR does not contain IPConnection and BrickIMUV2.");
    return;
end
try
    bridgePath = char(dependencies.buildBridge());
catch exception
    status = failUnavailable(status, ...
        "IMU callback bridge could not be prepared: " + string(exception.message));
    return;
end
expectedBridge = canonicalPath(bridgePath);
status.expectedBridgeSource = string(expectedBridge);
if ~(isfile(bridgePath) || isfolder(bridgePath))
    status = failUnavailable(status, ...
        "IMU callback bridge is unavailable: " + string(bridgePath));
    return;
end

paths = dependencies.javaClassPath();
paths = canonicalPaths(paths);
status.jarAlreadyOnPath = any(strcmpi(paths, expectedJar));
status.bridgeAlreadyOnPath = any(strcmpi(paths, expectedBridge));
status.classpathChangeRequired = ...
    ~status.jarAlreadyOnPath || ~status.bridgeAlreadyOnPath;

[ipClass, ipLoaded] = tryClass(dependencies, 'com.tinkerforge.IPConnection');
[imuClass, imuLoaded] = tryClass(dependencies, 'com.tinkerforge.BrickIMUV2');
[bridgeClass, bridgeLoaded] = tryClass(dependencies, 'bus.imu.ImuAllDataBuffer');
status.tinkerforgeClassesLoaded = ipLoaded || imuLoaded;
status.bridgeClassLoaded = bridgeLoaded;
status.ipConnectionCodeSource = classSource(dependencies, ipClass, ipLoaded);
status.brickImuCodeSource = classSource(dependencies, imuClass, imuLoaded);
status.bridgeCodeSource = classSource(dependencies, bridgeClass, bridgeLoaded);

if status.classpathChangeRequired && ...
        (status.tinkerforgeClassesLoaded || status.bridgeClassLoaded)
    status = requireRestart(status);
    return;
end

if status.classpathChangeRequired
    additions = strings(0, 1);
    if ~status.jarAlreadyOnPath, additions(end+1, 1) = string(expectedJar); end
    if ~status.bridgeAlreadyOnPath, additions(end+1, 1) = string(expectedBridge); end
    dependencies.javaAddPath(cellstr(additions));
    status.javaAddPathCalled = true;
    status.pathsAdded = additions;
    status.jarAlreadyOnPath = true;
    status.bridgeAlreadyOnPath = true;
    status.classpathChangeRequired = false;
end

[ipClass, ipLoaded] = tryClass(dependencies, 'com.tinkerforge.IPConnection');
[imuClass, imuLoaded] = tryClass(dependencies, 'com.tinkerforge.BrickIMUV2');
[bridgeClass, bridgeLoaded] = tryClass(dependencies, 'bus.imu.ImuAllDataBuffer');
status.tinkerforgeClassesLoaded = ipLoaded && imuLoaded;
status.bridgeClassLoaded = bridgeLoaded;
status.ipConnectionCodeSource = classSource(dependencies, ipClass, ipLoaded);
status.brickImuCodeSource = classSource(dependencies, imuClass, imuLoaded);
status.bridgeCodeSource = classSource(dependencies, bridgeClass, bridgeLoaded);
status.loadedSourcesMatch = sourcesMatch(status, expectedJar, expectedBridge);
status.restartRequired = ~status.loadedSourcesMatch && ...
    (status.tinkerforgeClassesLoaded || status.bridgeClassLoaded);
status.restartRecommended = status.restartRequired;
status.classesAvailable = status.tinkerforgeClassesLoaded && ...
    status.bridgeClassLoaded;
status.available = status.classesAvailable && status.loadedSourcesMatch && ...
    ~status.restartRequired;
if status.restartRequired, status = requireRestart(status); end
end

function status = initialStatus(info, expectedJar, expectedBridge)
status = struct('available', false, 'jarInfo', info, ...
    'classesAvailable', false, 'jarAlreadyOnPath', false, ...
    'bridgeAlreadyOnPath', false, 'classpathChangeRequired', false, ...
    'tinkerforgeClassesLoaded', false, 'bridgeClassLoaded', false, ...
    'ipConnectionCodeSource', "", 'brickImuCodeSource', "", ...
    'bridgeCodeSource', "", 'expectedJarSource', string(expectedJar), ...
    'expectedBridgeSource', string(expectedBridge), ...
    'loadedSourcesMatch', false, 'restartRequired', false, ...
    'restartRecommended', false, 'errors', strings(0, 1), ...
    'warnings', strings(0, 1), 'javaAddPathCalled', false, ...
    'pathsAdded', strings(0, 1), ...
    'runtimeCheckTimestamp', datetime('now', 'TimeZone', 'UTC'));
end

function dependencies = mergeDependencies(custom)
defaults = struct('javaClassPath', @currentJavaClassPath, ...
    'javaAddPath', @(paths)javaaddpath(paths), ...
    'classForName', @matlabClassForName, ...
    'classCodeSource', @javaClassCodeSource, ...
    'buildBridge', @getImuCallbackBridgePath);
dependencies = defaults;
names = fieldnames(custom);
unknown = setdiff(names, fieldnames(defaults));
if ~isempty(unknown)
    error('IMU:InvalidRuntimeDependencies', ...
        'Unknown runtime dependency: %s.', unknown{1});
end
for index = 1:numel(names), dependencies.(names{index}) = custom.(names{index}); end
end

function classReference = matlabClassForName(name)
manager = javaMethod('getClassLoaderManager', ...
    'com.mathworks.jmi.ClassLoaderManager');
loader = manager.getCurrentClassLoader();
classReference = javaMethod('forName', 'java.lang.Class', ...
    char(name), true, loader);
end

function paths = currentJavaClassPath()
dynamicPaths = javaclasspath('-dynamic');
staticPaths = javaclasspath('-static');
paths = [dynamicPaths(:); staticPaths(:)];
end

function [classReference, loaded] = tryClass(dependencies, name)
classReference = [];
loaded = false;
try
    classReference = dependencies.classForName(name);
    loaded = true;
catch exception
    if ~isClassNotFound(exception), rethrow(exception); end
end
end

function result = isClassNotFound(exception)
text = string(exception.message) + " " + string(exception.identifier);
result = contains(text, "ClassNotFound", 'IgnoreCase', true) || ...
    contains(text, "not found", 'IgnoreCase', true) || ...
    contains(text, "undefined", 'IgnoreCase', true);
end

function source = classSource(dependencies, classReference, loaded)
if ~loaded, source = ""; return; end
source = string(canonicalPath(dependencies.classCodeSource(classReference)));
end

function source = javaClassCodeSource(classReference)
location = classReference.getProtectionDomain().getCodeSource().getLocation();
source = char(javaObject('java.io.File', location.toURI()).getCanonicalPath());
end

function match = sourcesMatch(status, expectedJar, expectedBridge)
match = status.tinkerforgeClassesLoaded && status.bridgeClassLoaded && ...
    strcmpi(char(status.ipConnectionCodeSource), expectedJar) && ...
    strcmpi(char(status.brickImuCodeSource), expectedJar) && ...
    strcmpi(char(status.bridgeCodeSource), expectedBridge);
end

function status = requireRestart(status)
status.available = false;
status.restartRequired = true;
status.restartRecommended = true;
message = sprintf(['Tinkerforge Java classes already loaded.\n', ...
    'Current sources: IPConnection=%s; BrickIMUV2=%s; bridge=%s.\n', ...
    'Expected sources: Tinkerforge=%s; bridge=%s.\n', ...
    'Close IMU objects and restart MATLAB before connecting the IMU.'], ...
    status.ipConnectionCodeSource, status.brickImuCodeSource, ...
    status.bridgeCodeSource, status.expectedJarSource, ...
    status.expectedBridgeSource);
status.errors(end+1, 1) = string(message);
status.warnings(end+1, 1) = string(message);
warning('IMU:JavaRestartRequired', '%s', message);
end

function status = failUnavailable(status, message)
status.errors(end+1, 1) = string(message);
status.warnings(end+1, 1) = string(message);
warning('IMU:TinkerforgeBindingsUnavailable', '%s', message);
end

function values = canonicalPaths(paths)
if ischar(paths) || isstring(paths), paths = cellstr(paths); end
values = cell(size(paths));
for index = 1:numel(paths), values{index} = canonicalPath(paths{index}); end
end

function value = canonicalPath(path)
if strlength(string(path)) == 0, value = ''; return; end
try
    value = char(javaObject('java.io.File', char(path)).getCanonicalPath());
catch
    value = char(path);
end
end
