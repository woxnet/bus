projectRoot = fileparts(fileparts(mfilename('fullpath')));
run(fullfile(projectRoot, 'startup.m'));
config = getImuConfig();
imu = ImuBrick2(config.uid, config.host, config.port);
cleanup = onCleanup(@()imu.disconnect());

preflight = diagnoseImuBrick2UsingExistingConnection(imu);
disp(preflight);
if ~preflight.success
    disp(preflight.errors);
    error('IMU:PreflightFailed', 'Hardware acceptance preflight failed.');
end

report = runImuHardwareAcceptance(imu, 60, 'artifacts');
disp(report);
if ~report.success
    error('IMU:HardwareAcceptanceFailed', ...
        'The 60-second IMU hardware acceptance test failed.');
end
