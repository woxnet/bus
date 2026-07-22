projectRoot = fileparts(fileparts(mfilename('fullpath')));
run(fullfile(projectRoot, "startup.m"));
assertImuRuntimeReady();
imuConfig = getImuConfig();
imu = ImuBrick2(imuConfig.uid, imuConfig.host, imuConfig.port);
imuCleanup = onCleanup(@()imu.disconnect());
calibrationStatus = ensureImuInstallationCalibration(imu, imuConfig.busId, ...
    getImuInstallationCalibrationWorkflowConfig());
if calibrationStatus.calibrationRequired
    error('IMU:InstallationCalibrationRequired', ...
        ['A valid installation calibration is required. Run: ', ...
         'run("examples/run_interactive_imu_installation_calibration.m");']);
end
calibration = calibrationStatus.calibration;
preflight = diagnoseImuBrick2UsingExistingConnection(imu);
disp(preflight); assert(preflight.success);
options = getRealtimeDrivingConfig();
options.enableLivePlot = true; options.enableRecording = true;
monitor = RealtimeDrivingMonitor(imu, calibration, options);
monitorCleanup = onCleanup(@()delete(monitor));
monitor.OnEventCompleted = @(~,event)printRealtimeDrivingEvent(event);
monitor.start();
disp("Real-time monitor запущен.");
disp("Для остановки выполните: summary = monitor.stop();");
clear projectRoot;
