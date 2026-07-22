function config = getRealtimeDrivingConfig()
%GETREALTIMEDRIVINGCONFIG Return validated causal monitor settings.

analysis = getDrivingAnalysisConfig();
imu = getImuConfig();
config = struct();
config.sampleRateHz = imu.sampleRateHz;
config.callbackPeriodMs = imu.callbackPeriodMs;
config.pollPeriodSeconds = 0.02;
config.maximumPollSamples = imu.callbackBufferCapacity;
config.lowPassCutoffHz = analysis.lowPassCutoffHz;
config.medianWindowSamples = analysis.medianWindowSamples;
config.outlierMadThreshold = analysis.outlierMadThreshold;
config.brakingStartThreshold = analysis.brakingStartThreshold;
config.brakingStopThreshold = analysis.brakingStopThreshold;
config.accelerationStartThreshold = analysis.accelerationStartThreshold;
config.accelerationStopThreshold = analysis.accelerationStopThreshold;
config.lateralStartThreshold = analysis.lateralStartThreshold;
config.lateralStopThreshold = analysis.lateralStopThreshold;
config.yawRateStartThresholdDegPerSecond = ...
    analysis.yawRateStartThresholdDegPerSecond;
config.yawRateStopThresholdDegPerSecond = ...
    analysis.yawRateStopThresholdDegPerSecond;
config.verticalShockThreshold = analysis.verticalShockThreshold;
config.jerkCandidateThreshold = analysis.jerkCandidateThreshold;
config.minimumEventDurationSeconds = analysis.minimumEventDurationSeconds;
config.maximumEventSilenceSeconds = 0.40;
config.verticalShockReleaseSamples = 5;
config.maximumSampleAgeMs = imu.maximumCallbackSampleAgeMs;
config.historySeconds = 30;
config.eventHistoryLimit = 1000;
config.stopOnOverflow = true;
config.stopOnSequenceGap = false;
config.maximumConsecutiveErrors = 3;
config.stopDrainTimeoutSeconds = 0.50;
config.stopDrainEmptyPasses = 3;
config.stopDrainPollIntervalSeconds = 0.005;
config.enableLivePlot = true;
config.plotRefreshHz = 10;
config.enableRecording = false;
config.recordingDirectory = "sessions";
config.maximumRecordingDurationSeconds = 8 * 60 * 60;
config.minimumFreeDiskBytes = 1024^3;
config.maximumSessionBytes = 20 * 1024^3;
config.recordingGuardPeriodSeconds = 1.0;
config.UseTimer = true;
config.DisconnectImuOnDelete = false;
config.AllowSyntheticCalibration = false;
config = validateRealtimeDrivingConfig(config);
end
