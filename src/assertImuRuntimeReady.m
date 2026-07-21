function status = assertImuRuntimeReady(dependencies, jarFile)
%ASSERTIMURUNTIMEREADY Fail before hardware objects are created if unsafe.

if nargin < 2
    root = fileparts(fileparts(mfilename('fullpath')));
    jarFile = fullfile(root, 'lib', 'Tinkerforge.jar');
end
if nargin < 1
    status = loadTinkerforgeBindings(jarFile);
else
    status = loadTinkerforgeBindings(jarFile, dependencies);
end
if ~status.available || status.restartRequired || ...
        ~status.loadedSourcesMatch || ~status.bridgeClassLoaded
    details = strjoin([status.errors; status.warnings], newline);
    error('IMU:RuntimeNotReady', 'IMU Java runtime is not ready. %s', details);
end
end
