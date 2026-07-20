function status = loadTinkerforgeBindings(jarFile)
%LOADTINKERFORGEBINDINGS Validate and add a local JAR to the Java path.
%   STATUS = LOADTINKERFORGEBINDINGS(JARFILE) never throws for a missing,
%   empty or malformed JAR. It returns STATUS.available and emits warning
%   IMU:TinkerforgeBindingsUnavailable with the expected path.

info = inspectTinkerforgeJar(jarFile);
status = struct('available', false, 'jarInfo', info, ...
    'destinationFile', string(jarFile));
if ~info.exists || info.fileSizeBytes <= 0 || ~info.signatureValid
    warning('IMU:TinkerforgeBindingsUnavailable', ...
        ['Tinkerforge bindings отсутствуют, пусты или повреждены. ', ...
         'Ожидаемый файл: %s'], char(jarFile));
    return;
end

dynamicPath = javaclasspath('-dynamic');
staticPath = javaclasspath('-static');
if ~any(strcmp(dynamicPath, jarFile)) && ~any(strcmp(staticPath, jarFile))
    javaaddpath(jarFile);
end
status.available = true;
end
