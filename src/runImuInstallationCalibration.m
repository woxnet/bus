function calibration = runImuInstallationCalibration(imu, busId, calibrationDirectory)
%RUNIMUINSTALLATIONCALIBRATION Calibrate an installed IMU and save the result.
%   CALIBRATION = RUNIMUINSTALLATIONCALIBRATION(IMU, BUSID, DIRECTORY)
%   temporarily stops an active callback stream and restores it on exit.

if nargin < 3 || isempty(calibrationDirectory)
    calibrationDirectory = 'calibration';
end
validateattributes(busId, {'char','string'}, {'scalartext'});
validateattributes(calibrationDirectory, {'char','string'}, {'scalartext'});

config = ImuMountCalibrator.defaultConfig();
wasStreaming = isprop(imu, 'IsStreaming') && logical(imu.IsStreaming);
if wasStreaming, imu.stop(); end
periodMs = round(1000 / config.sampleRate);
cleanup = onCleanup(@()restoreImuStream(imu, wasStreaming, periodMs));

saveFile = fullfile(char(calibrationDirectory), [char(busId), '_imu_mount.mat']);
fprintf('Автоматическая установочная калибровка IMU запущена.\n');
calibrator = ImuMountCalibrator(imu, config);
calibration = calibrator.run(saveFile);
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
