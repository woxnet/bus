function report = diagnoseImuBrick2(imu, dependencies)
%DIAGNOSEIMUBRICK2 Run full hardware preflight for IMU Brick 2.0.
%   REPORT = DIAGNOSEIMUBRICK2() validates local bindings, Brick Daemon,
%   identity, sensor fusion, synchronous data and a 50 Hz callback stream.
%   An internally created device is disconnected automatically.
%
%   REPORT = DIAGNOSEIMUBRICK2(IMU) uses an existing hardware connection,
%   does not disconnect it, and restores its exact previous stream state.

config = getImuConfig();
if nargin < 2, dependencies = struct(); end
dependencies = mergeDependencies(dependencies);
external = nargin >= 1 && ~isempty(imu);
report = createReport(config);

jarInfo = inspectTinkerforgeJar(dependencies.jarFile);
report.jarAvailable = jarInfo.exists;
report.jarSizeBytes = jarInfo.fileSizeBytes;
report.jarSignatureValid = jarInfo.signatureValid;
bindings = dependencies.bindingsLoader(dependencies.jarFile);
report.javaBindingsAvailable = bindings.available;
if ~bindings.available
    report.errors = [report.errors; bindings.errors];
    return;
end

if ~external
    try
        report.brickDaemonConnected = dependencies.daemonProbe(config.host, config.port);
        if ~report.brickDaemonConnected
            report.errors(end+1, 1) = "Brick Daemon недоступен.";
            return;
        end
        imu = dependencies.imuFactory(config);
        ownerCleanup = onCleanup(@()imu.disconnect());
        report.imuConnected = true;
        report = runHardwarePhases(report, imu, config, dependencies);
        clear ownerCleanup;
    catch exception
        report.errors(end+1, 1) = string(exception.message);
    end
else
    report.brickDaemonConnected = true;
    report.imuConnected = true;
    try
        report = runHardwarePhases(report, imu, config, dependencies);
    catch exception
        report.errors(end+1, 1) = string(exception.message);
    end
end
report.success = report.jarAvailable && report.jarSizeBytes > 0 && ...
    report.jarSignatureValid && report.javaBindingsAvailable && ...
    report.brickDaemonConnected && report.imuConnected && ...
    report.configuredUidMatches && report.sensorFusionModeValid && ...
    report.synchronousSamplesRead >= 20 && report.callbackSamplesRead >= 100 && ...
    report.callbackFrequencyHz >= config.minimumDiagnosticFrequencyHz && ...
    report.callbackFrequencyHz <= config.maximumDiagnosticFrequencyHz && ...
    report.callbackTimestampsAdvance && report.callbackSequenceAdvances && ...
    abs(report.meanGravityMagnitude - config.gravityReference) <= ...
    config.maximumGravityError && abs(report.meanQuaternionNorm - 1) <= 0.1 && ...
    isempty(report.errors);
end

function report = runHardwarePhases(report, imu, config, dependencies)
report.identity = imu.getIdentity();
report.configuredUidMatches = string(report.identity.uid) == config.uid;
if ~report.configuredUidMatches
    report.errors(end+1, 1) = "UID устройства не совпадает с конфигурацией.";
    return;
end
imu.setSensorFusionMode(config.sensorFusionMode);
report.sensorFusionMode = imu.getSensorFusionMode();
report.sensorFusionModeValid = report.sensorFusionMode == config.sensorFusionMode;
if ~report.sensorFusionModeValid
    report.errors(end+1, 1) = "Sensor fusion mode не был применён.";
    return;
end
dependencies.pauseFunction(dependencies.fusionSettleDelaySeconds);

wasStreaming = logical(imu.IsStreaming);
previousPeriod = double(imu.StreamingPeriodMs);
streamCleanup = onCleanup(@()restoreStream(imu, wasStreaming, previousPeriod));
if wasStreaming, imu.stop(); end

syncOptions = struct('sampleCount', 20, ...
    'samplePeriodSeconds', config.samplePeriodSeconds, ...
    'minimumFrequencyHz', 0, 'maximumFrequencyHz', Inf, ...
    'pauseFunction', dependencies.pauseFunction);
sync = diagnoseImuDataSource(imu, syncOptions);
report.synchronousSamplesRead = sync.samplesRead;
report.samplesRequested = sync.samplesRequested;
report.samplesRead = sync.samplesRead;
report.readErrors = sync.readErrors;
report.elapsedSeconds = sync.elapsedSeconds;
report.averageReadFrequencyHz = sync.averageReadFrequencyHz;
report.meanGravityMagnitude = sync.meanGravityMagnitude;
report.gravityMagnitudeStd = sync.gravityMagnitudeStd;
report.meanLinearAcceleration = sync.meanLinearAcceleration;
report.meanAngularVelocity = sync.meanAngularVelocity;
report.meanTemperature = sync.meanTemperature;
report.fieldsValid = sync.fieldsValid;
report.valuesFinite = sync.valuesFinite;
report.timestampsAdvance = sync.timestampsAdvance;
report.meanQuaternionNorm = sync.meanQuaternionNorm;
report.calibrationStatus = sync.calibrationStatus;
if ~sync.success
    report.errors = [report.errors; sync.errors];
    clear streamCleanup;
    return;
end

imu.start(config.callbackPeriodMs);
[callback, callbackErrors] = collectCallbacks(imu, config, dependencies.pauseFunction);
report.callbackSamplesRead = callback.count;
report.callbackFrequencyHz = callback.frequencyHz;
report.callbackTimestampsAdvance = callback.timestampsAdvance;
report.callbackSequenceAdvances = callback.sequenceAdvances;
if ~isempty(callbackErrors), report.errors = [report.errors; callbackErrors]; end
clear streamCleanup;
end

function [result, errors] = collectCallbacks(imu, config, pauseFunction)
count = 100;
sequences = zeros(count, 1, 'uint64');
timestamps = NaT(count, 1);
received = 0;
lastSequence = uint64(0);
timer = tic;
timeout = max(5, count * config.callbackPeriodMs / 1000 * 3);
errors = strings(0, 1);
while received < count && toc(timer) < timeout
    try
        sample = imu.latest();
        sequence = uint64(sample.sequenceNumber);
        if sequence ~= lastSequence
            received = received + 1;
            sequences(received) = sequence;
            timestamps(received) = sample.hostTimestamp;
            lastSequence = sequence;
        end
    catch exception
        if ~contains(string(exception.message), "не получены") && ...
                ~contains(string(exception.identifier), "NotStreaming")
            errors(end+1, 1) = string(exception.message); %#ok<AGROW>
            break;
        end
    end
    pauseFunction(0.001);
end
result.count = received;
result.frequencyHz = NaN;
result.timestampsAdvance = false;
result.sequenceAdvances = false;
if received >= 2
    elapsed = seconds(timestamps(received) - timestamps(1));
    if elapsed > 0, result.frequencyHz = (received - 1) / elapsed; end
    result.timestampsAdvance = all(seconds(diff(timestamps(1:received))) > 0);
    result.sequenceAdvances = all(diff(sequences(1:received)) > 0);
end
if received < count, errors(end+1, 1) = sprintf('Callback: получено %d из %d отсчётов.', received, count); end
if ~(result.frequencyHz >= config.minimumDiagnosticFrequencyHz && ...
        result.frequencyHz <= config.maximumDiagnosticFrequencyHz)
    errors(end+1, 1) = "Частота callback вне допустимого диапазона.";
end
if ~result.timestampsAdvance, errors(end+1, 1) = "Callback timestamps не возрастают."; end
if ~result.sequenceAdvances, errors(end+1, 1) = "Callback sequence numbers не возрастают."; end
end

function restoreStream(imu, wasStreaming, previousPeriod)
try
    imu.stop();
    if wasStreaming, imu.start(previousPeriod); end
catch exception
    warning('IMU:StreamRestoreFailed', 'Не удалось восстановить поток: %s', exception.message);
end
end

function report = createReport(config)
report = struct('success', false, 'uid', config.uid, 'host', config.host, ...
    'port', config.port, 'jarAvailable', false, 'jarSizeBytes', 0, ...
    'jarSignatureValid', false, 'javaBindingsAvailable', false, ...
    'brickDaemonConnected', false, 'imuConnected', false, ...
    'identity', struct(), 'configuredUidMatches', false, ...
    'sensorFusionMode', NaN, 'sensorFusionModeValid', false, ...
    'samplesRequested', 0, 'samplesRead', 0, 'readErrors', 0, ...
    'elapsedSeconds', NaN, 'averageReadFrequencyHz', NaN, ...
    'meanGravityMagnitude', NaN, 'gravityMagnitudeStd', NaN, ...
    'meanLinearAcceleration', [NaN NaN NaN], ...
    'meanAngularVelocity', [NaN NaN NaN], 'meanTemperature', NaN, ...
    'fieldsValid', false, 'valuesFinite', false, 'timestampsAdvance', false, ...
    'synchronousSamplesRead', 0, 'callbackSamplesRead', 0, ...
    'callbackFrequencyHz', NaN, 'callbackTimestampsAdvance', false, ...
    'callbackSequenceAdvances', false, 'meanQuaternionNorm', NaN, ...
    'calibrationStatus', struct(), 'errors', strings(0, 1), ...
    'warnings', strings(0, 1));
end

function dependencies = mergeDependencies(custom)
root = fileparts(fileparts(mfilename('fullpath')));
dependencies.jarFile = fullfile(root, 'lib', 'Tinkerforge.jar');
dependencies.bindingsLoader = @loadTinkerforgeBindings;
dependencies.daemonProbe = @probeDaemon;
dependencies.imuFactory = @(config)ImuBrick2(config.uid, config.host, config.port);
dependencies.pauseFunction = @pause;
dependencies.fusionSettleDelaySeconds = 0.5;
fields = fieldnames(custom);
for index = 1:numel(fields), dependencies.(fields{index}) = custom.(fields{index}); end
end

function connected = probeDaemon(host, port)
socket = javaObject('java.net.Socket');
cleanup = onCleanup(@()socket.close());
address = javaObject('java.net.InetSocketAddress', char(host), int32(port));
socket.connect(address, int32(2000));
connected = logical(socket.isConnected());
clear cleanup;
end
