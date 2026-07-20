function calibrationConfig = getImuCalibrationConfig()
%GETIMUCALIBRATIONCONFIG Return calibrator thresholds with unified rate.
projectConfig = getImuConfig();
calibrationConfig = ImuMountCalibrator.defaultConfig();
calibrationConfig.sampleRate = projectConfig.calibrationSampleRateHz;
end
