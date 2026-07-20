function report = validateImuCalibration(calibration)
%VALIDATEIMUCALIBRATION Validate an IMU installation calibration structure.
%   REPORT = VALIDATEIMUCALIBRATION(CALIBRATION) returns REPORT.valid,
%   REPORT.errors and REPORT.warnings without throwing for normal invalid data.

report = struct('valid', false, 'errors', {{}}, 'warnings', {{}});
try
    if ~isstruct(calibration) || ~isscalar(calibration)
        report.errors{end+1} = 'Calibration must be a scalar structure.';
        return;
    end

    required = {'version','createdAt','axisConvention', ...
        'rotationVehicleFromSensor','bias','sensorAxes','quality','configuration'};
    for index = 1:numel(required)
        if ~isfield(calibration, required{index})
            report.errors{end+1} = ['Missing field: ', required{index}, '.'];
        end
    end
    if ~isempty(report.errors), return; end

    if ~(isnumeric(calibration.version) && isscalar(calibration.version) && ...
            isfinite(calibration.version) && calibration.version == 1)
        report.errors{end+1} = 'Unsupported calibration format version.';
    end

    R = calibration.rotationVehicleFromSensor;
    if ~(isnumeric(R) && isequal(size(R), [3 3]) && all(isfinite(R(:))))
        report.errors{end+1} = 'rotationVehicleFromSensor must be a finite 3-by-3 matrix.';
    else
        orthogonalityError = norm(R * R' - eye(3), 'fro');
        determinant = det(R);
        if orthogonalityError > 1e-5
            report.errors{end+1} = 'Rotation matrix is not orthonormal.';
        end
        if abs(determinant - 1) > 1e-3
            report.errors{end+1} = 'Rotation matrix determinant is not close to 1.';
        end
    end

    checkVector('bias.linearAccelerationSensor', calibration.bias, ...
        'linearAccelerationSensor');
    checkVector('bias.angularVelocitySensor', calibration.bias, ...
        'angularVelocitySensor');
    checkVector('sensorAxes.forward', calibration.sensorAxes, 'forward');
    checkVector('sensorAxes.left', calibration.sensorAxes, 'left');
    checkVector('sensorAxes.up', calibration.sensorAxes, 'up');

    qualityFields = {'valid','score','gravityMagnitude', ...
        'gravityDirectionStdDeg','forwardCoherence','forwardAccelerationMean', ...
        'forwardAccelerationStd','orthogonalityError','determinant', ...
        'stationarySampleCount','forwardSampleCount'};
    if ~isstruct(calibration.quality)
        report.errors{end+1} = 'quality must be a structure.';
    else
        for index = 1:numel(qualityFields)
            if ~isfield(calibration.quality, qualityFields{index})
                report.errors{end+1} = ['Missing field: quality.', qualityFields{index}, '.'];
            end
        end
        numericQualityFields = qualityFields(3:end);
        for index = 1:numel(numericQualityFields)
            field = numericQualityFields{index};
            if isfield(calibration.quality, field)
                value = calibration.quality.(field);
                if ~(isnumeric(value) && isscalar(value) && isfinite(value))
                    report.errors{end+1} = ['quality.', field, ' must be a finite scalar.'];
                end
            end
        end
    end
    if ~isstruct(calibration.quality) || ~isfield(calibration.quality, 'score') || ...
            ~(isnumeric(calibration.quality.score) && isscalar(calibration.quality.score) && ...
              isfinite(calibration.quality.score) && calibration.quality.score >= 0 && ...
              calibration.quality.score <= 1)
        report.errors{end+1} = 'quality.score must be a finite scalar in [0, 1].';
    end
    if ~isstruct(calibration.quality) || ~isfield(calibration.quality, 'valid') || ...
            ~(islogical(calibration.quality.valid) && isscalar(calibration.quality.valid))
        report.errors{end+1} = 'quality.valid must be a logical scalar.';
    elseif ~calibration.quality.valid
        report.errors{end+1} = 'Calibration quality is marked invalid.';
    end
catch exception
    report.errors{end+1} = ['Malformed calibration structure: ', exception.message];
end
report.valid = isempty(report.errors);

    function checkVector(label, parent, field)
        if ~isstruct(parent) || ~isfield(parent, field)
            report.errors{end+1} = ['Missing field: ', label, '.'];
            return;
        end
        value = parent.(field);
        if ~(isnumeric(value) && isequal(size(value), [3 1]) && all(isfinite(value(:))))
            report.errors{end+1} = [label, ' must be a finite 3-by-1 vector.'];
        end
    end
end
