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
    report.configuredUidMatches && report.firmwareVersionValid && ...
    report.sensorFusionModeValid && ...
    report.synchronousSamplesRead >= 20 && report.callbackSamplesRead >= 100 && ...
    report.callbackFrequencyHz >= config.minimumDiagnosticFrequencyHz && ...
    report.callbackFrequencyHz <= config.maximumDiagnosticFrequencyHz && ...
    report.callbackTimestampsAdvance && report.callbackSequenceAdvances && ...
    report.callbackMissingSequences == 0 && ...
    report.callbackDroppedSamples <= config.preflightMaximumDroppedSamples && ...
    report.callbackMaximumAgeMs <= 2 * config.callbackPeriodMs && ...
    report.callbackRestartClean && ...
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
report.firmwareVersion = double(report.identity.firmwareVersion(:)).';
report.firmwareVersionValid = versionAtLeast( ...
    report.firmwareVersion, config.minimumFirmwareVersion);
if ~report.firmwareVersionValid
    report.errors(end+1, 1) = sprintf( ...
        ['Firmware IMU %s is too old. Version %s or newer is required ', ...
         'because 2.0.11 and older have erroneous callback periods.'], ...
        join(string(report.firmwareVersion), "."), ...
        join(string(config.minimumFirmwareVersion), "."));
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

imu.clearCallbackBuffer();
imu.start(config.callbackPeriodMs);
[callback, callbackErrors] = collectCallbacks(imu, config, dependencies.pauseFunction);
report.callbackSamplesRead = callback.count;
report.callbackFrequencyHz = callback.frequencyHz;
report.callbackTimestampsAdvance = callback.timestampsAdvance;
report.callbackSequenceAdvances = callback.sequenceAdvances;
report.callbackFirstSequence = callback.firstSequence;
report.callbackLastSequence = callback.lastSequence;
report.callbackMissingSequences = callback.missingSequences;
report.callbackDroppedSamples = callback.droppedSamples;
report.callbackMaximumAgeMs = callback.maximumAgeMs;
report.callbackBufferMaximumSize = config.callbackBufferMaximumSize;
report.callbackRestartClean = callback.restartClean;
if ~isempty(callbackErrors), report.errors = [report.errors; callbackErrors]; end
clear streamCleanup;
end

function [result, errors] = collectCallbacks(imu, config, pauseFunction)
count = 100;
sequences = zeros(count, 1, 'uint64');
timestamps = zeros(count, 1);
agesMs = NaN(count, 1);
received = 0;
timer = tic;
timeout = max(5, count * config.callbackPeriodMs / 1000 * 3);
errors = strings(0, 1);
while received < count && toc(timer) < timeout
    sampleAvailable = false;
    try
        sample = imu.nextCallbackMetadata();
        if ~isempty(sample)
            sampleAvailable = true;
            received = received + 1;
            sequences(received) = uint64(sample.sequenceNumber);
            timestamps(received) = sample.timestampMillis / 1000;
            agesMs(received) = 1000 * posixtime( ...
                datetime('now', 'TimeZone', 'UTC')) - sample.timestampMillis;
        end
    catch exception
        if ~contains(string(exception.identifier), "NotStreaming")
            errors(end+1, 1) = string(exception.message); %#ok<AGROW>
            break;
        end
    end
    if ~sampleAvailable, pauseFunction(0.001); end
end
result.count = received;
result.frequencyHz = NaN;
result.timestampsAdvance = false;
result.sequenceAdvances = false;
result.firstSequence = uint64(0);
result.lastSequence = uint64(0);
result.missingSequences = Inf;
result.droppedSamples = Inf;
result.maximumAgeMs = Inf;
result.restartClean = false;
if received >= 2
    elapsed = timestamps(received) - timestamps(1);
    if elapsed > 0, result.frequencyHz = (received - 1) / elapsed; end
    result.timestampsAdvance = all(diff(timestamps(1:received)) > 0);
    result.sequenceAdvances = all(diff(sequences(1:received)) > 0);
    result.firstSequence = sequences(1);
    result.lastSequence = sequences(received);
    result.missingSequences = sum(max(0, ...
        diff(double(sequences(1:received))) - 1));
    result.maximumAgeMs = max(agesMs(1:received));
    result.restartClean = result.firstSequence == uint64(1);
end
stats = imu.getCallbackStats();
result.droppedSamples = double(stats.dropped);
if received < count, errors(end+1, 1) = sprintf('Callback: получено %d из %d отсчётов.', received, count); end
if ~(result.frequencyHz >= config.minimumDiagnosticFrequencyHz && ...
        result.frequencyHz <= config.maximumDiagnosticFrequencyHz)
    errors(end+1, 1) = "Частота callback вне допустимого диапазона.";
end
if ~result.timestampsAdvance, errors(end+1, 1) = "Callback timestamps не возрастают."; end
if ~result.sequenceAdvances, errors(end+1, 1) = "Callback sequence numbers не возрастают."; end
if result.missingSequences ~= 0, errors(end+1, 1) = "Callback sequence contains missing samples."; end
if result.droppedSamples > config.preflightMaximumDroppedSamples, errors(end+1, 1) = "Callback buffer dropped samples."; end
if result.maximumAgeMs > 2 * config.callbackPeriodMs, errors(end+1, 1) = "Callback sample is too old."; end
if ~result.restartClean, errors(end+1, 1) = "Callback restart returned stale session data."; end
end

function restoreStream(imu, wasStreaming, previousPeriod)
try
    imu.stop();
    imu.clearCallbackBuffer();
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
    'firmwareVersion', [NaN NaN NaN], 'firmwareVersionValid', false, ...
    'sensorFusionMode', NaN, 'sensorFusionModeValid', false, ...
    'samplesRequested', 0, 'samplesRead', 0, 'readErrors', 0, ...
    'elapsedSeconds', NaN, 'averageReadFrequencyHz', NaN, ...
    'meanGravityMagnitude', NaN, 'gravityMagnitudeStd', NaN, ...
    'meanLinearAcceleration', [NaN NaN NaN], ...
    'meanAngularVelocity', [NaN NaN NaN], 'meanTemperature', NaN, ...
    'fieldsValid', false, 'valuesFinite', false, 'timestampsAdvance', false, ...
    'synchronousSamplesRead', 0, 'callbackSamplesRead', 0, ...
    'callbackFrequencyHz', NaN, 'callbackTimestampsAdvance', false, ...
    'callbackSequenceAdvances', false, 'callbackFirstSequence', uint64(0), ...
    'callbackLastSequence', uint64(0), 'callbackMissingSequences', Inf, ...
    'callbackDroppedSamples', Inf, 'callbackMaximumAgeMs', Inf, ...
    'callbackBufferMaximumSize', config.callbackBufferMaximumSize, ...
    'callbackRestartClean', false, 'meanQuaternionNorm', NaN, ...
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

function valid = versionAtLeast(actual, required)
width = max(numel(actual), numel(required));
actual(end+1:width) = 0;
required(end+1:width) = 0;
different = find(actual ~= required, 1, 'first');
valid = isempty(different) || actual(different) > required(different);
end

function connected = probeDaemon(host, port)
socket = javaObject('java.net.Socket');
cleanup = onCleanup(@()socket.close());
address = javaObject('java.net.InetSocketAddress', char(host), int32(port));
socket.connect(address, int32(2000));
connected = logical(socket.isConnected());
clear cleanup;
end
