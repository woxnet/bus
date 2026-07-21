function calibration = runImuInstallationCalibration(imu, busId, calibrationDirectory, preflightReport)
%RUNIMUINSTALLATIONCALIBRATION Calibrate an installed IMU and save the result.
%   CALIBRATION = RUNIMUINSTALLATIONCALIBRATION(IMU, BUSID, DIRECTORY)
%   temporarily stops an active callback stream and restores it on exit.

projectConfig = getImuConfig();
if nargin < 4 || ~isstruct(preflightReport) || ...
        ~isfield(preflightReport, 'success') || ~preflightReport.success
    error('IMU:PreflightRequired', ...
        'A successful hardware preflight report is required.');
end
if ~isfield(preflightReport, 'uid') || ...
        string(preflightReport.uid) ~= projectConfig.uid
    error('IMU:PreflightDeviceMismatch', ...
        'The preflight report belongs to a different IMU.');
end
if ~isfield(preflightReport, 'generatedAt') || ...
        ~isdatetime(preflightReport.generatedAt) || ...
        seconds(datetime('now', 'TimeZone', 'UTC') - ...
            preflightReport.generatedAt) > 300
    error('IMU:PreflightExpired', ...
        'The hardware preflight report is older than five minutes.');
end
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
if string(identity.uid) ~= projectConfig.uid
    error('IMU:CalibrationDeviceMismatch', ...
        'Connected IMU UID does not match project configuration.');
end
if double(identity.deviceIdentifier) ~= 18
    error('IMU:CalibrationDeviceMismatch', ...
        'Connected device is not an IMU Brick 2.0.');
end
if ~versionAtLeast(identity.firmwareVersion, projectConfig.minimumFirmwareVersion)
    error('IMU:FirmwareTooOld', 'Connected IMU firmware is too old.');
end

calibrationDirectory = resolveProjectPath(calibrationDirectory);
saveFile = fullfile(char(calibrationDirectory), [char(busId), '_imu_mount.mat']);
fprintf('Автоматическая установочная калибровка IMU запущена.\n');
metadata = struct('busId', string(busId), 'imuUid', string(identity.uid), ...
    'deviceIdentifier', identity.deviceIdentifier, ...
    'firmwareVersion', identity.firmwareVersion, ...
    'sensorFusionMode', fusionMode, ...
    'sampleRateHz', calibrationConfig.sampleRate, ...
    'algorithmVersion', "2.0", 'synthetic', false);
calibrator = ImuMountCalibrator(imu, calibrationConfig);
calibration = calibrator.run(saveFile, metadata);
fprintf('Итоговая оценка качества: %.3f.\n', calibration.quality.score);
end

function valid = versionAtLeast(actual, required)
actual = double(actual(:)).'; required = double(required(:)).';
width = max(numel(actual), numel(required));
actual(end+1:width) = 0; required(end+1:width) = 0;
different = find(actual ~= required, 1, 'first');
valid = isempty(different) || actual(different) > required(different);
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
