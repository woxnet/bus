function status = loadTinkerforgeBindings(jarFile)
%LOADTINKERFORGEBINDINGS Validate and load official Tinkerforge bindings.
%   STATUS = LOADTINKERFORGEBINDINGS(JARFILE) verifies both the archive and
%   required class entries before adding it to the Java path. Normal errors
%   are returned and warned without blocking hardware-independent tests.

info = inspectTinkerforgeJar(jarFile);
status = struct('available', false, 'jarInfo', info, ...
    'classesAvailable', false, 'restartRecommended', false, ...
    'errors', strings(0, 1), 'warnings', strings(0, 1));
if ~info.exists || info.fileSizeBytes <= 0 || ~info.signatureValid
    status = fail(status, "Tinkerforge bindings отсутствуют, пусты или повреждены: " + ...
        string(jarFile));
    return;
end

try
    if ~tinkerforgeJarHasRequiredClasses(jarFile)
        status = fail(status, ...
            "JAR не содержит IPConnection и BrickIMUV2 из MATLAB bindings Tinkerforge.");
        return;
    end
    dynamicPath = javaclasspath('-dynamic');
    staticPath = javaclasspath('-static');
    bridgePath = getImuCallbackBridgePath();
    allPaths = [dynamicPath(:); staticPath(:)];
    alreadyLoaded = any(strcmp(allPaths, char(jarFile)));
    conflicting = any(contains(string(allPaths), "Tinkerforge.jar", ...
        'IgnoreCase', true) & ~strcmp(string(allPaths), string(jarFile)));
    status.restartRecommended = logical(conflicting);
    pathsToAdd = strings(0, 1);
    if ~alreadyLoaded, pathsToAdd(end+1, 1) = string(jarFile); end
    if ~any(strcmp(allPaths, bridgePath)), pathsToAdd(end+1, 1) = string(bridgePath); end
    if ~isempty(pathsToAdd), javaaddpath(cellstr(pathsToAdd)); end

    ipConnection = javaObject('com.tinkerforge.IPConnection');
    device = javaObject('com.tinkerforge.BrickIMUV2', ...
        char(getImuConfig().uid), ipConnection);
    status.classesAvailable = ~isempty(ipConnection) && ~isempty(device);
    status.available = status.classesAvailable;
    if status.restartRecommended
        status.warnings(end+1, 1) = ...
            "После замены уже загруженного JAR рекомендуется перезапустить MATLAB.";
        warning('IMU:TinkerforgeRestartRecommended', '%s', status.warnings(end));
    end
catch exception
    status.restartRecommended = true;
    status = fail(status, "Не удалось загрузить Tinkerforge bindings: " + ...
        string(exception.message));
end
end

function status = fail(status, message)
status.errors(end+1, 1) = string(message);
status.warnings(end+1, 1) = string(message);
warning('IMU:TinkerforgeBindingsUnavailable', '%s', message);
end
