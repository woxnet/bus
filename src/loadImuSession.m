function [session, report] = loadImuSession(sessionDirectory, options)
%LOADIMUSESSION Load and validate a chunked ImuSessionRecorder directory.

if nargin < 2, options = struct(); end
options = parseOptions(options);
sessionDirectory = char(string(sessionDirectory));
session = struct();
report = struct('valid', false, 'sessionDirectory', string(sessionDirectory), ...
    'chunkCount', 0, 'samplesLoaded', 0, 'duplicateSamples', 0, ...
    'missingSamples', 0, 'gaps', zeros(0, 3), ...
    'errors', strings(0, 1), 'warnings', strings(0, 1));

if ~isfolder(sessionDirectory)
    report.errors(end+1, 1) = "Session directory does not exist.";
    return;
end
metadataFile = fullfile(sessionDirectory, 'metadata.json');
summaryFile = fullfile(sessionDirectory, 'summary.json');
if ~isfile(metadataFile), report.errors(end+1, 1) = "metadata.json is missing."; end
if ~isfile(summaryFile), report.errors(end+1, 1) = "summary.json is missing."; end
if ~isempty(report.errors), return; end
try
    metadata = jsondecode(fileread(metadataFile));
    summary = jsondecode(fileread(summaryFile));
catch exception
    report.errors(end+1, 1) = "Invalid session JSON: " + string(exception.message);
    return;
end
if ~isfield(metadata, 'status') || ...
        (string(metadata.status) ~= "complete" && ~options.AllowIncomplete)
    report.errors(end+1, 1) = "Session status is not complete.";
end
if isfield(metadata, 'synthetic') && logical(metadata.synthetic) && ...
        ~options.AllowSynthetic
    report.errors(end+1, 1) = ...
        "Synthetic session requires AllowSynthetic=true.";
end
requiredMetadata = {'sessionId','uid','busId','status'};
for index = 1:numel(requiredMetadata)
    if ~isfield(metadata, requiredMetadata{index})
        report.errors(end+1, 1) = ...
            "Missing metadata field: " + requiredMetadata{index} + ".";
    end
end
if ~isfield(summary, 'samplesWritten')
    report.errors(end+1, 1) = "summary.samplesWritten is missing.";
end
if isfield(summary, 'sessionId') && isfield(metadata, 'sessionId') && ...
        string(summary.sessionId) ~= string(metadata.sessionId)
    report.errors(end+1, 1) = "metadata and summary session IDs differ.";
end
if ~isempty(report.errors), return; end

chunks = dir(fullfile(sessionDirectory, 'samples_*.mat'));
if isempty(chunks)
    report.errors(end+1, 1) = "No sample chunks were found.";
    return;
end
[chunks, chunkNumbers, validNames] = sortChunks(chunks);
report.chunkCount = numel(chunks);
if ~validNames || ~isequal(chunkNumbers(:).', 1:numel(chunks))
    report.errors(end+1, 1) = "Sample chunk numbering is incomplete.";
    return;
end
if isfield(summary, 'chunkCount') && double(summary.chunkCount) ~= numel(chunks)
    report.errors(end+1, 1) = "summary.chunkCount does not match chunk files.";
    return;
end

sensorSamples = cell(0, 1);
vehicleSamples = cell(0, 1);
for chunkIndex = 1:numel(chunks)
    filename = fullfile(chunks(chunkIndex).folder, chunks(chunkIndex).name);
    variables = whos('-file', filename);
    names = string({variables.name});
    if ~all(ismember(["sensorSamples", "vehicleSamples"], names))
        report.errors(end+1, 1) = ...
            "Chunk lacks sensorSamples or vehicleSamples: " + chunks(chunkIndex).name;
        return;
    end
    contents = load(filename, 'sensorSamples', 'vehicleSamples');
    sensors = asCellColumn(contents.sensorSamples);
    vehicles = asCellColumn(contents.vehicleSamples);
    if numel(sensors) ~= numel(vehicles)
        report.errors(end+1, 1) = ...
            "Sensor and vehicle sample counts differ in " + chunks(chunkIndex).name + ".";
        return;
    end
    sensorSamples = [sensorSamples; sensors]; %#ok<AGROW>
    vehicleSamples = [vehicleSamples; vehicles]; %#ok<AGROW>
end

report.samplesLoaded = numel(vehicleSamples);
if double(summary.samplesWritten) ~= report.samplesLoaded
    report.errors(end+1, 1) = "summary.samplesWritten does not match loaded samples.";
    return;
end
try
    data = samplesToTable(sensorSamples, vehicleSamples, metadata);
catch exception
    report.errors(end+1, 1) = "Invalid sample data: " + string(exception.message);
    return;
end
sequence = double(data.sequenceNumber);
differences = diff(sequence);
report.duplicateSamples = sum(differences == 0);
if any(differences <= 0)
    report.errors(end+1, 1) = "Sequence numbers are not strictly increasing.";
end
gapIndices = find(differences > 1);
if ~isempty(gapIndices)
    missing = differences(gapIndices) - 1;
    report.gaps = [sequence(gapIndices), sequence(gapIndices + 1), missing];
    report.missingSamples = sum(missing);
    if ~options.AllowMissingSamples
        report.errors(end+1, 1) = "Sequence gaps require AllowMissingSamples=true.";
    else
        report.warnings(end+1, 1) = sprintf( ...
            'Session contains %d missing samples.', report.missingSamples);
    end
end
if isfield(summary, 'duplicateSamples') && ...
        double(summary.duplicateSamples) ~= report.duplicateSamples
    report.errors(end+1, 1) = "summary.duplicateSamples does not match chunks.";
end
if isfield(summary, 'missingSamples') && ...
        double(summary.missingSamples) ~= report.missingSamples
    report.errors(end+1, 1) = "summary.missingSamples does not match chunks.";
end
if ~isempty(report.errors), return; end

session = struct('data', data, 'metadata', metadata, 'summary', summary, ...
    'rawSensorSamples', {sensorSamples}, 'rawVehicleSamples', {vehicleSamples});
report.valid = true;
end

function options = parseOptions(custom)
defaults = struct('AllowIncomplete', false, 'AllowMissingSamples', false, ...
    'AllowSynthetic', false);
if ~isstruct(custom) || ~isscalar(custom)
    error('IMU:InvalidSessionLoadOptions', 'options must be a scalar structure.');
end
unknown = setdiff(fieldnames(custom), fieldnames(defaults));
if ~isempty(unknown)
    error('IMU:InvalidSessionLoadOptions', 'Unknown option: %s.', unknown{1});
end
options = defaults;
fields = fieldnames(custom);
for index = 1:numel(fields), options.(fields{index}) = custom.(fields{index}); end
for index = 1:numel(fields)
    if ~(islogical(options.(fields{index})) && isscalar(options.(fields{index})))
        error('IMU:InvalidSessionLoadOptions', '%s must be logical.', fields{index});
    end
end
end

function [chunks, numbers, valid] = sortChunks(chunks)
numbers = zeros(numel(chunks), 1);
valid = true;
for index = 1:numel(chunks)
    token = regexp(chunks(index).name, '^samples_(\d+)\.mat$', 'tokens', 'once');
    if isempty(token), valid = false; return; end
    numbers(index) = str2double(token{1});
end
[numbers, order] = sort(numbers);
chunks = chunks(order);
end

function values = asCellColumn(values)
if isstruct(values), values = num2cell(values); end
if ~iscell(values), error('Samples must be stored as cells or structures.'); end
values = values(:);
end

function data = samplesToTable(sensors, vehicles, metadata)
count = numel(vehicles);
sequenceNumber = zeros(count, 1, 'uint64');
hostTimestamp = NaT(count, 1, 'TimeZone', 'UTC');
sessionId = zeros(count, 1, 'uint64');
longitudinalAcceleration = zeros(count, 1);
lateralAcceleration = zeros(count, 1);
verticalAcceleration = zeros(count, 1);
rollRate = zeros(count, 1); pitchRate = zeros(count, 1); yawRate = zeros(count, 1);
gravityX = zeros(count, 1); gravityY = zeros(count, 1); gravityZ = zeros(count, 1);
temperature = zeros(count, 1); callbackAgeMs = zeros(count, 1);
for index = 1:count
    sensor = requireScalarStruct(sensors{index}, 'sensor');
    vehicle = requireScalarStruct(vehicles{index}, 'vehicle');
    required = {'sequenceNumber','hostTimestamp','sessionId', ...
        'longitudinalAcceleration','lateralAcceleration','verticalAcceleration', ...
        'rollRate','pitchRate','yawRate','gravity','temperature','callbackAgeMs'};
    for fieldIndex = 1:numel(required)
        if ~isfield(vehicle, required{fieldIndex})
            error('Missing vehicle channel: %s.', required{fieldIndex});
        end
    end
    if ~isfield(sensor, 'sequenceNumber') || ...
            uint64(sensor.sequenceNumber) ~= uint64(vehicle.sequenceNumber)
        error('Sensor and vehicle sequence numbers differ.');
    end
    checkIdentity(sensor, metadata);
    checkIdentity(vehicle, metadata);
    sequenceNumber(index) = uint64(vehicle.sequenceNumber);
    hostTimestamp(index) = normalizeTimestamp(vehicle.hostTimestamp);
    sessionId(index) = uint64(vehicle.sessionId);
    longitudinalAcceleration(index) = finiteScalar(vehicle.longitudinalAcceleration);
    lateralAcceleration(index) = finiteScalar(vehicle.lateralAcceleration);
    verticalAcceleration(index) = finiteScalar(vehicle.verticalAcceleration);
    rollRate(index) = finiteScalar(vehicle.rollRate);
    pitchRate(index) = finiteScalar(vehicle.pitchRate);
    yawRate(index) = finiteScalar(vehicle.yawRate);
    gravity = finiteVector3(vehicle.gravity);
    gravityX(index) = gravity(1); gravityY(index) = gravity(2); gravityZ(index) = gravity(3);
    temperature(index) = finiteScalar(vehicle.temperature);
    callbackAgeMs(index) = finiteScalar(vehicle.callbackAgeMs);
end
if any(sessionId ~= sessionId(1)), error('Sample sessionId values differ.'); end
analysisConfig = getDrivingAnalysisConfig();
timeSeconds = double(sequenceNumber - sequenceNumber(1)) / ...
    analysisConfig.targetSampleRateHz;
data = table(sequenceNumber, hostTimestamp, sessionId, timeSeconds, ...
    longitudinalAcceleration, lateralAcceleration, verticalAcceleration, ...
    rollRate, pitchRate, yawRate, gravityX, gravityY, gravityZ, ...
    temperature, callbackAgeMs);
end

function value = requireScalarStruct(value, label)
if ~isstruct(value) || ~isscalar(value), error('%s sample must be scalar.', label); end
end

function checkIdentity(sample, metadata)
if ~isfield(sample, 'imuUid') || ~isfield(sample, 'busId')
    error('Sample identity fields imuUid and busId are required.');
end
if string(sample.imuUid) ~= string(metadata.uid)
    error('Sample IMU UID does not match metadata.');
end
if string(sample.busId) ~= string(metadata.busId)
    error('Sample bus ID does not match metadata.');
end
end

function value = normalizeTimestamp(value)
if ~(isdatetime(value) && isscalar(value) && ~isnat(value))
    error('hostTimestamp must be a finite datetime scalar.');
end
value.TimeZone = 'UTC';
end

function value = finiteScalar(value)
if ~(isnumeric(value) && isscalar(value) && isfinite(value))
    error('Expected a finite numeric scalar.');
end
value = double(value);
end

function value = finiteVector3(value)
if ~(isnumeric(value) && numel(value) == 3 && all(isfinite(value(:))))
    error('Expected a finite three-element vector.');
end
value = double(value(:));
end
