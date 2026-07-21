projectRoot = fileparts(fileparts(mfilename('fullpath')));
run(fullfile(projectRoot, 'startup.m'));
assertImuRuntimeReady();

config = getImuConfig();
calibrationFile = resolveProjectPath(fullfile( ...
    config.calibrationDirectory, config.busId + "_imu_mount.mat"));
calibration = loadImuCalibration(calibrationFile, config.busId, config.uid);

imu = ImuBrick2(config.uid, config.host, config.port);
imuCleanup = onCleanup(@()imu.disconnect());
preflightReport = diagnoseImuBrick2UsingExistingConnection(imu);
disp(preflightReport);
assert(preflightReport.success);

recorder = ImuSessionRecorder(imu, calibration, struct( ...
    'directory', 'sessions', 'chunkSize', 1000, ...
    'maxPollSamples', config.callbackBufferCapacity, ...
    'callbackPeriodMs', config.callbackPeriodMs));
recorderCleanup = onCleanup(@()delete(recorder));
recorder.start();
timer = tic;
while toc(timer) < 120
    recorder.poll();
    pause(0.01);
end
recordedSession = recorder.stop();
disp(recordedSession);

assert(recordedSession.durationSeconds >= 120);
assert(recordedSession.status == "complete");
assert(recordedSession.samplesWritten >= 120 * ...
    config.minimumDiagnosticFrequencyHz);
assert(recordedSession.duplicateSamples == 0);
assert(recordedSession.missingSamples == 0);
assert(recordedSession.overflowDropped == 0);
assert(recordedSession.staleSessionDropped == 0);
assert(isfolder(recordedSession.directory));

clear timer recorderCleanup recorder;
clear imuCleanup imu projectRoot calibrationFile;
