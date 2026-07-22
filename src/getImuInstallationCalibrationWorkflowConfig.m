function config = getImuInstallationCalibrationWorkflowConfig()
%GETIMUINSTALLATIONCALIBRATIONWORKFLOWCONFIG Operator workflow defaults.
imu = getImuConfig();
config = struct();
config.busId = imu.busId;
config.calibrationDirectory = imu.calibrationDirectory;
config.requireOperatorConfirmation = true;
config.StopExistingStream = false;
config.RestorePreviousStream = false;
config.enableDashboard = true;
config.pollStatusSeconds = 0.10;
config.performVerification = true;
config.verificationStationarySeconds = 3.0;
config.verificationForwardSeconds = 1.0;
config.maximumVerificationGravityError = 0.50;
config.maximumVerificationLateralGravity = 0.35;
config.maximumVerificationLongitudinalGravity = 0.35;
config.minimumVerificationForwardAcceleration = 0.25;
config.maximumVerificationYawRateDegPerSecond = 6.0;
config.maximumVerificationStationaryAngularVelocityDegPerSecond = 1.5;
config.maximumVerificationStationaryLinearAcceleration = 0.20;
config.minimumVerificationForwardCoherence = 0.85;
config.backupExistingCalibration = true;
config.keepFailedWorkingFiles = false;
config.AllowUnverifiedLegacyCalibration = false;
config = validateImuInstallationCalibrationWorkflowConfig(config);
end
