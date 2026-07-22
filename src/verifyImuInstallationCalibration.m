function report = verifyImuInstallationCalibration(imu, calibration, config, dependencies)
%VERIFYIMUINSTALLATIONCALIBRATION Independently verify a candidate transform.
%   This routine applies the candidate; it never recalculates its rotation.
if nargin < 3 || isempty(config), config = getImuInstallationCalibrationWorkflowConfig(); end
config = validateImuInstallationCalibrationWorkflowConfig(config);
if nargin < 4, dependencies = struct(); end
if ~isfield(dependencies, 'sleep'), dependencies.sleep = @pause; end
if ~isfield(dependencies, 'beforeForward'), dependencies.beforeForward = @()[]; end
rate = getImuCalibrationConfig().sampleRate;
allowSynthetic = isfield(calibration, 'metadata') && ...
    isfield(calibration.metadata, 'synthetic') && logical(calibration.metadata.synthetic);

stationary = collect(max(1, ceil(config.verificationStationarySeconds * rate)));
dependencies.beforeForward();
forward = collect(max(1, ceil(config.verificationForwardSeconds * rate)));
gravity = vertcat(stationary.gravity);
linearStationary = vertcat(stationary.linearAcceleration);
gyroStationary = vertcat(stationary.angularVelocity);
linearForward = vertcat(forward.linearAcceleration);
gyroForward = vertcat(forward.angularVelocity);

meanGravity = mean(gravity, 1);
meanLinear = mean(linearStationary, 1);
meanAngular = mean(gyroStationary, 1);
report = struct();
report.success = false;
report.stationarySamples = numel(stationary);
report.forwardSamples = numel(forward);
report.meanGravityVehicle = meanGravity;
report.meanLinearAccelerationVehicle = meanLinear;
report.meanAngularVelocityVehicle = meanAngular;
report.gravityMagnitudeError = abs(norm(meanGravity) - 9.81);
report.longitudinalGravityError = abs(meanGravity(1));
report.lateralGravityError = abs(meanGravity(2));
report.forwardAccelerationMean = mean(linearForward(:,1));
report.lateralAccelerationMean = mean(linearForward(:,2));
report.yawRateMean = mean(gyroForward(:,3));
report.errors = strings(0,1);
report.warnings = strings(0,1);
if report.gravityMagnitudeError > config.maximumVerificationGravityError
    report.errors(end+1,1) = "Stationary gravity magnitude is outside tolerance.";
end
if report.longitudinalGravityError > config.maximumVerificationLongitudinalGravity
    report.errors(end+1,1) = "Stationary longitudinal gravity is outside tolerance.";
end
if report.lateralGravityError > config.maximumVerificationLateralGravity
    report.errors(end+1,1) = "Stationary lateral gravity is outside tolerance.";
end
if abs(meanLinear(1)) > config.maximumVerificationLongitudinalGravity || ...
        abs(meanLinear(2)) > config.maximumVerificationLateralGravity
    report.errors(end+1,1) = "Stationary linear acceleration is outside tolerance.";
end
if report.forwardAccelerationMean <= 0
    report.errors(end+1,1) = "Forward acceleration has a reversed sign.";
elseif report.forwardAccelerationMean < config.minimumVerificationForwardAcceleration
    report.errors(end+1,1) = "Forward acceleration is too small.";
end
if abs(report.lateralAccelerationMean) > config.maximumVerificationLateralGravity
    report.errors(end+1,1) = "Forward lateral acceleration is outside tolerance.";
end
if abs(report.yawRateMean) > config.maximumVerificationYawRateDegPerSecond
    report.errors(end+1,1) = "Forward yaw rate is outside tolerance.";
end
components = [1-report.gravityMagnitudeError/config.maximumVerificationGravityError, ...
    1-report.longitudinalGravityError/config.maximumVerificationLongitudinalGravity, ...
    1-report.lateralGravityError/config.maximumVerificationLateralGravity, ...
    report.forwardAccelerationMean/config.minimumVerificationForwardAcceleration, ...
    1-abs(report.lateralAccelerationMean)/config.maximumVerificationLateralGravity, ...
    1-abs(report.yawRateMean)/config.maximumVerificationYawRateDegPerSecond];
report.score = mean(max(0, min(1, components)));
report.success = isempty(report.errors);

    function values = collect(count)
        values = repmat(struct('gravity',[],'linearAcceleration',[], ...
            'angularVelocity',[]), count, 1);
        for sampleIndex = 1:count
            sensor = imu.readOnce();
            vehicle = applyMountCalibration(sensor, calibration, ...
                'AllowSynthetic', allowSynthetic);
            values(sampleIndex).gravity = vehicle.gravity(:).';
            values(sampleIndex).linearAcceleration = vehicle.linearAcceleration(:).';
            values(sampleIndex).angularVelocity = vehicle.angularVelocity(:).';
            if sampleIndex < count, dependencies.sleep(1/rate); end
        end
    end
end
