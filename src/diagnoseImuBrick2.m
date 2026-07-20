function report = diagnoseImuBrick2(imu, dependencies)
%DIAGNOSEIMUBRICK2 Diagnose IMU Brick 2.0 without running calibration.
%   REPORT = DIAGNOSEIMUBRICK2() checks the JAR, Java bindings, Brick
%   Daemon and configured physical IMU. An internally created IMU is always
%   disconnected with onCleanup.
%
%   REPORT = DIAGNOSEIMUBRICK2(IMU) performs the same sample validation on
%   an externally owned device or mock and does not disconnect that object.
%   Ordinary diagnostic failures are returned in REPORT.errors.
%
%   REPORT = DIAGNOSEIMUBRICK2(IMU, DEPENDENCIES) allows tests to override
%   the JAR path, connection probes, IMU factory, pause function and selected
%   timing configuration without requiring physical hardware.

config = getImuConfig();
if nargin < 2, dependencies = struct(); end
dependencies = mergeDependencies(dependencies);
config = applyConfigOverrides(config, dependencies.configOverrides);
report = createReport(config);
externalImu = nargin >= 1 && ~isempty(imu);

jarFile = dependencies.jarFile;
jarInfo = inspectTinkerforgeJar(jarFile);
report.jarAvailable = jarInfo.exists;
report.jarSizeBytes = jarInfo.fileSizeBytes;
report.jarSignatureValid = jarInfo.signatureValid;
if ~report.jarAvailable
    report = addError(report, "Не найден Tinkerforge.jar: " + string(jarFile));
    return;
end
if report.jarSizeBytes <= 0
    report = addError(report, "Tinkerforge.jar пуст: " + string(jarFile));
    return;
end
if ~report.jarSignatureValid
    report = addError(report, "Tinkerforge.jar не имеет ZIP/JAR-сигнатуры PK.");
    return;
end

try
    report.javaBindingsAvailable = logical( ...
        dependencies.javaBindingsCheck(jarFile, config));
catch exception
    report = addError(report, ...
        "Java bindings Tinkerforge недоступны: " + string(exception.message));
    return;
end

if externalImu
    report.brickDaemonConnected = true;
    report.imuConnected = true;
    report = collectDiagnostics(report, imu, config, dependencies.pauseFunction);
else
    try
        report.brickDaemonConnected = logical( ...
            dependencies.daemonProbe(config.host, config.port));
    catch exception
        report = addError(report, ...
            "Brick Daemon недоступен: " + string(exception.message));
        return;
    end
    if ~report.brickDaemonConnected
        report = addError(report, sprintf( ...
            'Brick Daemon недоступен по адресу %s:%d.', config.host, config.port));
        return;
    end

    try
        imu = dependencies.imuFactory(config);
        cleanup = onCleanup(@()disconnectImu(imu));
        report.imuConnected = true;
        report = collectDiagnostics(report, imu, config, dependencies.pauseFunction);
        clear cleanup;
    catch exception
        report = addError(report, "Ошибка подключения к IMU: " + string(exception.message));
    end
end

report = finishReport(report, config);
end

function report = createReport(config)
report = struct();
report.success = false;
report.uid = config.uid;
report.host = config.host;
report.port = config.port;
report.jarAvailable = false;
report.jarSizeBytes = 0;
report.jarSignatureValid = false;
report.javaBindingsAvailable = false;
report.brickDaemonConnected = false;
report.imuConnected = false;
report.samplesRequested = config.diagnosticSampleCount;
report.samplesRead = 0;
report.readErrors = 0;
report.elapsedSeconds = NaN;
report.averageReadFrequencyHz = NaN;
report.meanGravityMagnitude = NaN;
report.gravityMagnitudeStd = NaN;
report.meanLinearAcceleration = [NaN NaN NaN];
report.meanAngularVelocity = [NaN NaN NaN];
report.meanTemperature = NaN;
report.fieldsValid = false;
report.valuesFinite = false;
report.timestampsAdvance = false;
report.errors = strings(0, 1);
report.warnings = strings(0, 1);
end

function dependencies = mergeDependencies(custom)
validateattributes(custom, {'struct'}, {'scalar'});
projectRoot = fileparts(fileparts(mfilename('fullpath')));
dependencies.jarFile = fullfile(projectRoot, 'lib', 'Tinkerforge.jar');
dependencies.javaBindingsCheck = @checkJavaBindings;
dependencies.daemonProbe = @probeBrickDaemon;
dependencies.imuFactory = @(config)ImuBrick2( ...
    config.uid, config.host, config.port);
dependencies.pauseFunction = @pause;
dependencies.configOverrides = struct();
fields = fieldnames(custom);
unknown = setdiff(fields, fieldnames(dependencies));
if ~isempty(unknown)
    error('IMU:InvalidDiagnosticDependencies', ...
        'Неизвестная диагностическая зависимость: %s.', unknown{1});
end
for index = 1:numel(fields)
    dependencies.(fields{index}) = custom.(fields{index});
end
validateattributes(dependencies.jarFile, {'char','string'}, {'scalartext'});
validateattributes(dependencies.javaBindingsCheck, {'function_handle'}, {'scalar'});
validateattributes(dependencies.daemonProbe, {'function_handle'}, {'scalar'});
validateattributes(dependencies.imuFactory, {'function_handle'}, {'scalar'});
validateattributes(dependencies.pauseFunction, {'function_handle'}, {'scalar'});
validateattributes(dependencies.configOverrides, {'struct'}, {'scalar'});
end

function config = applyConfigOverrides(config, overrides)
fields = fieldnames(overrides);
allowed = {'samplePeriodSeconds','minimumDiagnosticFrequencyHz', ...
    'maximumDiagnosticFrequencyHz','maxConsecutiveReadErrors', ...
    'readRetryDelaySeconds'};
unknown = setdiff(fields, allowed);
if ~isempty(unknown)
    error('IMU:InvalidDiagnosticDependencies', ...
        'Недопустимая настройка диагностики: %s.', unknown{1});
end
for index = 1:numel(fields)
    config.(fields{index}) = overrides.(fields{index});
end
end

function available = checkJavaBindings(jarFile, config)
dynamicPath = javaclasspath('-dynamic');
staticPath = javaclasspath('-static');
if ~any(strcmp(dynamicPath, jarFile)) && ~any(strcmp(staticPath, jarFile))
    javaaddpath(jarFile);
end
ipConnection = javaObject('com.tinkerforge.IPConnection');
device = javaObject('com.tinkerforge.BrickIMUV2', char(config.uid), ipConnection);
available = ~isempty(ipConnection) && ~isempty(device);
end

function connected = probeBrickDaemon(host, port)
socket = javaObject('java.net.Socket');
cleanup = onCleanup(@()closeSocket(socket));
address = javaObject('java.net.InetSocketAddress', char(host), int32(port));
socket.connect(address, int32(2000));
connected = logical(socket.isConnected());
clear cleanup;
end

function closeSocket(socket)
try
    socket.close();
catch exception
    warning('IMU:SocketCleanupFailed', ...
        'Не удалось закрыть диагностический сокет: %s', exception.message);
end
end

function disconnectImu(imu)
try
    imu.disconnect();
catch exception
    warning('IMU:DisconnectFailed', ...
        'Не удалось отключить IMU после диагностики: %s', exception.message);
end
end

function report = collectDiagnostics(report, imu, config, pauseFunction)
count = config.diagnosticSampleCount;
gravity = zeros(count, 3);
linearAcceleration = zeros(count, 3);
angularVelocity = zeros(count, 3);
temperature = zeros(count, 1);
timestamps = cell(count, 1);
readTimes = zeros(count, 1);
required = {'gravity','linearAcceleration','angularVelocity', ...
    'quaternion','temperature'};
consecutiveErrors = 0;
allFieldsValid = true;
allValuesFinite = true;
timer = tic;

while report.samplesRead < count
    try
        sample = imu.readOnce();
        consecutiveErrors = 0;
    catch exception
        report.readErrors = report.readErrors + 1;
        consecutiveErrors = consecutiveErrors + 1;
        if consecutiveErrors > config.maxConsecutiveReadErrors
            report = addError(report, sprintf( ...
                'Превышен лимит последовательных ошибок чтения (%d): %s', ...
                config.maxConsecutiveReadErrors, exception.message));
            break;
        end
        pauseFunction(config.readRetryDelaySeconds);
        continue;
    end

    nextIndex = report.samplesRead + 1;
    report.samplesRead = nextIndex;
    [validFields, finiteValues, validationError] = validateSample(sample, required);
    if ~validFields || ~finiteValues
        allFieldsValid = validFields;
        allValuesFinite = finiteValues;
        report = addError(report, validationError);
        break;
    end

    gravity(nextIndex, :) = sample.gravity(:).';
    linearAcceleration(nextIndex, :) = sample.linearAcceleration(:).';
    angularVelocity(nextIndex, :) = sample.angularVelocity(:).';
    temperature(nextIndex) = sample.temperature;
    timestamps{nextIndex} = sample.timestamp;
    readTimes(nextIndex) = toc(timer);

    if nextIndex < count
        nextTarget = readTimes(1) + nextIndex * config.samplePeriodSeconds;
        pauseFunction(max(0, nextTarget - toc(timer)));
    end
end

report.fieldsValid = allFieldsValid && report.samplesRead == count;
report.valuesFinite = allValuesFinite && report.samplesRead == count;
if report.samplesRead < count && isempty(report.errors)
    report = addError(report, sprintf('Получено только %d из %d отсчётов.', ...
        report.samplesRead, count));
end
if report.samplesRead == 0, return; end

validRange = 1:report.samplesRead;
report.meanGravityMagnitude = mean(vecnorm(gravity(validRange, :), 2, 2));
report.gravityMagnitudeStd = std(vecnorm(gravity(validRange, :), 2, 2), 0);
report.meanLinearAcceleration = mean(linearAcceleration(validRange, :), 1);
report.meanAngularVelocity = mean(angularVelocity(validRange, :), 1);
report.meanTemperature = mean(temperature(validRange));

if report.samplesRead > 1
    report.elapsedSeconds = readTimes(report.samplesRead) - readTimes(1);
    if report.elapsedSeconds > 0
        report.averageReadFrequencyHz = ...
            (report.samplesRead - 1) / report.elapsedSeconds;
    end
    advances = false(report.samplesRead - 1, 1);
    for index = 2:report.samplesRead
        advances(index - 1) = timestampAdvances(timestamps{index - 1}, timestamps{index});
    end
    report.timestampsAdvance = all(advances);
else
    report.elapsedSeconds = 0;
end

if report.readErrors > 0 && report.samplesRead == count
    report = addWarning(report, sprintf( ...
        'Диагностика восстановилась после ошибок чтения: %d.', report.readErrors));
end
end

function [fieldsValid, valuesFinite, message] = validateSample(sample, required)
fieldsValid = true;
valuesFinite = true;
message = "";
if ~isstruct(sample) || ~isscalar(sample)
    fieldsValid = false;
    message = "Отсчёт IMU должен быть скалярной структурой.";
    return;
end
for index = 1:numel(required)
    if ~isfield(sample, required{index})
        fieldsValid = false;
        message = "В отсчёте отсутствует поле " + string(required{index}) + ".";
        return;
    end
end
if ~isfield(sample, 'timestamp')
    fieldsValid = false;
    message = "В отсчёте отсутствует поле timestamp.";
    return;
end
vectorSizes = struct('gravity', 3, 'linearAcceleration', 3, ...
    'angularVelocity', 3, 'quaternion', 4);
vectorFields = fieldnames(vectorSizes);
for index = 1:numel(vectorFields)
    field = vectorFields{index};
    value = sample.(field);
    if ~(isnumeric(value) && numel(value) == vectorSizes.(field))
        fieldsValid = false;
        message = "Поле " + string(field) + " имеет неверный размер.";
        return;
    end
    if any(~isfinite(value(:)))
        valuesFinite = false;
        message = "Поле " + string(field) + " содержит NaN или Inf.";
        return;
    end
end
if ~(isnumeric(sample.temperature) && isscalar(sample.temperature))
    fieldsValid = false;
    message = "Поле temperature должно быть числовым скаляром.";
elseif ~isfinite(sample.temperature)
    valuesFinite = false;
    message = "Поле temperature содержит NaN или Inf.";
end
end

function advances = timestampAdvances(previous, current)
try
    if isdatetime(previous) && isdatetime(current) && ...
            isscalar(previous) && isscalar(current) && ...
            ~ismissing(previous) && ~ismissing(current)
        advances = seconds(current - previous) > 0;
    elseif isduration(previous) && isduration(current) && ...
            isscalar(previous) && isscalar(current)
        advances = seconds(current - previous) > 0;
    elseif isnumeric(previous) && isnumeric(current) && ...
            isscalar(previous) && isscalar(current) && ...
            isfinite(previous) && isfinite(current)
        advances = current > previous;
    else
        advances = false;
    end
catch
    advances = false;
end
end

function report = finishReport(report, config)
if report.samplesRead ~= report.samplesRequested
    report = addErrorOnce(report, sprintf('Получено %d из %d запрошенных отсчётов.', ...
        report.samplesRead, report.samplesRequested));
end
if report.samplesRead == report.samplesRequested && ~report.timestampsAdvance
    report = addError(report, "Временные метки отсчётов не возрастают.");
end
if isfinite(report.meanGravityMagnitude) && ...
        abs(report.meanGravityMagnitude - config.gravityReference) > ...
        config.maximumGravityError
    report = addError(report, sprintf( ...
        'Средняя величина гравитации %.3f м/с^2 вне допустимого диапазона.', ...
        report.meanGravityMagnitude));
end
frequencyValid = isfinite(report.averageReadFrequencyHz) && ...
    report.averageReadFrequencyHz >= config.minimumDiagnosticFrequencyHz && ...
    report.averageReadFrequencyHz <= config.maximumDiagnosticFrequencyHz;
if report.samplesRead == report.samplesRequested && ~frequencyValid
    report = addError(report, sprintf( ...
        'Частота %.2f Гц вне допустимого диапазона %.1f–%.1f Гц.', ...
        report.averageReadFrequencyHz, config.minimumDiagnosticFrequencyHz, ...
        config.maximumDiagnosticFrequencyHz));
end
report.success = report.jarAvailable && report.jarSizeBytes > 0 && ...
    report.jarSignatureValid && report.javaBindingsAvailable && ...
    report.brickDaemonConnected && report.imuConnected && ...
    report.samplesRead == report.samplesRequested && report.fieldsValid && ...
    report.valuesFinite && report.timestampsAdvance && frequencyValid && ...
    isfinite(report.meanGravityMagnitude) && ...
    abs(report.meanGravityMagnitude - config.gravityReference) <= ...
    config.maximumGravityError && isempty(report.errors);
end

function report = addError(report, message)
report.errors(end + 1, 1) = string(message);
end

function report = addErrorOnce(report, message)
message = string(message);
if ~any(report.errors == message)
    report.errors(end + 1, 1) = message;
end
end

function report = addWarning(report, message)
report.warnings(end + 1, 1) = string(message);
end
