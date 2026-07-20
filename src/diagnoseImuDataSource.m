function report = diagnoseImuDataSource(imu, options)
%DIAGNOSEIMUDATASOURCE Validate an IMU-like synchronous data source.
%   REPORT = DIAGNOSEIMUDATASOURCE(IMU) checks data structure, finite values,
%   timestamps, sequence numbers, gravity, quaternion norm and read rate.
%   It does not require a JAR, Brick Daemon, or physical hardware and never
%   disconnects the supplied object.

config = getImuConfig();
if nargin < 2, options = struct(); end
options = mergeOptions(options, config);
report = createReport(options.sampleCount);
samples = cell(options.sampleCount, 1);
readTimes = zeros(options.sampleCount, 1);
consecutiveErrors = 0;
timer = tic;

while report.samplesRead < options.sampleCount
    try
        sample = imu.readOnce();
        consecutiveErrors = 0;
    catch exception
        report.readErrors = report.readErrors + 1;
        consecutiveErrors = consecutiveErrors + 1;
        if consecutiveErrors > config.maxConsecutiveReadErrors
            report.errors(end+1, 1) = "Превышен лимит ошибок чтения: " + ...
                string(exception.message);
            break;
        end
        options.pauseFunction(config.readRetryDelaySeconds);
        continue;
    end
    [valid, finite, message] = validateSample(sample);
    report.samplesRead = report.samplesRead + 1;
    if ~valid || ~finite
        report.fieldsValid = valid;
        report.valuesFinite = finite;
        report.errors(end+1, 1) = message;
        break;
    end
    samples{report.samplesRead} = sample;
    readTimes(report.samplesRead) = toc(timer);
    if report.samplesRead < options.sampleCount
        target = readTimes(1) + report.samplesRead * options.samplePeriodSeconds;
        options.pauseFunction(max(0, target - toc(timer)));
    end
end

complete = report.samplesRead == options.sampleCount && ...
    all(~cellfun(@isempty, samples));
report.fieldsValid = report.fieldsValid && complete;
report.valuesFinite = report.valuesFinite && complete;
if ~complete
    report.errors(end+1, 1) = sprintf('Получено %d из %d отсчётов.', ...
        report.samplesRead, options.sampleCount);
    return;
end

gravity = zeros(options.sampleCount, 3);
linear = zeros(options.sampleCount, 3);
angular = zeros(options.sampleCount, 3);
quaternionNorm = zeros(options.sampleCount, 1);
temperature = zeros(options.sampleCount, 1);
timestamps = NaT(options.sampleCount, 1);
sequences = zeros(options.sampleCount, 1, 'uint64');
for index = 1:options.sampleCount
    sample = samples{index};
    gravity(index, :) = sample.gravity(:).';
    linear(index, :) = sample.linearAcceleration(:).';
    angular(index, :) = sample.angularVelocity(:).';
    quaternionNorm(index) = norm(sample.quaternion);
    temperature(index) = sample.temperature;
    timestamps(index) = sample.hostTimestamp;
    sequences(index) = uint64(sample.sequenceNumber);
end
report.elapsedSeconds = readTimes(end) - readTimes(1);
report.averageReadFrequencyHz = (options.sampleCount - 1) / report.elapsedSeconds;
report.meanGravityMagnitude = mean(vecnorm(gravity, 2, 2));
report.gravityMagnitudeStd = std(vecnorm(gravity, 2, 2), 0);
report.meanLinearAcceleration = mean(linear, 1);
report.meanAngularVelocity = mean(angular, 1);
report.meanTemperature = mean(temperature);
report.timestampsAdvance = all(seconds(diff(timestamps)) > 0);
report.sequenceAdvances = all(diff(sequences) > 0);
report.meanQuaternionNorm = mean(quaternionNorm);
report.calibrationStatus = samples{end}.calibration;

frequencyValid = report.averageReadFrequencyHz >= options.minimumFrequencyHz && ...
    report.averageReadFrequencyHz <= options.maximumFrequencyHz;
gravityValid = abs(report.meanGravityMagnitude - config.gravityReference) <= ...
    config.maximumGravityError;
quaternionValid = abs(report.meanQuaternionNorm - 1) <= 0.1;
if ~frequencyValid, report.errors(end+1, 1) = "Частота чтения вне допустимого диапазона."; end
if ~gravityValid, report.errors(end+1, 1) = "Величина гравитации вне допустимого диапазона."; end
if ~report.timestampsAdvance, report.errors(end+1, 1) = "Временные метки не возрастают."; end
if ~report.sequenceAdvances, report.errors(end+1, 1) = "Номера последовательности не возрастают."; end
if ~quaternionValid, report.errors(end+1, 1) = "Норма кватерниона недопустима."; end
report.success = complete && report.fieldsValid && report.valuesFinite && ...
    report.timestampsAdvance && report.sequenceAdvances && frequencyValid && ...
    gravityValid && quaternionValid && isempty(report.errors);
end

function options = mergeOptions(custom, config)
options.sampleCount = config.diagnosticSampleCount;
options.samplePeriodSeconds = config.samplePeriodSeconds;
options.minimumFrequencyHz = config.minimumDiagnosticFrequencyHz;
options.maximumFrequencyHz = config.maximumDiagnosticFrequencyHz;
options.pauseFunction = @pause;
fields = fieldnames(custom);
unknown = setdiff(fields, fieldnames(options));
if ~isempty(unknown), error('IMU:InvalidDiagnosticOptions', 'Unknown option: %s', unknown{1}); end
for index = 1:numel(fields), options.(fields{index}) = custom.(fields{index}); end
end

function report = createReport(count)
report = struct('success', false, 'samplesRequested', count, ...
    'samplesRead', 0, 'readErrors', 0, 'elapsedSeconds', NaN, ...
    'averageReadFrequencyHz', NaN, 'meanGravityMagnitude', NaN, ...
    'gravityMagnitudeStd', NaN, 'meanLinearAcceleration', [NaN NaN NaN], ...
    'meanAngularVelocity', [NaN NaN NaN], 'meanTemperature', NaN, ...
    'fieldsValid', true, 'valuesFinite', true, 'timestampsAdvance', false, ...
    'sequenceAdvances', false, 'meanQuaternionNorm', NaN, ...
    'calibrationStatus', struct(), 'errors', strings(0, 1), ...
    'warnings', strings(0, 1));
end

function [valid, finite, message] = validateSample(sample)
valid = true; finite = true; message = "";
required = {'hostTimestamp','timestamp','sequenceNumber','gravity', ...
    'linearAcceleration','angularVelocity','quaternion','temperature','calibration'};
if ~isstruct(sample) || ~isscalar(sample), valid = false; message = "Отсчёт не является структурой."; return; end
for index = 1:numel(required)
    if ~isfield(sample, required{index}), valid = false; message = "Отсутствует поле " + required{index}; return; end
end
if ~(isdatetime(sample.hostTimestamp) && isscalar(sample.hostTimestamp) && ...
        isdatetime(sample.timestamp) && isscalar(sample.timestamp))
    valid = false; message = "Некорректная временная метка."; return;
end
sizes = struct('gravity',3,'linearAcceleration',3,'angularVelocity',3,'quaternion',4);
names = fieldnames(sizes);
for index = 1:numel(names)
    value = sample.(names{index});
    if ~(isnumeric(value) && numel(value) == sizes.(names{index}))
        valid = false; message = "Неверный размер поля " + names{index}; return;
    end
    if any(~isfinite(value(:))), finite = false; message = "NaN или Inf в поле " + names{index}; return; end
end
if ~(isnumeric(sample.temperature) && isscalar(sample.temperature))
    valid = false; message = "Некорректная температура.";
elseif ~isfinite(sample.temperature)
    finite = false; message = "NaN или Inf в температуре.";
end
end
