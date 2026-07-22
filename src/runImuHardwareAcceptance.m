function report = runImuHardwareAcceptance(imu, durationSeconds, outputDirectory)
%RUNIMUHARDWAREACCEPTANCE Exercise FIFO callback acquisition and save a report.

config = getImuConfig();
if nargin < 2 || isempty(durationSeconds), durationSeconds = 60; end
if nargin < 3 || isempty(outputDirectory), outputDirectory = 'artifacts'; end
validateattributes(durationSeconds, {'numeric'}, {'scalar','positive'});
outputDirectory = resolveProjectPath(outputDirectory);
if ~isfolder(outputDirectory), mkdir(outputDirectory); end
identity=imu.getIdentity(); sensorFusionMode=imu.getSensorFusionMode();
[gitStatus,commit]=system('git rev-parse HEAD');
if gitStatus~=0, commit="unknown"; else, commit=strtrim(string(commit)); end

imu.start(config.callbackPeriodMs);
streamOwner = string(imu.StreamOwner);
cleanup = onCleanup(@()cleanupAcceptanceLifecycle(imu, streamOwner));
sessionStats = imu.getCallbackStats();
sequences = zeros(0, 1, 'uint64'); nanos = zeros(0, 1);
ages = zeros(0, 1); quaternionNorms = zeros(0, 1);
gravityMagnitudes = zeros(0, 1); temperatures = zeros(0, 1);
timer = tic;
while toc(timer) < durationSeconds
    consume(imu.drainCallbackSamples(256));
    pause(0.001);
end
imu.quiesce();
[tailSamplesDrained, stopDrainDurationSeconds, stopDrainTimedOut] = drainTail();
stats = imu.getCallbackStats();
finalBufferedSamples = double(stats.buffered);
imu.clearCallbackBuffer();
imu.releaseStreamOwner(streamOwner);
streamOwnerReleased = string(imu.StreamOwner) == "none";
streamStopped = ~imu.IsStreaming;

intervals = diff(nanos) / 1e9;
frequencies = 1 ./ intervals(intervals > 0);
missing = sum(max(0, diff(double(sequences)) - 1));
report = struct('success', false, 'generatedAt', string(datetime( ...
    'now', 'TimeZone', 'UTC'), 'yyyy-MM-dd''T''HH:mm:ss.SSSXXX'), ...
    'durationSeconds', toc(timer), 'commit',commit, ...
    'uid', string(identity.uid), 'busId',config.busId, ...
    'firmwareVersion',double(identity.firmwareVersion(:)).', ...
    'sensorFusionMode',double(sensorFusionMode), ...
    'sessionId', stats.sessionId, 'samplesRead', numel(sequences), ...
    'received', double(stats.received), 'missing', missing, ...
    'tailSamplesDrained', double(tailSamplesDrained), ...
    'stopDrainDurationSeconds', double(stopDrainDurationSeconds), ...
    'stopDrainTimedOut', logical(stopDrainTimedOut), ...
    'finalBufferedSamples', finalBufferedSamples, ...
    'samplesReadMatchesReceived', numel(sequences) == double(stats.received), ...
    'streamOwnerReleased', streamOwnerReleased, ...
    'streamStopped', streamStopped, 'finalCallbackStats', stats, ...
    'overflowDropped', double(stats.overflowDropped), ...
    'coalesced', double(stats.coalesced), ...
    'staleSessionDropped', double(stats.staleSessionDropped), ...
    'meanFrequencyHz', safeStatistic(frequencies, @mean), ...
    'minimumFrequencyHz', safeStatistic(frequencies, @min), ...
    'maximumFrequencyHz', safeStatistic(frequencies, @max), ...
    'sampleAgeP50Ms', percentile(ages, 50), ...
    'sampleAgeP95Ms', percentile(ages, 95), ...
    'sampleAgeP99Ms', percentile(ages, 99), ...
    'sampleAgeMaximumMs', safeStatistic(ages, @max), ...
    'quaternionNormMean', safeStatistic(quaternionNorms, @mean), ...
    'gravityMagnitudeMean', safeStatistic(gravityMagnitudes, @mean), ...
    'temperatureMinimum', safeStatistic(temperatures, @min), ...
    'temperatureMaximum', safeStatistic(temperatures, @max), ...
    'matFile', "", 'jsonFile', "");
report.success = report.samplesRead >= floor(durationSeconds * ...
    config.minimumDiagnosticFrequencyHz) && report.missing == 0 && ...
    report.overflowDropped == 0 && report.staleSessionDropped == 0 && ...
    report.meanFrequencyHz >= config.minimumDiagnosticFrequencyHz && ...
    report.meanFrequencyHz <= config.maximumDiagnosticFrequencyHz && ...
    report.sampleAgeMaximumMs <= config.maximumCallbackSampleAgeMs && ...
    abs(report.quaternionNormMean - 1) <= 0.1 && ...
    abs(report.gravityMagnitudeMean - config.gravityReference) <= ...
        config.maximumGravityError && ~report.stopDrainTimedOut && ...
    report.finalBufferedSamples == 0 && report.samplesReadMatchesReceived && ...
    report.samplesRead == report.received && report.streamOwnerReleased && ...
    report.streamStopped;

stamp = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
base = fullfile(outputDirectory, ['hardware_acceptance_', stamp]);
report.matFile = string(base) + ".mat";
report.jsonFile = string(base) + ".json";
save(char(report.matFile), 'report');
writeJson(char(report.jsonFile), report);
clear cleanup;

    function [count, duration, timedOut] = drainTail()
        stopDrainTimeoutSeconds = 0.5;
        stopDrainEmptyPasses = 3;
        stopDrainPollIntervalSeconds = 0.005;
        count = 0;
        emptyPasses = 0;
        drainTimer = tic;
        while emptyPasses < stopDrainEmptyPasses
            if toc(drainTimer) >= stopDrainTimeoutSeconds, break; end
            samples = imu.drainCallbackSamples(256);
            if isempty(samples)
                emptyPasses = emptyPasses + 1;
                if emptyPasses < stopDrainEmptyPasses
                    pause(stopDrainPollIntervalSeconds);
                end
            else
                emptyPasses = 0;
                consume(samples);
                count = count + numel(samples);
            end
        end
        duration = toc(drainTimer);
        timedOut = emptyPasses < stopDrainEmptyPasses;
    end

    function consume(samples)
        for sampleIndex = 1:numel(samples)
            sample = samples{sampleIndex};
            if uint64(sample.sessionId) ~= uint64(sessionStats.sessionId), continue; end
            sequences(end+1, 1) = uint64(sample.sequenceNumber); %#ok<AGROW>
            nanos(end+1, 1) = double(sample.callbackTimestampNanos); %#ok<AGROW>
            ages(end+1, 1) = double(sample.callbackAgeMs); %#ok<AGROW>
            quaternionNorms(end+1, 1) = norm(sample.quaternion); %#ok<AGROW>
            gravityMagnitudes(end+1, 1) = norm(sample.gravity); %#ok<AGROW>
            temperatures(end+1, 1) = double(sample.temperature); %#ok<AGROW>
        end
    end
end

function cleanupAcceptanceLifecycle(imu, streamOwner)
if ~imu.IsStreaming && string(imu.StreamOwner) == "none", return; end
try
    imu.quiesce();
catch exception
    warning('IMU:AcceptanceCleanupFailed', ...
        'Failed to quiesce IMU during acceptance cleanup: %s', exception.message);
end
try
    imu.clearCallbackBuffer();
catch exception
    warning('IMU:AcceptanceCleanupFailed', ...
        'Failed to clear callback FIFO during acceptance cleanup: %s', exception.message);
end
if string(imu.StreamOwner) ~= "none"
    try
        imu.releaseStreamOwner(streamOwner);
    catch exception
        warning('IMU:AcceptanceCleanupFailed', ...
            'Failed to release stream owner during acceptance cleanup: %s', ...
            exception.message);
    end
end
end

function value = safeStatistic(values, operation)
if isempty(values), value = NaN; else, value = operation(values); end
end

function value = percentile(values, percent)
values = sort(values(isfinite(values)));
if isempty(values), value = NaN; return; end
position = 1 + (numel(values) - 1) * percent / 100;
lower = floor(position); upper = ceil(position);
value = values(lower) + (position - lower) * (values(upper) - values(lower));
end

function writeJson(filename, value)
fileId = fopen(filename, 'w');
if fileId < 0, error('IMU:AcceptanceSaveFailed', 'Cannot write %s.', filename); end
cleanup = onCleanup(@()fclose(fileId));
fprintf(fileId, '%s', jsonencode(value, 'PrettyPrint', true));
clear cleanup;
end
