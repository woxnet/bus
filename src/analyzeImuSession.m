function result = analyzeImuSession(sessionDirectory, options)
%ANALYZEIMUSESSION Run the reproducible offline driving-event pipeline.
% IMU-only data detects dynamic candidates; without CAN/GNSS it cannot
% determine constant-speed motion, trip boundaries, distance, or bus speed.

if nargin < 2, options = struct(); end
options = parseOptions(options);
config = validateDrivingAnalysisConfig(options.Config);
loadOptions = struct('AllowIncomplete', options.AllowIncomplete, ...
    'AllowMissingSamples', options.AllowMissingSamples, ...
    'AllowSynthetic', options.AllowSynthetic);
[session, loadReport] = loadImuSession(sessionDirectory, loadOptions);
result = struct('success', false, 'sessionDirectory', string(sessionDirectory), ...
    'config', config, 'loadReport', loadReport, 'processed', struct(), ...
    'events', [], 'eventCounts', emptyEventCounts(), ...
    'totalDurationSeconds', 0, 'errors', loadReport.errors, ...
    'warnings', loadReport.warnings, 'analysisDirectory', "", ...
    'resultMatFile', "", 'eventsJsonFile', "", 'summaryJsonFile', "");
if ~loadReport.valid, return; end
try
    processed = preprocessDrivingSession(session, config);
    events = detectDrivingEvents(processed, config);
    counts = countEvents(events);
    result.processed = processed;
    result.events = events;
    result.eventCounts = counts;
    if numel(processed.timeSeconds) > 1
        result.totalDurationSeconds = processed.timeSeconds(end) - ...
            processed.timeSeconds(1) + 1 / config.targetSampleRateHz;
    elseif isscalar(processed.timeSeconds)
        result.totalDurationSeconds = 1 / config.targetSampleRateHz;
    end
    result.success = true;
    if options.SaveAnalysis, result = saveAnalysis(result, session); end
catch exception
    result.errors(end+1, 1) = string(exception.message);
end
end

function options = parseOptions(custom)
defaults = struct('AllowIncomplete', false, 'AllowMissingSamples', false, ...
    'AllowSynthetic', false, 'SaveAnalysis', true, ...
    'Config', getDrivingAnalysisConfig());
if ~isstruct(custom) || ~isscalar(custom)
    error('IMU:InvalidAnalysisOptions', 'options must be a scalar structure.');
end
unknown = setdiff(fieldnames(custom), fieldnames(defaults));
if ~isempty(unknown), error('IMU:InvalidAnalysisOptions', 'Unknown option: %s.', unknown{1}); end
options = defaults;
fields = fieldnames(custom);
for index = 1:numel(fields), options.(fields{index}) = custom.(fields{index}); end
logicalFields = {'AllowIncomplete','AllowMissingSamples','AllowSynthetic','SaveAnalysis'};
for index = 1:numel(logicalFields)
    value = options.(logicalFields{index});
    if ~(islogical(value) && isscalar(value))
        error('IMU:InvalidAnalysisOptions', '%s must be logical.', logicalFields{index});
    end
end
end

function counts = emptyEventCounts()
counts = struct('BRAKING_CANDIDATE', 0, 'ACCELERATION_CANDIDATE', 0, ...
    'TURN_LEFT_CANDIDATE', 0, 'TURN_RIGHT_CANDIDATE', 0, ...
    'VERTICAL_SHOCK_CANDIDATE', 0);
end

function counts = countEvents(events)
counts = emptyEventCounts();
for index = 1:numel(events)
    type = char(events(index).type);
    counts.(type) = counts.(type) + 1;
end
end

function result = saveAnalysis(result, session)
analysisDirectory = fullfile(char(result.sessionDirectory), 'analysis');
if ~isfolder(analysisDirectory), mkdir(analysisDirectory); end
result.analysisDirectory = string(analysisDirectory);
result.resultMatFile = string(fullfile(analysisDirectory, 'result.mat'));
result.eventsJsonFile = string(fullfile(analysisDirectory, 'events.json'));
result.summaryJsonFile = string(fullfile(analysisDirectory, 'summary.json'));
save(char(result.resultMatFile), 'result', '-v7');
writeJson(char(result.eventsJsonFile), eventsForJson(result.events));
summary = struct('sessionId', string(session.metadata.sessionId), ...
    'uid', string(session.metadata.uid), 'busId', string(session.metadata.busId), ...
    'analysisVersion', string(result.config.analysisVersion), ...
    'sampleCount', result.loadReport.samplesLoaded, ...
    'sessionDurationSeconds', result.totalDurationSeconds, ...
    'missingSamples', result.loadReport.missingSamples, ...
    'eventCounts', result.eventCounts, 'thresholds', result.config);
writeJson(char(result.summaryJsonFile), summary);
end

function output = eventsForJson(events)
output = events;
for index = 1:numel(output)
    output(index).startTimestamp = string(output(index).startTimestamp, ...
        'yyyy-MM-dd''T''HH:mm:ss.SSSXXX');
    output(index).endTimestamp = string(output(index).endTimestamp, ...
        'yyyy-MM-dd''T''HH:mm:ss.SSSXXX');
end
end

function writeJson(filename, value)
temporary = [filename, '.tmp'];
fileId = fopen(temporary, 'w');
if fileId < 0, error('IMU:AnalysisWriteFailed', 'Cannot write %s.', filename); end
cleanup = onCleanup(@()fclose(fileId));
fprintf(fileId, '%s', jsonencode(value, 'PrettyPrint', true));
clear cleanup;
[success, message] = movefile(temporary, filename, 'f');
if ~success, error('IMU:AnalysisWriteFailed', '%s', message); end
end
