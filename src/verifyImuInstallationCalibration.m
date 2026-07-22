function report = verifyImuInstallationCalibration(imu, calibration, config, dependencies)
%VERIFYIMUINSTALLATIONCALIBRATION Independently verify a candidate transform.
%   This routine applies the candidate; it never recalculates its rotation.
if nargin < 3 || isempty(config), config = getImuInstallationCalibrationWorkflowConfig(); end
config = validateImuInstallationCalibrationWorkflowConfig(config);
if nargin < 4, dependencies = struct(); end
if ~isfield(dependencies, 'sleep'), dependencies.sleep = @pause; end
if ~isfield(dependencies, 'beforeForward'), dependencies.beforeForward = @()[]; end
if ~isfield(dependencies, 'checkCancelled'), dependencies.checkCancelled = @()[]; end
if ~isfield(dependencies, 'onProgress'), dependencies.onProgress = @(varargin)[]; end
rate = getImuCalibrationConfig().sampleRate;
allowSynthetic = isfield(calibration, 'metadata') && ...
    isfield(calibration.metadata, 'synthetic') && logical(calibration.metadata.synthetic);

dependencies.checkCancelled();
stationary = collect(max(1, ceil(config.verificationStationarySeconds * rate)),"verification_stationary");
dependencies.checkCancelled();
dependencies.beforeForward();
dependencies.checkCancelled();
forward = collect(max(1, ceil(config.verificationForwardSeconds * rate)),"verification_forward");
dependencies.checkCancelled();
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
report.stationarySamplesCollected = numel(stationary);
report.forwardSamplesCollected = numel(forward);
report.meanGravityVehicle = meanGravity;
report.meanLinearAccelerationVehicle = meanLinear;
report.meanAngularVelocityVehicle = meanAngular;
report.gravityMagnitudeError = abs(norm(meanGravity) - 9.81);
report.longitudinalGravityError = abs(meanGravity(1));
report.lateralGravityError = abs(meanGravity(2));
report.forwardAccelerationMean = mean(linearForward(:,1));
report.lateralAccelerationMean = mean(linearForward(:,2));
report.yawRateMean = mean(gyroForward(:,3));
stationaryAngularMagnitude = vecnorm(gyroStationary,2,2);
stationaryLinearMagnitude = vecnorm(linearStationary,2,2);
report.maximumStationaryAngularVelocity = max(stationaryAngularMagnitude);
report.rmsStationaryAngularVelocity = sqrt(mean(stationaryAngularMagnitude.^2));
report.maximumStationaryLinearAcceleration = max(stationaryLinearMagnitude);
report.rmsStationaryLinearAcceleration = sqrt(mean(stationaryLinearMagnitude.^2));
report.maximumAbsoluteLateralAcceleration = max(abs(linearForward(:,2)));
report.maximumAbsoluteYawRate = max(abs(gyroForward(:,3)));
horizontal = linearForward(:,1:2);
horizontalMagnitude = vecnorm(horizontal,2,2);
validDirection = horizontalMagnitude > eps;
if any(validDirection)
    directions = horizontal(validDirection,:) ./ horizontalMagnitude(validDirection);
    report.forwardDirectionCoherence = norm(mean(directions,1));
else
    report.forwardDirectionCoherence = 0;
end
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
if report.maximumStationaryAngularVelocity > ...
        config.maximumVerificationStationaryAngularVelocityDegPerSecond
    report.errors(end+1,1) = "Stationary angular velocity peak is outside tolerance.";
end
if report.maximumStationaryLinearAcceleration > ...
        config.maximumVerificationStationaryLinearAcceleration
    report.errors(end+1,1) = "Stationary linear acceleration peak is outside tolerance.";
end
if report.forwardAccelerationMean <= 0
    report.errors(end+1,1) = "Forward acceleration has a reversed sign.";
elseif report.forwardAccelerationMean < config.minimumVerificationForwardAcceleration
    report.errors(end+1,1) = "Forward acceleration is too small.";
end
if report.maximumAbsoluteLateralAcceleration > config.maximumVerificationLateralGravity
    report.errors(end+1,1) = "Forward lateral acceleration is outside tolerance.";
end
if report.maximumAbsoluteYawRate > config.maximumVerificationYawRateDegPerSecond
    report.errors(end+1,1) = "Forward yaw rate is outside tolerance.";
end
if report.forwardDirectionCoherence < config.minimumVerificationForwardCoherence
    report.errors(end+1,1) = "Forward acceleration direction is not coherent.";
end
components = [1-report.gravityMagnitudeError/config.maximumVerificationGravityError, ...
    1-report.longitudinalGravityError/config.maximumVerificationLongitudinalGravity, ...
    1-report.lateralGravityError/config.maximumVerificationLateralGravity, ...
    report.forwardAccelerationMean/config.minimumVerificationForwardAcceleration, ...
    1-abs(report.lateralAccelerationMean)/config.maximumVerificationLateralGravity, ...
    1-report.maximumAbsoluteYawRate/config.maximumVerificationYawRateDegPerSecond, ...
    report.forwardDirectionCoherence];
report.score = mean(max(0, min(1, components)));
report.success = isempty(report.errors);

    function values = collect(count,phase)
        values = repmat(struct('gravity',[],'linearAcceleration',[], ...
            'angularVelocity',[]), count, 1);
        for sampleIndex = 1:count
            dependencies.checkCancelled();
            sensor = imu.readOnce();
            dependencies.checkCancelled();
            vehicle = applyMountCalibration(sensor, calibration, ...
                'AllowSynthetic', allowSynthetic);
            values(sampleIndex).gravity = vehicle.gravity(:).';
            values(sampleIndex).linearAcceleration = vehicle.linearAcceleration(:).';
            values(sampleIndex).angularVelocity = vehicle.angularVelocity(:).';
            dependencies.onProgress(phase,sampleIndex,count);
            if sampleIndex < count, dependencies.sleep(1/rate); end
        end
    end
end
