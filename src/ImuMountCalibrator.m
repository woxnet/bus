classdef ImuMountCalibrator < handle
%IMUMOUNTCALIBRATOR Automatically calibrate the installed orientation of an IMU.
%   Calibration must be performed on a level surface. The first confirmed
%   acceleration must be straight forward. Without CAN or GNSS an IMU cannot
%   distinguish forward acceleration from backward braking. Recalibrate after
%   changing the sensor position.
%
%   Example:
%       imu = ImuBrick2("UID");
%       config = ImuMountCalibrator.defaultConfig();
%       calibrator = ImuMountCalibrator(imu, config);
%       calibration = calibrator.run( ...
%           fullfile("calibration", "bus_017_imu_mount.mat"));

    properties (SetAccess = private)
        State = "IDLE"
        Progress = 0
        LastMessage = ""
        Config
    end

    properties
        OnStatusChanged = []
        OnProgress = []
        OnMessage = []
    end

    properties (Access = private)
        Imu
        CancelRequested = false
        ConsecutiveReadErrors = 0
        PacingTimer
        NextSampleDeadline = 0
    end

    methods
        function obj = ImuMountCalibrator(imu, config)
            %IMUMOUNTCALIBRATOR Construct a calibrator for a readOnce source.
            if nargin < 1 || isempty(imu) || ~ismethod(imu, 'readOnce')
                error('IMU:InvalidConfiguration', ...
                    'imu must be an object supporting readOnce().');
            end
            if nargin < 2 || isempty(config), config = struct(); end
            obj.Imu = imu;
            obj.Config = obj.mergeAndValidateConfig(config);
        end

        function calibration = run(obj, saveFile, metadata, varargin)
            %RUN Perform calibration and optionally save it to a MAT-file.
            if nargin < 2, saveFile = ''; end
            if nargin < 3, metadata = []; end
            parser = inputParser;
            parser.addParameter('AllowSyntheticMetadata', false, ...
                @(value)islogical(value) && isscalar(value));
            parser.parse(varargin{:});
            if isempty(metadata)
                if ~parser.Results.AllowSyntheticMetadata
                    error('IMU:CalibrationMetadataRequired', ...
                        ['Calibration requires hardware metadata. Tests must ', ...
                         'explicitly set AllowSyntheticMetadata to true.']);
                end
                metadata = obj.defaultSyntheticMetadata();
            end
            if ~isfield(metadata, 'synthetic') || ...
                    ~(islogical(metadata.synthetic) && isscalar(metadata.synthetic))
                error('IMU:CalibrationMetadataRequired', ...
                    'metadata.synthetic must be an explicit logical scalar.');
            end
            obj.CancelRequested = false;
            obj.ConsecutiveReadErrors = 0;
            obj.PacingTimer = tic;
            obj.NextSampleDeadline = 0;
            obj.setStatus("INITIALIZATION", 0, "Проверка доступности IMU");
            try
                obj.readSample();
                [stationary, gravity, linearBias, gyroBias] = obj.findStationary();
                zSensor = -obj.normalizeVector(gravity);
                [forward, forwardTimes] = obj.findForward( ...
                    zSensor, linearBias, gyroBias);

                obj.setStatus("VALIDATION", 0.92, ...
                    "Проверка качества калибровки");
                [R, axes] = obj.buildRotation(zSensor, mean(forward, 1));
                quality = obj.calculateQuality( ...
                    stationary, forward, forwardTimes, R);
                calibration = obj.makeCalibration(R, axes, linearBias, gyroBias, quality, metadata);
                if ~quality.valid
                    obj.LastMessage = "Калибровка отклонена из-за низкого качества";
                    error('IMU:CalibrationRejected', ...
                        'Calibration quality %.3f does not meet requirements.', quality.score);
                end
                report = validateImuCalibration(calibration, ...
                    'AllowSynthetic', logical(metadata.synthetic));
                if ~report.valid
                    error('IMU:CalibrationRejected', '%s', strjoin(report.errors, ' '));
                end
                if ~isempty(saveFile), obj.saveAtomically(calibration, saveFile); end
                obj.setStatus("READY", 1, "Калибровка успешно завершена");
            catch exception
                if strcmp(exception.identifier, 'IMU:CalibrationCancelled')
                    obj.setStatus("CANCELLED", obj.Progress, "Калибровка отменена");
                else
                    obj.State = "FAILED";
                    obj.LastMessage = string(exception.message);
                end
                rethrow(exception);
            end
        end

        function cancel(obj)
            %CANCEL Request cancellation of a running calibration.
            obj.CancelRequested = true;
        end
    end

    methods (Static)
        function config = defaultConfig()
            %DEFAULTCONFIG Return validated default calibration settings.
            config.sampleRate = 50;
            config.stationaryDuration = 4.0;
            config.stationaryTimeout = 45.0;
            config.maxStationaryLinearAcceleration = 0.20;
            config.maxStationaryAngularVelocity = 1.5;
            config.stationaryGravityTolerance = 0.80;
            config.forwardAccelerationDuration = 1.0;
            config.forwardTimeout = 90.0;
            config.minForwardAcceleration = 0.30;
            config.maxForwardAcceleration = 2.50;
            config.maxForwardAngularVelocity = 6.0;
            config.maxForwardDirectionDeviationDeg = 20.0;
            config.maximumForwardSampleGap = 0.15;
            config.minForwardCoherence = 0.85;
            config.maxGravityMagnitudeError = 0.50;
            config.maxGravityDirectionStdDeg = 1.5;
            config.maxOrthogonalityError = 1e-5;
            config.minimumCalibrationScore = 0.75;
            config.maxConsecutiveReadErrors = 3;
            config.readRetryDelay = 0.1;
        end
    end

    methods (Access = private)
        function [samples, meanGravity, linearBias, gyroBias] = findStationary(obj)
            obj.setStatus("WAIT_STILL", 0.05, ...
                "Ожидание неподвижного состояния на горизонтальной площадке");
            needed = max(1, ceil(obj.Config.stationaryDuration * obj.Config.sampleRate));
            samples = repmat(obj.emptyMeasurement(), 0, 1);
            timer = tic;
            while numel(samples) < needed
                obj.checkCancelled();
                if toc(timer) > obj.Config.stationaryTimeout
                    error('IMU:StationaryTimeout', ...
                        'A continuous stationary interval was not found in time.');
                end
                data = obj.readSample();
                if obj.isStationary(data)
                    measurement = obj.measurement(data);
                    measurement.monotonicSeconds = toc(obj.PacingTimer);
                    samples(end+1, 1) = measurement; %#ok<AGROW>
                    obj.updateProgress(min(0.40, 0.05 + 0.35 * numel(samples) / needed));
                else
                    samples = repmat(obj.emptyMeasurement(), 0, 1);
                    obj.updateProgress(0.05);
                end
                obj.samplePause();
            end
            obj.setStatus("LEVEL_CALIBRATION", 0.45, "Неподвижность подтверждена");
            gravityValues = vertcat(samples.gravity);
            linearValues = vertcat(samples.linearAcceleration);
            gyroValues = vertcat(samples.angularVelocity);
            meanGravity = mean(gravityValues, 1);
            obj.normalizeVector(meanGravity);
            linearBias = mean(linearValues, 1).';
            gyroBias = mean(gyroValues, 1).';
        end

        function [samples, sampleTimes] = findForward(obj, zSensor, linearBias, gyroBias)
            obj.setStatus("WAIT_FORWARD_ACCELERATION", 0.50, ...
                "Начните плавный разгон строго вперёд");
            needed = max(1, ceil(obj.Config.forwardAccelerationDuration * obj.Config.sampleRate));
            samples = zeros(0, 3);
            sampleTimes = zeros(0, 1);
            gapSamples = 0;
            maxGap = floor(obj.Config.maximumForwardSampleGap * obj.Config.sampleRate);
            timer = tic;
            while size(samples, 1) < needed
                obj.checkCancelled();
                if toc(timer) > obj.Config.forwardTimeout
                    error('IMU:ForwardTimeout', ...
                        'A suitable straight forward acceleration was not found in time.');
                end
                data = obj.readSample();
                acceleration = data.linearAcceleration(:) - linearBias;
                gyro = data.angularVelocity(:) - gyroBias;
                horizontal = acceleration - dot(acceleration, zSensor) * zSensor;
                magnitude = norm(horizontal);
                turning = norm(gyro) > obj.Config.maxForwardAngularVelocity;
                validMagnitude = magnitude >= obj.Config.minForwardAcceleration && ...
                    magnitude <= obj.Config.maxForwardAcceleration;
                consistent = true;
                if validMagnitude && ~isempty(samples)
                    reference = obj.normalizeVector(mean(samples, 1));
                    consistent = obj.safeAngle(reference, horizontal) <= ...
                        obj.Config.maxForwardDirectionDeviationDeg;
                end

                if turning
                    samples = zeros(0, 3);
                    sampleTimes = zeros(0, 1);
                    gapSamples = 0;
                    obj.updateProgress(0.50);
                    obj.LastMessage = "Обнаружен поворот, сегмент разгона сброшен";
                    fprintf('%s\n', char(obj.LastMessage));
                elseif validMagnitude && consistent
                    samples(end+1, :) = horizontal.'; %#ok<AGROW>
                    sampleTimes(end+1, 1) = toc(obj.PacingTimer); %#ok<AGROW>
                    gapSamples = 0;
                    obj.updateProgress(min(0.88, 0.50 + 0.38 * size(samples, 1) / needed));
                elseif ~isempty(samples) && gapSamples < maxGap
                    gapSamples = gapSamples + 1;
                else
                    samples = zeros(0, 3);
                    sampleTimes = zeros(0, 1);
                    gapSamples = 0;
                    obj.updateProgress(0.50);
                end
                obj.samplePause();
            end
            obj.LastMessage = "Направление движения определено";
        end

        function data = readSample(obj)
            while true
                obj.checkCancelled();
                try
                    data = obj.Imu.readOnce();
                    obj.validateSample(data);
                    obj.ConsecutiveReadErrors = 0;
                    return;
                catch exception
                    if strcmp(exception.identifier, 'IMU:CalibrationCancelled')
                        rethrow(exception);
                    end
                    obj.ConsecutiveReadErrors = obj.ConsecutiveReadErrors + 1;
                    if obj.ConsecutiveReadErrors > obj.Config.maxConsecutiveReadErrors
                        error('IMU:DeviceReadFailed', ...
                            'IMU read failed after %d consecutive errors: %s', ...
                            obj.ConsecutiveReadErrors, exception.message);
                    end
                    pause(obj.Config.readRetryDelay);
                end
            end
        end

        function validateSample(~, data)
            fields = {'gravity','linearAcceleration','angularVelocity'};
            if ~isstruct(data)
                error('Invalid IMU sample.');
            end
            for index = 1:numel(fields)
                if ~isfield(data, fields{index})
                    error('IMU sample is missing %s.', fields{index});
                end
                value = data.(fields{index});
                if ~(isnumeric(value) && numel(value) == 3 && all(isfinite(value(:))))
                    error('IMU sample field %s is invalid.', fields{index});
                end
            end
        end

        function result = isStationary(obj, data)
            result = abs(norm(data.gravity) - 9.81) <= ...
                obj.Config.stationaryGravityTolerance && ...
                norm(data.linearAcceleration) <= ...
                obj.Config.maxStationaryLinearAcceleration && ...
                norm(data.angularVelocity) <= ...
                obj.Config.maxStationaryAngularVelocity;
        end

        function [R, axes] = buildRotation(obj, zSensor, forward)
            xSensor = obj.normalizeVector(forward);
            ySensor = obj.normalizeVector(cross(zSensor, xSensor));
            xSensor = obj.normalizeVector(cross(ySensor, zSensor));
            R = [xSensor(:).'; ySensor(:).'; zSensor(:).'];
            if any(~isfinite(R(:))) || norm(R * R' - eye(3), 'fro') > ...
                    obj.Config.maxOrthogonalityError || abs(det(R) - 1) > 1e-3
                error('IMU:CalibrationRejected', 'Could not construct a valid rotation matrix.');
            end
            axes = struct('forward', xSensor(:), 'left', ySensor(:), 'up', zSensor(:));
        end

        function quality = calculateQuality(obj, stationary, forward, forwardTimes, R)
            gravityValues = vertcat(stationary.gravity);
            gyroValues = vertcat(stationary.angularVelocity);
            meanGravity = mean(gravityValues, 1);
            gravityMagnitude = norm(meanGravity);
            gravityUnit = gravityValues ./ vecnorm(gravityValues, 2, 2);
            meanGravityUnit = obj.normalizeVector(mean(gravityUnit, 1));
            angles = zeros(size(gravityUnit, 1), 1);
            for index = 1:numel(angles)
                angles(index) = obj.safeAngle(gravityUnit(index, :), meanGravityUnit);
            end
            directionStd = std(angles, 0);
            magnitudes = vecnorm(forward, 2, 2);
            directions = forward ./ magnitudes;
            coherence = norm(mean(directions, 1));
            orthogonalityError = norm(R * R' - eye(3), 'fro');
            determinant = det(R);
            stationaryTimes = [stationary.monotonicSeconds].';
            stationaryRate = obj.measuredRate(stationaryTimes);
            forwardRate = obj.measuredRate(forwardTimes);

            gravityScore = obj.clamp01(1 - abs(gravityMagnitude - 9.81) / ...
                obj.Config.maxGravityMagnitudeError);
            stationaryScore = obj.clamp01(1 - directionStd / ...
                obj.Config.maxGravityDirectionStdDeg);
            directionScore = obj.clamp01((coherence - obj.Config.minForwardCoherence) / ...
                max(eps, 1 - obj.Config.minForwardCoherence));
            rotationScore = obj.clamp01(1 - mean(vecnorm(gyroValues, 2, 2)) / ...
                obj.Config.maxStationaryAngularVelocity);
            orthogonalityScore = obj.clamp01(1 - orthogonalityError / ...
                obj.Config.maxOrthogonalityError);
            score = 0.20 * gravityScore + 0.20 * stationaryScore + ...
                0.30 * directionScore + 0.15 * rotationScore + ...
                0.15 * orthogonalityScore;
            critical = abs(gravityMagnitude - 9.81) <= obj.Config.maxGravityMagnitudeError && ...
                directionStd <= obj.Config.maxGravityDirectionStdDeg && ...
                coherence >= obj.Config.minForwardCoherence && ...
                orthogonalityError <= obj.Config.maxOrthogonalityError && ...
                abs(determinant - 1) <= 1e-3;

            quality = struct('valid', logical(critical && score >= ...
                obj.Config.minimumCalibrationScore), 'score', obj.clamp01(score), ...
                'gravityMagnitude', gravityMagnitude, ...
                'gravityDirectionStdDeg', directionStd, ...
                'forwardCoherence', coherence, ...
                'forwardAccelerationMean', mean(magnitudes), ...
                'forwardAccelerationStd', std(magnitudes, 0), ...
                'orthogonalityError', orthogonalityError, ...
                'determinant', determinant, ...
                'stationarySampleCount', size(gravityValues, 1), ...
                'forwardSampleCount', size(forward, 1));
            quality.actualStationarySampleRateHz = stationaryRate;
            quality.actualForwardSampleRateHz = forwardRate;
        end

        function calibration = makeCalibration(obj, R, axes, linearBias, gyroBias, quality, metadata)
            calibration = struct();
            calibration.version = getImuConfig().calibrationFileVersion;
            calibration.createdAt = datetime('now', 'TimeZone', 'UTC');
            calibration.axisConvention = 'X forward, Y left, Z up';
            calibration.rotationVehicleFromSensor = R;
            calibration.bias.linearAccelerationSensor = linearBias(:);
            calibration.bias.angularVelocitySensor = gyroBias(:);
            calibration.sensorAxes = axes;
            calibration.quality = quality;
            calibration.configuration = obj.Config;
            calibration.metadata = metadata;
        end

        function metadata = defaultSyntheticMetadata(obj)
            metadata = struct('busId', "synthetic", 'imuUid', "synthetic", ...
                'deviceIdentifier', 18, 'firmwareVersion', [0 0 0], ...
                'sensorFusionMode', getImuConfig().sensorFusionMode, ...
                'sampleRateHz', obj.Config.sampleRate, ...
                'algorithmVersion', "2.0", 'synthetic', true);
        end

        function saveAtomically(~, calibration, saveFile)
            validateattributes(saveFile, {'char','string'}, {'scalartext'});
            saveFile = char(saveFile);
            directory = fileparts(saveFile);
            if isempty(directory), directory = pwd; end
            if ~isfolder(directory), mkdir(directory); end
            temporaryFile = [tempname(directory), '.mat'];
            cleanup = onCleanup(@()deleteIfPresent(temporaryFile));
            save(temporaryFile, 'calibration');
            [success, message] = movefile(temporaryFile, saveFile, 'f');
            if ~success, error('IMU:CalibrationSaveFailed', '%s', message); end

            function deleteIfPresent(filename)
                if isfile(filename), delete(filename); end
            end
        end

        function config = mergeAndValidateConfig(~, custom)
            if ~isstruct(custom) || ~isscalar(custom)
                error('IMU:InvalidConfiguration', 'config must be a scalar structure.');
            end
            config = ImuMountCalibrator.defaultConfig();
            customFields = fieldnames(custom);
            validFields = fieldnames(config);
            unknown = setdiff(customFields, validFields);
            if ~isempty(unknown)
                error('IMU:InvalidConfiguration', 'Unknown configuration field: %s.', unknown{1});
            end
            for index = 1:numel(customFields)
                config.(customFields{index}) = custom.(customFields{index});
            end
            try
                positive = validFields;
                for index = 1:numel(positive)
                    validateattributes(config.(positive{index}), {'numeric'}, ...
                        {'real','finite','scalar','positive'}, '', positive{index});
                end
                validateattributes(config.sampleRate, {'numeric'}, {'integer'});
                validateattributes(config.maxConsecutiveReadErrors, {'numeric'}, ...
                    {'integer','nonnegative'});
                bounded = {'minForwardCoherence','minimumCalibrationScore'};
                for index = 1:numel(bounded)
                    validateattributes(config.(bounded{index}), {'numeric'}, ...
                        {'<=',1});
                end
                if config.minForwardAcceleration >= config.maxForwardAcceleration
                    error('Minimum forward acceleration must be less than maximum.');
                end
            catch exception
                error('IMU:InvalidConfiguration', 'Invalid calibration configuration: %s', ...
                    exception.message);
            end
        end

        function checkCancelled(obj)
            if obj.CancelRequested
                error('IMU:CalibrationCancelled', 'IMU calibration was cancelled.');
            end
        end

        function samplePause(obj)
            period = 1 / obj.Config.sampleRate;
            elapsed = toc(obj.PacingTimer);
            if obj.NextSampleDeadline <= 0
                obj.NextSampleDeadline = elapsed + period;
            else
                obj.NextSampleDeadline = obj.NextSampleDeadline + period;
                if obj.NextSampleDeadline < elapsed
                    missed = floor((elapsed - obj.NextSampleDeadline) / period) + 1;
                    obj.NextSampleDeadline = obj.NextSampleDeadline + missed * period;
                end
            end
            pause(max(0, obj.NextSampleDeadline - elapsed));
        end

        function rate = measuredRate(~, timestamps)
            if numel(timestamps) < 2 || timestamps(end) <= timestamps(1)
                rate = NaN;
            else
                rate = (numel(timestamps) - 1) / ...
                    (timestamps(end) - timestamps(1));
            end
        end

        function setStatus(obj, state, progress, message)
            obj.State = state;
            obj.Progress = max(0, min(1, progress));
            obj.LastMessage = message;
            fprintf('%s\n', char(message));
            status = struct('state', obj.State, 'progress', obj.Progress, ...
                'message', obj.LastMessage);
            obj.invokeCallback(obj.OnStatusChanged, status);
            obj.invokeCallback(obj.OnProgress, status);
            obj.invokeCallback(obj.OnMessage, status);
        end

        function updateProgress(obj, progress)
            obj.Progress = max(0, min(1, progress));
            status = struct('state', obj.State, 'progress', obj.Progress, ...
                'message', obj.LastMessage);
            obj.invokeCallback(obj.OnProgress, status);
        end

        function invokeCallback(obj, callback, value)
            if isempty(callback), return; end
            try
                callback(obj, value);
            catch exception
                warning('IMU:CalibrationCallbackFailed', ...
                    'Calibration callback failed: %s', exception.message);
            end
        end
    end

    methods (Static, Access = private)
        function value = normalizeVector(value)
            value = value(:);
            magnitude = norm(value);
            if ~all(isfinite(value)) || magnitude <= eps
                error('IMU:ZeroVector', 'A zero or non-finite vector cannot be normalized.');
            end
            value = value / magnitude;
        end

        function angle = safeAngle(first, second)
            first = ImuMountCalibrator.normalizeVector(first);
            second = ImuMountCalibrator.normalizeVector(second);
            value = dot(first, second);
            value = max(-1, min(1, value));
            angle = acosd(value);
        end

        function value = clamp01(value)
            value = max(0, min(1, value));
        end

        function measurement = emptyMeasurement()
            measurement = struct('gravity', [], 'linearAcceleration', [], ...
                'angularVelocity', [], 'monotonicSeconds', NaN);
        end

        function measurement = measurement(data)
            measurement = struct('gravity', data.gravity(:).', ...
                'linearAcceleration', data.linearAcceleration(:).', ...
                'angularVelocity', data.angularVelocity(:).', ...
                'monotonicSeconds', NaN);
        end
    end
end
