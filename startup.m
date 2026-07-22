imuStartupProjectRoot = fileparts(mfilename('fullpath'));
imuStartupJarFile = fullfile(imuStartupProjectRoot, 'lib', 'Tinkerforge.jar');

addpath(fullfile(imuStartupProjectRoot, 'src'));
addpath(fullfile(imuStartupProjectRoot, 'examples'));

imuStartupStatus = loadTinkerforgeBindings(imuStartupJarFile);

if imuStartupStatus.available
    fprintf('Tinkerforge bindings готовы.\n');
elseif imuStartupStatus.restartRequired
    fprintf(['Tinkerforge Java classes already loaded.\n', ...
        'Restart MATLAB before connecting the IMU.\n']);
end

clear imuStartupProjectRoot imuStartupJarFile;
