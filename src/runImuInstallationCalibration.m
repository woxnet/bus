function calibration = runImuInstallationCalibration(imu, busId, calibrationDirectory)
%RUNIMUINSTALLATIONCALIBRATION Calibrate an installed IMU and save the result.
%   CALIBRATION = RUNIMUINSTALLATIONCALIBRATION(IMU, BUSID, DIRECTORY)
%   temporarily stops an active callback stream and restores it on exit.

projectConfig = getImuConfig();
if nargin < 3 || isempty(calibrationDirectory), calibrationDirectory = projectConfig.calibrationDirectory; end
validateattributes(busId, {'char','string'}, {'scalartext'});
validateattributes(calibrationDirectory, {'char','string'}, {'scalartext'});

calibrationConfig = getImuCalibrationConfig();
wasStreaming = isprop(imu, 'IsStreaming') && logical(imu.IsStreaming);
previousStreamingPeriodMs = double(imu.StreamingPeriodMs);
if wasStreaming, imu.stop(); end
cleanup = onCleanup(@()restoreImuStream( ...
    imu, wasStreaming, previousStreamingPeriodMs));

imu.setSensorFusionMode(projectConfig.sensorFusionMode);
fusionMode = imu.getSensorFusionMode();
if fusionMode ~= projectConfig.sensorFusionMode
    error('IMU:SensorFusionModeMismatch', 'Sensor fusion mode was not applied.');
end
identity = imu.getIdentity();

calibrationDirectory = resolveProjectPath(calibrationDirectory);
saveFile = fullfile(char(calibrationDirectory), [char(busId), '_imu_mount.mat']);
fprintf('Автоматическая установочная калибровка IMU запущена.\n');
metadata = struct('busId', string(busId), 'imuUid', string(identity.uid), ...
    'deviceIdentifier', identity.deviceIdentifier, ...
    'firmwareVersion', identity.firmwareVersion, ...
    'sensorFusionMode', fusionMode, ...
    'sampleRateHz', calibrationConfig.sampleRate, ...
    'algorithmVersion', "2.0");
calibrator = ImuMountCalibrator(imu, calibrationConfig);
calibration = calibrator.run(saveFile, metadata);
fprintf('Итоговая оценка качества: %.3f.\n', calibration.quality.score);
end

function restoreImuStream(imu, wasStreaming, periodMs)
if wasStreaming
    try
        imu.start(periodMs);
    catch exception
        warning('IMU:StreamRestoreFailed', ...
            'Не удалось восстановить callback-поток IMU: %s', exception.message);
    end
end
end
