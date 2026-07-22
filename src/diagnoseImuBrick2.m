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
    report.callbackOverflowDropped <= config.maximumPreflightDroppedCallbacks && ...
    report.callbackStaleSessionDropped == 0 && ...
    report.callbackMaximumAgeMs <= config.maximumCallbackSampleAgeMs && ...
    report.callbackBufferCapacity == config.callbackBufferMaximumSize && ...
    report.callbackPayloadsDecoded >= 100 && ...
    report.callbackPayloadFieldsValid && report.callbackPayloadValuesFinite && ...
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
previousOwner = "callback";
if isprop(imu,'StreamOwner'), previousOwner=string(imu.StreamOwner); end
if wasStreaming && ~any(previousOwner==["none","callback"])
    error('IMU:DiagnosticsRequiresExclusiveAccess', ...
        'Diagnostics cannot stop a stream owned by %s.',previousOwner);
end
streamCleanup = onCleanup(@()restoreStream(imu, wasStreaming, previousPeriod,previousOwner));
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
warmUpCallbackDecoder(imu, dependencies.pauseFunction, config.callbackPeriodMs);
imu.clearCallbackBuffer();
initialCallbackStats = imu.getCallbackStats();
[callback, callbackErrors] = collectCallbacks(imu, config, ...
    dependencies.pauseFunction, initialCallbackStats);
report.callbackSamplesRead = callback.count;
report.callbackReceivedTotal = callback.receivedTotal;
report.callbackFrequencyHz = callback.frequencyHz;
report.callbackTimestampsAdvance = callback.timestampsAdvance;
report.callbackSequenceAdvances = callback.sequenceAdvances;
report.callbackFirstSequence = callback.firstSequence;
report.callbackLastSequence = callback.lastSequence;
report.callbackMissingSequences = callback.missingSequences;
report.callbackDroppedSamples = callback.droppedSamples;
report.callbackOverflowDropped = callback.overflowDropped;
report.callbackCoalesced = callback.coalesced;
report.callbackStaleSessionDropped = callback.staleSessionDropped;
report.callbackBufferCapacity = callback.bufferCapacity;
report.callbackMaximumBuffered = callback.maximumBuffered;
report.callbackMeanAgeMs = callback.meanAgeMs;
report.callbackMaximumAgeMs = callback.maximumAgeMs;
report.callbackPayloadsDecoded = callback.payloadsDecoded;
report.callbackPayloadFieldsValid = callback.payloadFieldsValid;
report.callbackPayloadValuesFinite = callback.payloadValuesFinite;
report.callbackQuaternionNormMean = callback.quaternionNormMean;
if ~isempty(callbackErrors), report.errors = [report.errors; callbackErrors]; end
clear streamCleanup;
end

function warmUpCallbackDecoder(imu, pauseFunction, periodMs)
target = 10;
decoded = 0;
timer = tic;
while decoded < target && toc(timer) < max(2, target * periodMs / 1000 * 3)
    sample = imu.nextCallbackSample();
    if isempty(sample)
        pauseFunction(0.001);
    else
        decoded = decoded + 1;
    end
end
end

function [result, errors] = collectCallbacks(imu, config, pauseFunction, initialStats)
count = 100;
sequences = zeros(count, 1, 'uint64');
timestamps = zeros(count, 1);
agesMs = NaN(count, 1);
received = 0;
maximumBuffered = 0;
payloadFieldsValid = true;
payloadValuesFinite = true;
quaternionNorms = NaN(count, 1);
timer = tic;
timeout = max(5, count * config.callbackPeriodMs / 1000 * 3);
errors = strings(0, 1);
while received < count && toc(timer) < timeout
    sampleAvailable = false;
    try
        currentStats = imu.getCallbackStats();
        maximumBuffered = max(maximumBuffered, double(currentStats.buffered));
        sample = imu.nextCallbackSample();
        if ~isempty(sample)
            sampleAvailable = true;
            received = received + 1;
            sequences(received) = uint64(sample.sequenceNumber);
            timestamps(received) = double(sample.callbackTimestampNanos) / 1e9;
            agesMs(received) = sample.callbackAgeMs;
            [fieldsValid, valuesFinite, quaternionNorm] = ...
                validateCallbackPayload(sample, initialStats.sessionId);
            payloadFieldsValid = payloadFieldsValid && fieldsValid;
            payloadValuesFinite = payloadValuesFinite && valuesFinite;
            quaternionNorms(received) = quaternionNorm;
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
result.receivedTotal = 0;
result.droppedSamples = Inf;
result.overflowDropped = Inf;
result.coalesced = Inf;
result.staleSessionDropped = Inf;
result.bufferCapacity = double(initialStats.capacity);
result.maximumBuffered = maximumBuffered;
result.meanAgeMs = Inf;
result.maximumAgeMs = Inf;
result.payloadsDecoded = received;
result.payloadFieldsValid = payloadFieldsValid;
result.payloadValuesFinite = payloadValuesFinite;
result.quaternionNormMean = NaN;
if received >= 2
    elapsed = timestamps(received) - timestamps(1);
    if elapsed > 0, result.frequencyHz = (received - 1) / elapsed; end
    result.timestampsAdvance = all(diff(timestamps(1:received)) > 0);
    result.sequenceAdvances = all(diff(sequences(1:received)) > 0);
    result.firstSequence = sequences(1);
    result.lastSequence = sequences(received);
    result.missingSequences = sum(max(0, ...
        diff(double(sequences(1:received))) - 1));
    result.meanAgeMs = mean(agesMs(1:received));
    result.maximumAgeMs = max(agesMs(1:received));
    result.quaternionNormMean = mean(quaternionNorms(1:received));
end
stats = imu.getCallbackStats();
result.receivedTotal = double(stats.received);
result.overflowDropped = double(stats.overflowDropped);
result.coalesced = double(stats.coalesced);
result.staleSessionDropped = double(stats.staleSessionDropped);
result.droppedSamples = result.overflowDropped;
result.payloadsDecoded = received;
result.bufferCapacity = double(stats.capacity);
result.maximumBuffered = max(result.maximumBuffered, double(stats.buffered));
if received < count, errors(end+1, 1) = sprintf('Callback: получено %d из %d отсчётов.', received, count); end
if ~(result.frequencyHz >= config.minimumDiagnosticFrequencyHz && ...
        result.frequencyHz <= config.maximumDiagnosticFrequencyHz)
    errors(end+1, 1) = "Частота callback вне допустимого диапазона.";
end
if ~result.timestampsAdvance, errors(end+1, 1) = "Callback timestamps не возрастают."; end
if ~result.sequenceAdvances, errors(end+1, 1) = "Callback sequence numbers не возрастают."; end
if result.missingSequences ~= 0, errors(end+1, 1) = "Callback sequence contains missing samples."; end
if result.overflowDropped > config.maximumPreflightDroppedCallbacks, errors(end+1, 1) = "Callback buffer overflow dropped samples."; end
if result.staleSessionDropped > 0, errors(end+1, 1) = "Stale-session callbacks were received."; end
if result.maximumAgeMs > config.maximumCallbackSampleAgeMs, errors(end+1, 1) = "Callback sample is too old."; end
if result.bufferCapacity ~= config.callbackBufferMaximumSize, errors(end+1, 1) = "Callback buffer capacity does not match configuration."; end
if ~result.payloadFieldsValid, errors(end+1, 1) = "Callback payload fields are invalid."; end
if ~result.payloadValuesFinite, errors(end+1, 1) = "Callback payload contains non-finite values."; end
if abs(result.quaternionNormMean - 1) > 0.1, errors(end+1, 1) = "Callback quaternion norm is invalid."; end
end

function [fieldsValid, valuesFinite, quaternionNorm] = validateCallbackPayload(sample, sessionId)
required = {'gravity','linearAcceleration','angularVelocity','quaternion', ...
    'temperature','calibration','source','sessionId','sequenceNumber', ...
    'callbackTimestampNanos'};
fieldsValid = isstruct(sample) && all(isfield(sample, required));
valuesFinite = false;
quaternionNorm = NaN;
if ~fieldsValid, return; end
fieldsValid = isequal(size(sample.gravity), [1 3]) && ...
    isequal(size(sample.linearAcceleration), [1 3]) && ...
    isequal(size(sample.angularVelocity), [1 3]) && ...
    isequal(size(sample.quaternion), [1 4]) && isscalar(sample.temperature) && ...
    string(sample.source) == "callback" && ...
    uint64(sample.sessionId) == uint64(sessionId) && ...
    isscalar(sample.sequenceNumber) && isstruct(sample.calibration);
calibrationFields = {'magnetometer','accelerometer','gyroscope','system'};
fieldsValid = fieldsValid && all(isfield(sample.calibration, calibrationFields));
if ~fieldsValid, return; end
numeric = [sample.gravity(:); sample.linearAcceleration(:); ...
    sample.angularVelocity(:); sample.quaternion(:); sample.temperature; ...
    sample.calibration.magnetometer; sample.calibration.accelerometer; ...
    sample.calibration.gyroscope; sample.calibration.system];
valuesFinite = isnumeric(numeric) && all(isfinite(numeric));
quaternionNorm = norm(sample.quaternion);
end

function restoreStream(imu, wasStreaming, previousPeriod,previousOwner)
try
    imu.stop();
    imu.clearCallbackBuffer();
    if wasStreaming
        if ismethod(imu,'claimStreamOwner'), imu.claimStreamOwner(previousOwner); end
        imu.start(previousPeriod);
    end
catch exception
    warning('IMU:StreamRestoreFailed', 'Не удалось восстановить поток: %s', exception.message);
end
end

function report = createReport(config)
report = struct('success', false, 'uid', config.uid, 'host', config.host, ...
    'generatedAt', datetime('now', 'TimeZone', 'UTC'), ...
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
    'callbackReceivedTotal', 0, 'callbackDroppedSamples', Inf, ...
    'callbackOverflowDropped', Inf, 'callbackCoalesced', Inf, ...
    'callbackStaleSessionDropped', Inf, ...
    'callbackBufferCapacity', NaN, ...
    'callbackMaximumBuffered', 0, 'callbackMeanAgeMs', Inf, ...
    'callbackMaximumAgeMs', Inf, 'callbackPayloadsDecoded', 0, ...
    'callbackPayloadFieldsValid', false, ...
    'callbackPayloadValuesFinite', false, ...
    'callbackQuaternionNormMean', NaN, 'meanQuaternionNorm', NaN, ...
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
