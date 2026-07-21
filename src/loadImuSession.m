function [session, report] = loadImuSession(sessionDirectory, options)
%LOADIMUSESSION Load a validated session using bounded, preallocated storage.

if nargin < 2, options = struct(); end
options = parseOptions(options);
sessionDirectory = char(string(sessionDirectory));
session = struct();
report = emptyReport(sessionDirectory);

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

[report, provenanceValid] = readProvenance(metadata, summary, options, report);
validateStatusAndIdentityMetadata();
if ~provenanceValid || ~isempty(report.errors), return; end
if ~isfield(summary, 'samplesWritten') || ...
        ~(isnumeric(summary.samplesWritten) && isscalar(summary.samplesWritten) && ...
        isfinite(summary.samplesWritten) && summary.samplesWritten >= 0 && ...
        mod(summary.samplesWritten, 1) == 0)
    report.errors(end+1, 1) = "summary.samplesWritten is missing or invalid.";
    return;
end
expectedCount = double(summary.samplesWritten);
report.estimatedMemoryBytes = estimateNumericMemory(expectedCount);
if expectedCount > options.MaximumSamplesInMemory
    report.errors(end+1, 1) = sprintf( ...
        'IMU:MaximumSamplesInMemoryExceeded: Session contains %d samples; limit is %g.', ...
        expectedCount, options.MaximumSamplesInMemory);
    return;
end

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

arrays = allocateArrays(expectedCount);
if options.KeepRawSamples
    rawSensors = cell(expectedCount, 1);
    rawVehicles = cell(expectedCount, 1);
else
    rawSensors = cell(0, 1);
    rawVehicles = cell(0, 1);
end
offset = 0;
try
    for chunkIndex = 1:numel(chunks)
        filename = fullfile(chunks(chunkIndex).folder, chunks(chunkIndex).name);
        variables = whos('-file', filename);
        names = string({variables.name});
        if ~all(ismember(["sensorSamples", "vehicleSamples"], names))
            error('IMU:InvalidSessionChunk', ...
                'Chunk lacks sensorSamples or vehicleSamples: %s.', chunks(chunkIndex).name);
        end
        contents = load(filename, 'sensorSamples', 'vehicleSamples');
        columnar = istable(contents.sensorSamples) && istable(contents.vehicleSamples);
        if columnar
            count = height(contents.vehicleSamples);
            if height(contents.sensorSamples) ~= count
                error('IMU:InvalidSessionChunk', ...
                    'Sensor and vehicle sample counts differ in %s.', chunks(chunkIndex).name);
            end
        else
            sensors = asCellColumn(contents.sensorSamples);
            vehicles = asCellColumn(contents.vehicleSamples);
            if numel(sensors) ~= numel(vehicles)
                error('IMU:InvalidSessionChunk', ...
                    'Sensor and vehicle sample counts differ in %s.', chunks(chunkIndex).name);
            end
            count = numel(vehicles);
        end
        if offset + count > expectedCount
            error('IMU:InvalidSessionChunk', ...
                'Chunk samples exceed summary.samplesWritten.');
        end
        if columnar
            block = tablesToBlock(contents.sensorSamples, ...
                contents.vehicleSamples, metadata, ~report.legacySession);
        else
            block = samplesToBlock(sensors, vehicles, metadata, ~report.legacySession);
        end
        range = offset + (1:count);
        arrays = assignBlock(arrays, block, range);
        if options.KeepRawSamples
            if columnar
                rawSensors(range) = num2cell(table2struct( ...
                    contents.sensorSamples));
                rawVehicles(range) = num2cell(table2struct( ...
                    contents.vehicleSamples));
            else
                rawSensors(range) = sensors;
                rawVehicles(range) = vehicles;
            end
        end
        offset = offset + count;
        clear contents sensors vehicles block;
    end
catch exception
    report.errors(end+1, 1) = "Invalid sample data: " + string(exception.message);
    return;
end
report.samplesLoaded = offset;
if offset ~= expectedCount
    report.errors(end+1, 1) = "summary.samplesWritten does not match loaded samples.";
    return;
end
if ~isempty(arrays.sessionId) && any(arrays.sessionId ~= arrays.sessionId(1))
    report.errors(end+1, 1) = "Sample sessionId values differ across chunks.";
    return;
end

sequence = double(arrays.sequenceNumber);
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
    analysisConfig = getDrivingAnalysisConfig();
    report.shortGapCount = sum(missing <= analysisConfig.maximumGapSamples);
    report.majorGapCount = sum(missing > analysisConfig.maximumGapSamples);
    if ~options.AllowMissingSamples
        report.errors(end+1, 1) = "Sequence gaps require AllowMissingSamples=true.";
    else
        report.warnings(end+1, 1) = sprintf( ...
            'Session contains %d missing samples in %d short and %d major gaps.', ...
            report.missingSamples, report.shortGapCount, report.majorGapCount);
    end
end
timestampDifferences = seconds(diff(arrays.hostTimestamp));
report.timestampBackwardsCount = sum(timestampDifferences < 0);
report.timestampDuplicateCount = sum(timestampDifferences == 0);
report.maximumTimestampGapSeconds = max([0; timestampDifferences(:)]);
if report.timestampBackwardsCount > 0
    report.warnings(end+1, 1) = sprintf( ...
        'Session contains %d backwards host timestamp jumps; sequence time is unchanged.', ...
        report.timestampBackwardsCount);
end
compareSummaryCounts();
if ~isempty(report.errors), return; end

timeSeconds = double(arrays.sequenceNumber - arrays.sequenceNumber(1)) / ...
    report.sampleRateHz;
data = table(arrays.sequenceNumber, arrays.hostTimestamp, arrays.sessionId, ...
    timeSeconds, arrays.longitudinalAcceleration, arrays.lateralAcceleration, ...
    arrays.verticalAcceleration, arrays.rollRate, arrays.pitchRate, arrays.yawRate, ...
    arrays.gravityX, arrays.gravityY, arrays.gravityZ, arrays.temperature, ...
    arrays.callbackAgeMs, 'VariableNames', {'sequenceNumber','hostTimestamp', ...
    'sessionId','timeSeconds','longitudinalAcceleration','lateralAcceleration', ...
    'verticalAcceleration','rollRate','pitchRate','yawRate','gravityX','gravityY', ...
    'gravityZ','temperature','callbackAgeMs'});
session = struct('data', data, 'metadata', metadata, 'summary', summary, ...
    'sampleRateHz', report.sampleRateHz, ...
    'callbackPeriodMs', report.callbackPeriodMs, ...
    'rawSensorSamples', {rawSensors}, 'rawVehicleSamples', {rawVehicles});
report.rawSamplesRetained = options.KeepRawSamples;
memoryInfo = whos('data', 'rawSensors', 'rawVehicles');
report.estimatedMemoryBytes = sum([memoryInfo.bytes]);
report.valid = isempty(report.errors);

    function validateStatusAndIdentityMetadata()
        requiredMetadata = {'sessionId','uid','busId','status'};
        for fieldIndex = 1:numel(requiredMetadata)
            if ~isfield(metadata, requiredMetadata{fieldIndex})
                report.errors(end+1, 1) = ...
                    "Missing metadata field: " + requiredMetadata{fieldIndex} + ".";
            end
        end
        validateStatuses();
        if isfield(metadata, 'synthetic') && logical(metadata.synthetic) && ...
                ~options.AllowSynthetic
            report.errors(end+1, 1) = "Synthetic session requires AllowSynthetic=true.";
        end
        if isfield(summary, 'sessionId') && isfield(metadata, 'sessionId') && ...
                string(summary.sessionId) ~= string(metadata.sessionId)
            report.errors(end+1, 1) = "metadata and summary session IDs differ.";
        end
    end

    function validateStatuses()
        if ~isfield(summary, 'status')
            report.errors(end+1, 1) = "Missing summary field: status.";
            return;
        end
        if ~isfield(metadata, 'status'), return; end
        metadataStatus = string(metadata.status);
        summaryStatus = string(summary.status);
        report.sessionStatus = metadataStatus;
        report.metadataSummaryStatusMatch = metadataStatus == summaryStatus;
        if ~report.metadataSummaryStatusMatch
            report.errors(end+1, 1) = "metadata and summary statuses differ.";
            return;
        end
        if metadataStatus == "complete"
            return;
        end
        if metadataStatus == "incomplete" && options.AllowIncomplete
            return;
        end
        report.errors(end+1, 1) = "Session status is not complete.";
    end

    function compareSummaryCounts()
        if isfield(summary, 'duplicateSamples') && ...
                double(summary.duplicateSamples) ~= report.duplicateSamples
            report.errors(end+1, 1) = "summary.duplicateSamples does not match chunks.";
        end
        if isfield(summary, 'missingSamples') && ...
                double(summary.missingSamples) ~= report.missingSamples
            report.errors(end+1, 1) = "summary.missingSamples does not match chunks.";
        end
    end
end

function report = emptyReport(sessionDirectory)
report = struct('valid', false, 'sessionDirectory', string(sessionDirectory), ...
    'chunkCount', 0, 'samplesLoaded', 0, 'duplicateSamples', 0, ...
    'missingSamples', 0, 'gaps', zeros(0, 3), ...
    'sessionFormatVersion', 0, 'legacySession', false, ...
    'sessionStatus', "", 'metadataSummaryStatusMatch', false, ...
    'sampleRateHz', NaN, 'callbackPeriodMs', NaN, ...
    'sampleRateMatchesAnalysis', NaN, 'identityVerifiedPerSample', false, ...
    'timestampBackwardsCount', 0, 'timestampDuplicateCount', 0, ...
    'maximumTimestampGapSeconds', 0, ...
    'shortGapCount', 0, 'majorGapCount', 0, 'rawSamplesRetained', false, ...
    'estimatedMemoryBytes', 0, 'errors', strings(0, 1), ...
    'warnings', strings(0, 1));
end

function [report, valid] = readProvenance(metadata, summary, options, report)
fields = {'sessionFormatVersion','sampleRateHz','callbackPeriodMs'};
metadataHas = isfield(metadata, fields);
summaryHas = isfield(summary, fields);
valid = false;
if ~any(metadataHas) && ~any(summaryHas)
    report.legacySession = true;
    report.sessionFormatVersion = 1;
    if ~options.AllowLegacySession
        report.errors(end+1, 1) = ...
            "Legacy session requires AllowLegacySession=true.";
        return;
    end
    if ~(isnumeric(options.LegacySampleRateHz) && ...
            isscalar(options.LegacySampleRateHz) && ...
            isfinite(options.LegacySampleRateHz) && options.LegacySampleRateHz > 0)
        report.errors(end+1, 1) = ...
            "LegacySampleRateHz must be explicitly provided for a legacy session.";
        return;
    end
    report.sampleRateHz = double(options.LegacySampleRateHz);
    report.callbackPeriodMs = 1000 / report.sampleRateHz;
    report.identityVerifiedPerSample = false;
    report.warnings(end+1, 1) = ...
        "Legacy session: sample rate supplied by operator; " + ...
        "sample identity is taken from metadata only.";
else
    if ~all(metadataHas) || ~all(summaryHas)
        report.errors(end+1, 1) = "Session provenance fields are incomplete.";
        return;
    end
    report.sessionFormatVersion = double(metadata.sessionFormatVersion);
    if report.sessionFormatVersion ~= 2 || ...
            double(summary.sessionFormatVersion) ~= report.sessionFormatVersion
        report.errors(end+1, 1) = "Unsupported or inconsistent session format version.";
        return;
    end
    values = [double(metadata.sampleRateHz), double(summary.sampleRateHz), ...
        double(metadata.callbackPeriodMs), double(summary.callbackPeriodMs)];
    if any(~isfinite(values)) || any(values <= 0)
        report.errors(end+1, 1) = "Session sample-rate provenance is invalid.";
        return;
    end
    if abs(values(1) - values(2)) > 1e-9 || abs(values(3) - values(4)) > 1e-9
        report.errors(end+1, 1) = "metadata and summary sample rates differ.";
        return;
    end
    if abs(values(1) - 1000 / values(3)) > 1e-9
        report.errors(end+1, 1) = "sampleRateHz and callbackPeriodMs are inconsistent.";
        return;
    end
    report.sampleRateHz = values(1);
    report.callbackPeriodMs = values(3);
    report.identityVerifiedPerSample = true;
end
if ~isnan(options.ExpectedSampleRateHz)
    report.sampleRateMatchesAnalysis = ...
        abs(report.sampleRateHz - options.ExpectedSampleRateHz) <= ...
        options.SampleRateToleranceHz;
    if ~report.sampleRateMatchesAnalysis
        report.errors(end+1, 1) = sprintf([ ...
            'IMU:SessionSampleRateMismatch: Session rate %.6g Hz differs from ' ...
            'expected rate %.6g Hz by more than %.6g Hz.'], ...
            report.sampleRateHz, options.ExpectedSampleRateHz, ...
            options.SampleRateToleranceHz);
    end
end
valid = true;
end

function options = parseOptions(custom)
defaults = struct('AllowIncomplete', false, 'AllowMissingSamples', false, ...
    'AllowSynthetic', false, 'AllowLegacySession', false, ...
    'LegacySampleRateHz', NaN, 'KeepRawSamples', false, ...
    'MaximumSamplesInMemory', Inf, 'ExpectedSampleRateHz', NaN, ...
    'SampleRateToleranceHz', NaN);
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
logicalFields = {'AllowIncomplete','AllowMissingSamples','AllowSynthetic', ...
    'AllowLegacySession','KeepRawSamples'};
for index = 1:numel(logicalFields)
    value = options.(logicalFields{index});
    if ~(islogical(value) && isscalar(value))
        error('IMU:InvalidSessionLoadOptions', '%s must be logical.', logicalFields{index});
    end
end
if ~(isnumeric(options.MaximumSamplesInMemory) && ...
        isscalar(options.MaximumSamplesInMemory) && ...
        (isinf(options.MaximumSamplesInMemory) || ...
        (isfinite(options.MaximumSamplesInMemory) && ...
        options.MaximumSamplesInMemory >= 0 && ...
        mod(options.MaximumSamplesInMemory, 1) == 0)))
    error('IMU:InvalidSessionLoadOptions', ...
        'MaximumSamplesInMemory must be a nonnegative integer or Inf.');
end
validateRateExpectation(options);
end

function validateRateExpectation(options)
expected = options.ExpectedSampleRateHz;
tolerance = options.SampleRateToleranceHz;
if ~(isnumeric(expected) && isscalar(expected) && ...
        (isnan(expected) || (isfinite(expected) && expected > 0)))
    error('IMU:InvalidSessionLoadOptions', ...
        'ExpectedSampleRateHz must be positive or NaN.');
end
if isnan(expected)
    if ~(isnumeric(tolerance) && isscalar(tolerance) && isnan(tolerance))
        error('IMU:InvalidSessionLoadOptions', ...
            'SampleRateToleranceHz must be NaN when expected rate is not set.');
    end
elseif ~(isnumeric(tolerance) && isscalar(tolerance) && ...
        isfinite(tolerance) && tolerance >= 0)
    error('IMU:InvalidSessionLoadOptions', ...
        'SampleRateToleranceHz must be nonnegative when expected rate is set.');
end
end

function [chunks, numbers, valid] = sortChunks(chunks)
numbers = zeros(numel(chunks), 1); valid = true;
for index = 1:numel(chunks)
    token = regexp(chunks(index).name, '^samples_(\d+)\.mat$', 'tokens', 'once');
    if isempty(token), valid = false; return; end
    numbers(index) = str2double(token{1});
end
[numbers, order] = sort(numbers); chunks = chunks(order);
end

function values = asCellColumn(values)
if isstruct(values), values = num2cell(values); end
if ~iscell(values), error('Samples must be stored as cells or structures.'); end
values = values(:);
end

function arrays = allocateArrays(count)
arrays = struct('sequenceNumber', zeros(count, 1, 'uint64'), ...
    'hostTimestamp', NaT(count, 1, 'TimeZone', 'UTC'), ...
    'sessionId', zeros(count, 1, 'uint64'), ...
    'longitudinalAcceleration', zeros(count, 1), ...
    'lateralAcceleration', zeros(count, 1), 'verticalAcceleration', zeros(count, 1), ...
    'rollRate', zeros(count, 1), 'pitchRate', zeros(count, 1), ...
    'yawRate', zeros(count, 1), 'gravityX', zeros(count, 1), ...
    'gravityY', zeros(count, 1), 'gravityZ', zeros(count, 1), ...
    'temperature', zeros(count, 1), 'callbackAgeMs', zeros(count, 1));
end

function block = samplesToBlock(sensors, vehicles, metadata, requireIdentity)
block = allocateArrays(numel(vehicles));
required = {'sequenceNumber','hostTimestamp','sessionId', ...
    'longitudinalAcceleration','lateralAcceleration','verticalAcceleration', ...
    'rollRate','pitchRate','yawRate','gravity','temperature','callbackAgeMs'};
for index = 1:numel(vehicles)
    sensor = requireScalarStruct(sensors{index}, 'sensor');
    vehicle = requireScalarStruct(vehicles{index}, 'vehicle');
    for fieldIndex = 1:numel(required)
        if ~isfield(vehicle, required{fieldIndex})
            error('Missing vehicle channel: %s.', required{fieldIndex});
        end
    end
    if ~isfield(sensor, 'sequenceNumber') || ...
            uint64(sensor.sequenceNumber) ~= uint64(vehicle.sequenceNumber)
        error('Sensor and vehicle sequence numbers differ.');
    end
    checkIdentity(sensor, metadata, requireIdentity);
    checkIdentity(vehicle, metadata, requireIdentity);
    block.sequenceNumber(index) = uint64(vehicle.sequenceNumber);
    block.hostTimestamp(index) = normalizeTimestamp(vehicle.hostTimestamp);
    block.sessionId(index) = uint64(vehicle.sessionId);
    block.longitudinalAcceleration(index) = finiteScalar(vehicle.longitudinalAcceleration);
    block.lateralAcceleration(index) = finiteScalar(vehicle.lateralAcceleration);
    block.verticalAcceleration(index) = finiteScalar(vehicle.verticalAcceleration);
    block.rollRate(index) = finiteScalar(vehicle.rollRate);
    block.pitchRate(index) = finiteScalar(vehicle.pitchRate);
    block.yawRate(index) = finiteScalar(vehicle.yawRate);
    gravity = finiteVector3(vehicle.gravity);
    block.gravityX(index) = gravity(1); block.gravityY(index) = gravity(2);
    block.gravityZ(index) = gravity(3);
    block.temperature(index) = finiteScalar(vehicle.temperature);
    block.callbackAgeMs(index) = finiteScalar(vehicle.callbackAgeMs);
end
if ~isempty(block.sessionId) && any(block.sessionId ~= block.sessionId(1))
    error('Sample sessionId values differ.');
end
end

function block = tablesToBlock(sensors, vehicles, metadata, requireIdentity)
sensorRequired = {'sequenceNumber'};
vehicleRequired = {'sequenceNumber','hostTimestamp','sessionId', ...
    'longitudinalAcceleration','lateralAcceleration','verticalAcceleration', ...
    'rollRate','pitchRate','yawRate','gravity','temperature','callbackAgeMs'};
if ~all(ismember(sensorRequired, sensors.Properties.VariableNames)) || ...
        ~all(ismember(vehicleRequired, vehicles.Properties.VariableNames))
    error('Columnar chunk lacks required sensor or vehicle channels.');
end
count = height(vehicles);
block = allocateArrays(count);
sensorSequence = uint64(sensors.sequenceNumber(:));
vehicleSequence = uint64(vehicles.sequenceNumber(:));
if ~isequal(sensorSequence, vehicleSequence)
    error('Sensor and vehicle sequence numbers differ.');
end
checkTableIdentity(sensors, metadata, requireIdentity);
checkTableIdentity(vehicles, metadata, requireIdentity);
block.sequenceNumber = vehicleSequence;
timestamps = vehicles.hostTimestamp(:);
if ~isdatetime(timestamps) || any(isnat(timestamps))
    error('hostTimestamp must contain finite datetime values.');
end
timestamps.TimeZone = 'UTC';
block.hostTimestamp = timestamps;
block.sessionId = uint64(vehicles.sessionId(:));
numericFields = {'longitudinalAcceleration','lateralAcceleration', ...
    'verticalAcceleration','rollRate','pitchRate','yawRate','temperature', ...
    'callbackAgeMs'};
for index = 1:numel(numericFields)
    field = numericFields{index};
    values = double(vehicles.(field)(:));
    if numel(values) ~= count || any(~isfinite(values))
        error('Vehicle channel %s must contain finite scalar samples.', field);
    end
    block.(field) = values;
end
gravity = double(vehicles.gravity);
if ~isequal(size(gravity), [count, 3]) || any(~isfinite(gravity(:)))
    error('Vehicle gravity must be an N-by-3 finite matrix.');
end
block.gravityX = gravity(:, 1); block.gravityY = gravity(:, 2);
block.gravityZ = gravity(:, 3);
if ~isempty(block.sessionId) && any(block.sessionId ~= block.sessionId(1))
    error('Sample sessionId values differ.');
end
end

function checkTableIdentity(samples, metadata, required)
variables = samples.Properties.VariableNames;
hasIdentity = all(ismember({'imuUid','busId'}, variables));
if required && ~hasIdentity
    error('Sample identity fields imuUid and busId are required for format v2.');
end
if hasIdentity && (any(string(samples.imuUid) ~= string(metadata.uid)) || ...
        any(string(samples.busId) ~= string(metadata.busId)))
    error('Sample identity does not match metadata.');
end
end

function arrays = assignBlock(arrays, block, range)
fields = fieldnames(arrays);
for index = 1:numel(fields)
    arrays.(fields{index})(range) = block.(fields{index});
end
end

function value = requireScalarStruct(value, label)
if ~isstruct(value) || ~isscalar(value), error('%s sample must be scalar.', label); end
end

function checkIdentity(sample, metadata, required)
hasIdentity = isfield(sample, 'imuUid') && isfield(sample, 'busId');
if required && ~hasIdentity
    error('Sample identity fields imuUid and busId are required for format v2.');
end
if hasIdentity && (string(sample.imuUid) ~= string(metadata.uid) || ...
        string(sample.busId) ~= string(metadata.busId))
    error('Sample identity does not match metadata.');
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

function bytes = estimateNumericMemory(count)
bytes = double(count) * (13 * 8 + 2 * 8 + 8);
end
