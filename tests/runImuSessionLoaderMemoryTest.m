function report = runImuSessionLoaderMemoryTest()
%RUNIMUSESSIONLOADERMEMORYTEST Load 500k columnar samples with bounded memory.

sampleCount = 500000;
chunkSize = 50000;
sampleRateHz = 50;
root = tempname;
mkdir(root);
cleanup = onCleanup(@()rmdir(root, 's'));
sessionDirectory = fullfile(root, 'large-session');
mkdir(sessionDirectory);
config = getImuConfig();
sessionIdValue = "memory_test_500k";
startTimestamp = datetime('now', 'TimeZone', 'UTC');
chunkCount = ceil(sampleCount / chunkSize);

for chunkIndex = 1:chunkCount
    first = (chunkIndex - 1) * chunkSize + 1;
    last = min(sampleCount, chunkIndex * chunkSize);
    sequenceNumber = uint64((first:last).');
    count = numel(sequenceNumber);
    imuUid = repmat(config.uid, count, 1);
    busId = repmat(config.busId, count, 1);
    sensorSamples = table(sequenceNumber, imuUid, busId);

    hostTimestamp = startTimestamp + seconds((double(sequenceNumber) - 1) / sampleRateHz);
    sessionId = ones(count, 1, 'uint64');
    longitudinalAcceleration = zeros(count, 1);
    lateralAcceleration = zeros(count, 1);
    verticalAcceleration = zeros(count, 1);
    rollRate = zeros(count, 1); pitchRate = zeros(count, 1); yawRate = zeros(count, 1);
    gravity = repmat([0, 0, -9.81], count, 1);
    temperature = 20 * ones(count, 1); callbackAgeMs = ones(count, 1);
    vehicleSamples = table(sequenceNumber, hostTimestamp, sessionId, imuUid, busId, ...
        longitudinalAcceleration, lateralAcceleration, verticalAcceleration, ...
        rollRate, pitchRate, yawRate, gravity, temperature, callbackAgeMs);
    save(fullfile(sessionDirectory, sprintf('samples_%06d.mat', chunkIndex)), ...
        'sensorSamples', 'vehicleSamples', '-v7');
    clear sensorSamples vehicleSamples;
end

metadata = struct('sessionId', sessionIdValue, 'status', "complete", ...
    'sessionFormatVersion', 2, 'sampleRateHz', sampleRateHz, ...
    'callbackPeriodMs', 1000 / sampleRateHz, 'uid', config.uid, ...
    'busId', config.busId, 'synthetic', true);
summary = struct('sessionId', sessionIdValue, 'status', "complete", ...
    'sessionFormatVersion', 2, 'sampleRateHz', sampleRateHz, ...
    'callbackPeriodMs', 1000 / sampleRateHz, 'samplesWritten', sampleCount, ...
    'duplicateSamples', 0, 'missingSamples', 0, 'chunkCount', chunkCount);
writeJson(fullfile(sessionDirectory, 'metadata.json'), metadata);
writeJson(fullfile(sessionDirectory, 'summary.json'), summary);

before = memory;
timer = tic;
[session, loadReport] = loadImuSession(sessionDirectory, struct( ...
    'AllowSynthetic', true, 'MaximumSamplesInMemory', sampleCount));
elapsedSeconds = toc(timer);
after = memory;
process = System.Diagnostics.Process.GetCurrentProcess();

assert(loadReport.valid, strjoin(loadReport.errors, ' '));
assert(loadReport.samplesLoaded == sampleCount);
assert(height(session.data) == sampleCount);
assert(session.data.sequenceNumber(1) == uint64(1));
assert(session.data.sequenceNumber(end) == uint64(sampleCount));
assert(loadReport.chunkCount == chunkCount);
assert(~loadReport.rawSamplesRetained);
assert(isempty(session.rawSensorSamples) && isempty(session.rawVehicleSamples));
assert(loadReport.estimatedMemoryBytes > 0);

report = struct('success', true, 'sampleCount', sampleCount, ...
    'chunkCount', chunkCount, 'elapsedSeconds', elapsedSeconds, ...
    'estimatedSessionMemoryBytes', loadReport.estimatedMemoryBytes, ...
    'matlabMemoryDeltaBytes', max(0, after.MemUsedMATLAB - before.MemUsedMATLAB), ...
    'peakProcessWorkingSetBytes', double(process.PeakWorkingSet64), ...
    'rawSamplesRetained', loadReport.rawSamplesRetained);
end

function writeJson(filename, value)
fileId = fopen(filename, 'w');
assert(fileId >= 0);
cleanup = onCleanup(@()fclose(fileId));
fprintf(fileId, '%s', jsonencode(value, 'PrettyPrint', true));
clear cleanup;
end
