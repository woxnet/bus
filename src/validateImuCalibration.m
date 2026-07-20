function report = validateImuCalibration(calibration, allowLegacy)
%VALIDATEIMUCALIBRATION Validate an IMU installation calibration structure.
%   REPORT = VALIDATEIMUCALIBRATION(CALIBRATION) returns REPORT.valid,
%   REPORT.errors and REPORT.warnings without throwing for normal invalid data.

report = struct('valid', false, 'errors', {{}}, 'warnings', {{}});
if nargin < 2, allowLegacy = false; end
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
            isfinite(calibration.version) && any(calibration.version == [1 2]))
        report.errors{end+1} = 'Unsupported calibration format version.';
    elseif calibration.version == 1 && ~allowLegacy
        report.errors{end+1} = 'Legacy calibration version 1 requires AllowLegacy=true.';
    elseif calibration.version == 2
        if ~isfield(calibration, 'metadata') || ~isstruct(calibration.metadata)
            report.errors{end+1} = 'Version 2 calibration requires metadata.';
        else
            metadataFields = {'busId','imuUid','deviceIdentifier','firmwareVersion', ...
                'sensorFusionMode','sampleRateHz','algorithmVersion'};
            for metadataIndex = 1:numel(metadataFields)
                if ~isfield(calibration.metadata, metadataFields{metadataIndex})
                    report.errors{end+1} = ['Missing metadata field: ', ...
                        metadataFields{metadataIndex}, '.'];
                end
            end
            if isempty(report.errors)
                metadata = calibration.metadata;
                config = getImuConfig();
                if ~(isTextScalar(metadata.busId) && strlength(string(metadata.busId)) > 0)
                    report.errors{end+1} = 'metadata.busId must be nonempty.';
                end
                if ~(isTextScalar(metadata.imuUid) && strlength(string(metadata.imuUid)) > 0)
                    report.errors{end+1} = 'metadata.imuUid must be nonempty.';
                end
                if ~(isnumeric(metadata.deviceIdentifier) && isscalar(metadata.deviceIdentifier) && ...
                        isfinite(metadata.deviceIdentifier) && metadata.deviceIdentifier == 18)
                    report.errors{end+1} = 'metadata.deviceIdentifier must equal 18.';
                end
                if ~(isnumeric(metadata.firmwareVersion) && ...
                        numel(metadata.firmwareVersion) == 3 && ...
                        all(isfinite(metadata.firmwareVersion(:))))
                    report.errors{end+1} = 'metadata.firmwareVersion must contain three finite values.';
                end
                if ~(isnumeric(metadata.sensorFusionMode) && ...
                        isscalar(metadata.sensorFusionMode) && ...
                        metadata.sensorFusionMode == config.sensorFusionMode)
                    report.errors{end+1} = 'metadata.sensorFusionMode does not match project configuration.';
                end
                if ~(isnumeric(metadata.sampleRateHz) && isscalar(metadata.sampleRateHz) && ...
                        isfinite(metadata.sampleRateHz) && metadata.sampleRateHz > 0)
                    report.errors{end+1} = 'metadata.sampleRateHz must be positive.';
                end
                if ~(isTextScalar(metadata.algorithmVersion) && ...
                        strlength(string(metadata.algorithmVersion)) > 0)
                    report.errors{end+1} = 'metadata.algorithmVersion must be nonempty.';
                end
            end
        end
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

    function valid = isTextScalar(value)
        valid = (ischar(value) && (isrow(value) || isempty(value))) || ...
            (isstring(value) && isscalar(value));
    end
end
