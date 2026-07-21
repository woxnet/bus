function config = getDrivingAnalysisConfig()
%GETDRIVINGANALYSISCONFIG Preliminary engineering settings for IMU analysis.

config = struct();
config.targetSampleRateHz = 50;
config.sampleRateToleranceHz = 0.5;
config.maximumGapSamples = 2;
config.segmentGapSeconds = 0.10;
config.medianWindowSamples = 5;
config.outlierMadThreshold = 6;
config.lowPassCutoffHz = 2.5;
config.brakingStartThreshold = -1.5;
config.brakingStopThreshold = -0.8;
config.accelerationStartThreshold = 1.2;
config.accelerationStopThreshold = 0.6;
config.lateralStartThreshold = 1.5;
config.lateralStopThreshold = 0.8;
config.yawRateStartThresholdDegPerSecond = 8;
config.yawRateStopThresholdDegPerSecond = 4;
config.verticalShockThreshold = 2.0;
config.jerkCandidateThreshold = 2.5;
config.minimumEventDurationSeconds = 0.30;
config.maximumMergeGapSeconds = 0.40;
config.preEventSeconds = 1.0;
config.postEventSeconds = 1.0;
config.analysisVersion = "1.0";
config = validateDrivingAnalysisConfig(config);
end
