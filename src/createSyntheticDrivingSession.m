function sessionDirectory = createSyntheticDrivingSession(outputDirectory, scenario)
%CREATESYNTHETICDRIVINGSESSION Create test-only chunked driving data.

if nargin < 2, scenario = "stationary"; end
scenario = string(scenario);
supported = ["stationary","braking","acceleration","left_turn", ...
    "right_turn","vertical_shock","mixed_events","sequence_gap","outlier"];
if ~isscalar(scenario) || ~any(scenario == supported)
    error('IMU:UnknownSyntheticScenario', 'Unsupported scenario: %s.', scenario);
end
outputDirectory = char(string(outputDirectory));
if ~isfolder(outputDirectory), mkdir(outputDirectory); end
stamp = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss_SSS'));
uuid = char(javaMethod('randomUUID', 'java.util.UUID'));
sessionDirectory = string(fullfile(outputDirectory, ...
    char(scenario) + "_" + stamp + "_" + uuid(1:8)));
mkdir(char(sessionDirectory));

config = getDrivingAnalysisConfig();
projectConfig = getImuConfig();
count = 500;
longitudinal = zeros(count, 1); lateral = zeros(count, 1);
vertical = zeros(count, 1); yaw = zeros(count, 1);
switch scenario
    case "braking"
        longitudinal(151:195) = -2.2;
    case "acceleration"
        longitudinal(151:195) = 1.8;
    case "left_turn"
        lateral(151:195) = 2.1; yaw(151:195) = 12;
    case "right_turn"
        lateral(151:195) = -2.1; yaw(151:195) = -12;
    case "vertical_shock"
        vertical(249:251) = 3.5;
    case "mixed_events"
        longitudinal(51:90) = -2.2;
        longitudinal(121:165) = 1.8;
        lateral(201:245) = 2.1; yaw(201:245) = 12;
        lateral(281:325) = -2.1; yaw(281:325) = -12;
        vertical(389:391) = 3.5;
    case "outlier"
        longitudinal(250) = 20;
end
sequence = uint64((1:count).');
if scenario == "sequence_gap", sequence(251:end) = sequence(251:end) + 4; end
firstTimestamp = datetime('now', 'TimeZone', 'UTC');
allSensorSamples = cell(count, 1); allVehicleSamples = cell(count, 1);
for index = 1:count
    timestamp = firstTimestamp + seconds((index - 1) / config.targetSampleRateHz);
    common = struct('sequenceNumber', sequence(index), ...
        'hostTimestamp', timestamp, 'timestamp', timestamp, ...
        'sessionId', uint64(1), 'imuUid', projectConfig.uid, ...
        'busId', projectConfig.busId, 'callbackAgeMs', 1, ...
        'temperature', 20, 'gravity', [0;0;-9.81], ...
        'linearAcceleration', [longitudinal(index); lateral(index); vertical(index)], ...
        'angularVelocity', [0;0;yaw(index)]);
    allSensorSamples{index} = common;
    vehicle = common;
    vehicle.longitudinalAcceleration = longitudinal(index);
    vehicle.lateralAcceleration = lateral(index);
    vehicle.verticalAcceleration = vertical(index);
    vehicle.rollRate = 0; vehicle.pitchRate = 0; vehicle.yawRate = yaw(index);
    allVehicleSamples{index} = vehicle;
end

chunkSize = 175;
chunkCount = ceil(count / chunkSize);
for chunkIndex = 1:chunkCount
    first = (chunkIndex - 1) * chunkSize + 1;
    last = min(count, chunkIndex * chunkSize);
    sensorSamples = allSensorSamples(first:last);
    vehicleSamples = allVehicleSamples(first:last);
    save(fullfile(char(sessionDirectory), sprintf('samples_%06d.mat', chunkIndex)), ...
        'sensorSamples', 'vehicleSamples', '-v7');
end

missing = sum(max(0, diff(double(sequence)) - 1));
sessionId = string(char(scenario) + "_synthetic");
metadata = struct('sessionId', sessionId, 'status', "complete", ...
    'uid', projectConfig.uid, 'busId', projectConfig.busId, ...
    'calibrationVersion', 2, 'firmwareVersion', [2 0 15], ...
    'synthetic', true, 'createdAt', string(firstTimestamp));
summary = struct('sessionId', sessionId, 'status', "complete", ...
    'samplesWritten', count, 'duplicateSamples', 0, ...
    'missingSamples', missing, 'gaps', zeros(0, 3), ...
    'received', count, 'overflowDropped', 0, 'coalesced', 0, ...
    'staleSessionDropped', 0, 'chunkCount', chunkCount);
writeJson(fullfile(char(sessionDirectory), 'metadata.json'), metadata);
writeJson(fullfile(char(sessionDirectory), 'summary.json'), summary);
end

function writeJson(filename, value)
fileId = fopen(filename, 'w');
if fileId < 0, error('IMU:SyntheticSessionWriteFailed', 'Cannot write %s.', filename); end
cleanup = onCleanup(@()fclose(fileId));
fprintf(fileId, '%s', jsonencode(value, 'PrettyPrint', true));
clear cleanup;
end
