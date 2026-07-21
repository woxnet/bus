projectRoot = fileparts(mfilename('fullpath'));
jarFile = fullfile(projectRoot, 'lib', 'Tinkerforge.jar');

addpath(fullfile(projectRoot, 'src'));
addpath(fullfile(projectRoot, 'examples'));

imuStartupStatus = loadTinkerforgeBindings(jarFile);

if imuStartupStatus.available
    fprintf('Tinkerforge bindings готовы.\n');
elseif imuStartupStatus.restartRequired
    fprintf(['Tinkerforge Java classes already loaded.\n', ...
        'Restart MATLAB before connecting the IMU.\n']);
end

clear projectRoot jarFile;
