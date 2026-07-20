function config = getImuConfig()
%GETIMUCONFIG Return the single project configuration for IMU Brick 2.0.
%   CONFIG contains the device address, acquisition rate and calibration
%   output settings used by diagnostics and operator-run calibration.

config.uid = "6dKiM3";
config.host = "localhost";
config.port = 4223;
config.sampleRateHz = 50;
config.callbackPeriodMs = 20;
config.calibrationDirectory = "calibration";
config.busId = "bus_001";
end
