function report = diagnoseImuBrick2(options)
%DIAGNOSEIMUBRICK2 Run hardware diagnostics without performing calibration.
%   REPORT = DIAGNOSEIMUBRICK2() checks the Tinkerforge Java bindings, Brick
%   Daemon connection and IMU Brick 2.0 readings. Ordinary diagnostic
%   failures are returned in REPORT.errors instead of being rethrown.
%
%   REPORT = DIAGNOSEIMUBRICK2(OPTIONS) supports dependency overrides for
%   hardware-independent tests. This form is intended for unit testing.

config = getImuConfig();
report = createReport(config);
if nargin < 1, options = struct(); end

try
    options = mergeOptions(options, config);
catch exception
    report.errors{end+1} = exception.message;
    return;
end

report.jarAvailable = isfile(options.jarFile);
if ~report.jarAvailable
    report.errors{end+1} = sprintf('Не найден Tinkerforge.jar: %s', options.jarFile);
    return;
end

try
    report.javaBindingsAvailable = logical(options.javaBindingsCheck(options.jarFile, config));
catch exception
    report.errors{end+1} = ['Java bindings Tinkerforge недоступны: ', exception.message];
    return;
end
if ~report.javaBindingsAvailable
    report.errors{end+1} = 'Java bindings Tinkerforge недоступны.';
    return;
end

try
    report.brickDaemonConnected = logical(options.daemonProbe(config.host, config.port));
catch exception
    report.errors{end+1} = ['Brick Daemon недоступен: ', exception.message];
    return;
end
if ~report.brickDaemonConnected
    report.errors{end+1} = sprintf('Brick Daemon недоступен по адресу %s:%d.', ...
        config.host, config.port);
    return;
end

try
    imu = options.imuFactory(config);
    cleanup = onCleanup(@()disconnectImu(imu));
    report.imuConnected = true;
    [report, samples] = readAndValidateSamples(report, imu, options, config);
    if isempty(report.errors)
        report = calculateStatistics(report, samples, config);
    end
    clear cleanup;
catch exception
    report.errors{end+1} = ['Ошибка IMU: ', exception.message];
end
report.success = isempty(report.errors) && report.jarAvailable && ...
    report.javaBindingsAvailable && report.brickDaemonConnected && ...
    report.imuConnected && report.samplesRead >= options.sampleCount;
end

function report = createReport(config)
report = struct('success', false, 'uid', config.uid, 'host', config.host, ...
    'port', config.port, 'jarAvailable', false, ...
    'javaBindingsAvailable', false, 'brickDaemonConnected', false, ...
    'imuConnected', false, 'samplesRead', 0, ...
    'averageReadFrequencyHz', NaN, 'meanGravityMagnitude', NaN, ...
    'meanAngularVelocity', [NaN NaN NaN], 'temperature', NaN, ...
    'errors', {{}}, 'warnings', {{}});
end

function options = mergeOptions(options, config)
if ~isstruct(options) || ~isscalar(options)
    error('IMU:InvalidDiagnosticOptions', 'Diagnostic options must be a scalar structure.');
end
projectRoot = fileparts(fileparts(mfilename('fullpath')));
defaults.jarFile = fullfile(projectRoot, 'lib', 'Tinkerforge.jar');
defaults.javaBindingsCheck = @checkJavaBindings;
defaults.daemonProbe = @probeBrickDaemon;
defaults.imuFactory = @(value)ImuBrick2(value.uid, value.host, value.port);
defaults.sampleCount = 20;
defaults.paceReads = true;
fields = fieldnames(options);
unknown = setdiff(fields, fieldnames(defaults));
if ~isempty(unknown)
    error('IMU:InvalidDiagnosticOptions', 'Unknown diagnostic option: %s.', unknown{1});
end
for index = 1:numel(fields), defaults.(fields{index}) = options.(fields{index}); end
options = defaults;
validateattributes(options.jarFile, {'char','string'}, {'scalartext'});
validateattributes(options.javaBindingsCheck, {'function_handle'}, {'scalar'});
validateattributes(options.daemonProbe, {'function_handle'}, {'scalar'});
validateattributes(options.imuFactory, {'function_handle'}, {'scalar'});
validateattributes(options.sampleCount, {'numeric'}, {'scalar','integer','>=',20});
validateattributes(options.paceReads, {'logical'}, {'scalar'});
validateattributes(config.sampleRateHz, {'numeric'}, {'scalar','positive'});
end

function available = checkJavaBindings(jarFile, config)
dynamicPath = javaclasspath('-dynamic');
staticPath = javaclasspath('-static');
if ~any(strcmp(dynamicPath, jarFile)) && ~any(strcmp(staticPath, jarFile))
    javaaddpath(jarFile);
end
ipConnection = javaObject('com.tinkerforge.IPConnection');
device = javaObject('com.tinkerforge.BrickIMUV2', char(config.uid), ipConnection); %#ok<NASGU>
available = true;
end

function connected = probeBrickDaemon(host, port)
socket = javaObject('java.net.Socket');
cleanup = onCleanup(@()closeSocket(socket));
address = javaObject('java.net.InetSocketAddress', char(host), int32(port));
socket.connect(address, int32(2000));
connected = socket.isConnected();
end

function closeSocket(socket)
try
    socket.close();
catch exception
    warning('IMU:SocketCleanupFailed', 'Не удалось закрыть диагностический сокет: %s', ...
        exception.message);
end
end

function disconnectImu(imu)
if isempty(imu), return; end
try
    imu.disconnect();
catch exception
    warning('IMU:DisconnectFailed', 'Не удалось отключить IMU: %s', exception.message);
end
end

function [report, samples] = readAndValidateSamples(report, imu, options, config)
required = {'gravity','linearAcceleration','angularVelocity', ...
    'quaternion','temperature'};
samples = cell(options.sampleCount, 1);
readTimes = zeros(options.sampleCount, 1);
timer = tic;
for index = 1:options.sampleCount
    iterationTimer = tic;
    sample = imu.readOnce();
    for fieldIndex = 1:numel(required)
        field = required{fieldIndex};
        if ~isstruct(sample) || ~isfield(sample, field)
            error('IMU:InvalidDiagnosticSample', 'В отсчёте отсутствует поле %s.', field);
        end
        value = sample.(field);
        if ~(isnumeric(value) && ~isempty(value) && all(isfinite(value(:))))
            error('IMU:InvalidDiagnosticSample', ...
                'Поле %s содержит NaN, Inf или некорректные данные.', field);
        end
    end
    if numel(sample.gravity) ~= 3 || numel(sample.linearAcceleration) ~= 3 || ...
            numel(sample.angularVelocity) ~= 3 || numel(sample.quaternion) ~= 4 || ...
            ~isscalar(sample.temperature)
        error('IMU:InvalidDiagnosticSample', 'Некорректные размеры полей отсчёта IMU.');
    end
    samples{index} = sample;
    report.samplesRead = index;
    readTimes(index) = toc(timer);
    if options.paceReads && index < options.sampleCount
        pause(max(0, 1 / config.sampleRateHz - toc(iterationTimer)));
    end
end
if options.sampleCount > 1
    elapsed = readTimes(end) - readTimes(1);
    if elapsed > 0
        report.averageReadFrequencyHz = (options.sampleCount - 1) / elapsed;
    end
end
end

function report = calculateStatistics(report, samples, config)
gravity = zeros(numel(samples), 3);
angularVelocity = zeros(numel(samples), 3);
temperature = zeros(numel(samples), 1);
for index = 1:numel(samples)
    gravity(index, :) = samples{index}.gravity(:).';
    angularVelocity(index, :) = samples{index}.angularVelocity(:).';
    temperature(index) = samples{index}.temperature;
end
report.meanGravityMagnitude = mean(vecnorm(gravity, 2, 2));
report.meanAngularVelocity = mean(angularVelocity, 1);
report.temperature = mean(temperature);
if abs(report.meanGravityMagnitude - 9.81) >= 1.5
    report.errors{end+1} = sprintf( ...
        'Средняя величина гравитации %.3f м/с^2 вне допустимого диапазона.', ...
        report.meanGravityMagnitude);
end
if isfinite(report.averageReadFrequencyHz) && ...
        abs(report.averageReadFrequencyHz - config.sampleRateHz) > 0.25 * config.sampleRateHz
    report.warnings{end+1} = sprintf( ...
        'Средняя частота чтения %.1f Гц отличается от заданных %.1f Гц.', ...
        report.averageReadFrequencyHz, config.sampleRateHz);
end
end
