function config = getImuConfig()
%GETIMUCONFIG Return the single project configuration for IMU Brick 2.0.
%   CONFIG contains the device address, acquisition rate and calibration
%   output settings used by diagnostics and operator-run calibration.

config = struct();

config.uid = "6dKiM3";
config.host = "localhost";
config.port = 4223;

config.sampleRateHz = 50;
config.samplePeriodSeconds = 0.02;
config.callbackPeriodMs = 20;
config.callbackBufferMaximumSize = 256;
config.preflightMaximumDroppedSamples = 0;
config.sensorFusionMode = 2;
config.minimumFirmwareVersion = [2 0 12];
config.calibrationSampleRateHz = config.sampleRateHz;
config.calibrationFileVersion = 2;

config.busId = "bus_001";
config.calibrationDirectory = "calibration";

config.diagnosticSampleCount = 100;
config.minimumDiagnosticFrequencyHz = 40;
config.maximumDiagnosticFrequencyHz = 60;

config.gravityReference = 9.81;
config.maximumGravityError = 1.5;

config.maxConsecutiveReadErrors = 3;
config.readRetryDelaySeconds = 0.1;
end
