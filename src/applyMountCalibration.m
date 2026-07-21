function vehicleData = applyMountCalibration(sensorData, calibration, varargin)
%APPLYMOUNTCALIBRATION Transform IMU vectors into vehicle coordinates.
%   VEHICLEDATA = APPLYMOUNTCALIBRATION(SENSORDATA, CALIBRATION) returns a
%   copy of SENSORDATA and transforms available 3-D vector fields. Bias is
%   removed from linear acceleration and angular velocity only.
%   sensorEuler and sensorQuaternion, when present, remain explicitly in the
%   sensor coordinate system; no ambiguous euler/quaternion fields are kept.

parser = inputParser;
parser.addParameter('AllowSynthetic', false, ...
    @(value)islogical(value) && isscalar(value));
parser.parse(varargin{:});
report = validateImuCalibration(calibration, ...
    'AllowSynthetic', parser.Results.AllowSynthetic);
if ~report.valid
    error('IMU:InvalidCalibrationFile', '%s', strjoin(report.errors, ' '));
end
if ~isstruct(sensorData) || ~isscalar(sensorData)
    error('IMU:InvalidSensorData', 'sensorData must be a scalar structure.');
end

vehicleData = sensorData;
if isfield(sensorData, 'euler')
    vehicleData.sensorEuler = sensorData.euler;
    vehicleData = rmfield(vehicleData, 'euler');
end
if isfield(sensorData, 'quaternion')
    vehicleData.sensorQuaternion = sensorData.quaternion;
    vehicleData = rmfield(vehicleData, 'quaternion');
end
R = calibration.rotationVehicleFromSensor;
fields = {'linearAcceleration','angularVelocity','gravity','acceleration','magneticField'};
for index = 1:numel(fields)
    field = fields{index};
    if ~isfield(sensorData, field), continue; end
    value = sensorData.(field);
    if ~(isnumeric(value) && numel(value) == 3 && all(isfinite(value(:))))
        error('IMU:InvalidSensorData', '%s must contain three finite numbers.', field);
    end
    value = value(:);
    if strcmp(field, 'linearAcceleration')
        value = value - calibration.bias.linearAccelerationSensor;
    elseif strcmp(field, 'angularVelocity')
        value = value - calibration.bias.angularVelocitySensor;
    end
    vehicleData.(field) = R * value;
end

if isfield(vehicleData, 'linearAcceleration')
    vehicleData.longitudinalAcceleration = vehicleData.linearAcceleration(1);
    vehicleData.lateralAcceleration = vehicleData.linearAcceleration(2);
    vehicleData.verticalAcceleration = vehicleData.linearAcceleration(3);
end
if isfield(vehicleData, 'angularVelocity')
    vehicleData.rollRate = vehicleData.angularVelocity(1);
    vehicleData.pitchRate = vehicleData.angularVelocity(2);
    vehicleData.yawRate = vehicleData.angularVelocity(3);
end
end
