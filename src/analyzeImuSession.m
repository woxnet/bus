function result = analyzeImuSession(sessionDirectory, options)
%ANALYZEIMUSESSION Run the transactional offline driving-event pipeline.
% IMU-only data detects dynamic candidates; without CAN/GNSS it cannot
% determine constant-speed motion, trip boundaries, distance, or bus speed.

if nargin < 2, options = struct(); end
options = parseOptions(options);
config = validateDrivingAnalysisConfig(options.Config);
loadOptions = struct('AllowIncomplete', options.AllowIncomplete, ...
    'AllowMissingSamples', options.AllowMissingSamples, ...
    'AllowSynthetic', options.AllowSynthetic, ...
    'AllowLegacySession', options.AllowLegacySession, ...
    'LegacySampleRateHz', options.LegacySampleRateHz, ...
    'KeepRawSamples', options.KeepRawSamples, ...
    'MaximumSamplesInMemory', options.MaximumSamplesInMemory, ...
    'ExpectedSampleRateHz', config.targetSampleRateHz, ...
    'SampleRateToleranceHz', config.sampleRateToleranceHz);
[session, loadReport] = loadImuSession(sessionDirectory, loadOptions);
result = initialResult(sessionDirectory, config, loadReport);
if ~loadReport.valid
    result.success = isempty(result.errors);
    return;
end
try
    processed = preprocessDrivingSession(session, config);
    events = detectDrivingEvents(processed, config);
    result.processed = processed;
    result.events = events;
    result.eventCounts = countEvents(events);
    result = addDurations(result, processed);
    if options.SaveAnalysis
        result = saveAnalysisTransaction(result, session, options);
    else
        result.success = true;
    end
catch exception
    result.success = false;
    result.errors(end+1, 1) = string(exception.identifier) + ": " + ...
        string(exception.message);
end
result.success = result.success && isempty(result.errors);
end

function result = initialResult(sessionDirectory, config, loadReport)
result = struct('success', false, 'sessionDirectory', string(sessionDirectory), ...
    'config', config, 'loadReport', loadReport, 'processed', struct(), ...
    'events', [], 'eventCounts', emptyEventCounts(), ...
    'elapsedDurationSeconds', 0, 'observedSampleDurationSeconds', 0, ...
    'totalDurationSeconds', 0, 'errors', loadReport.errors, ...
    'warnings', loadReport.warnings, 'analysisDirectory', "", ...
    'resultMatFile', "", 'eventsJsonFile', "", 'summaryJsonFile', "", ...
    'diagnosticPlotPngFile', "", 'diagnosticPlotFigFile', "");
end

function result = addDurations(result, processed)
if isempty(processed.sequenceNumber), return; end
sampleRateHz = processed.sampleRateHz;
result.elapsedDurationSeconds = ...
    (double(processed.sequenceNumber(end) - processed.sequenceNumber(1)) + 1) / ...
    sampleRateHz;
segments = unique(processed.segmentId(processed.segmentId > 0));
observedSamples = 0;
for index = 1:numel(segments)
    observedSamples = observedSamples + sum(processed.segmentId == segments(index));
end
result.observedSampleDurationSeconds = observedSamples / sampleRateHz;
% Backward-compatible alias: total duration means elapsed sequence duration.
result.totalDurationSeconds = result.elapsedDurationSeconds;
end

function options = parseOptions(custom)
defaults = struct('AllowIncomplete', false, 'AllowMissingSamples', false, ...
    'AllowSynthetic', false, 'AllowLegacySession', false, ...
    'LegacySampleRateHz', NaN, 'KeepRawSamples', false, ...
    'MaximumSamplesInMemory', Inf, 'SaveAnalysis', true, 'SavePlots', false, ...
    'OutputDirectory', "", 'Config', getDrivingAnalysisConfig(), ...
    'FileSystem', defaultFileSystem());
if ~isstruct(custom) || ~isscalar(custom)
    error('IMU:InvalidAnalysisOptions', 'options must be a scalar structure.');
end
unknown = setdiff(fieldnames(custom), fieldnames(defaults));
if ~isempty(unknown), error('IMU:InvalidAnalysisOptions', 'Unknown option: %s.', unknown{1}); end
options = defaults;
fields = fieldnames(custom);
for index = 1:numel(fields)
    field = fields{index};
    if strcmp(field, 'FileSystem')
        options.FileSystem = mergeFileSystem(defaults.FileSystem, custom.FileSystem);
    else
        options.(field) = custom.(field);
    end
end
logicalFields = {'AllowIncomplete','AllowMissingSamples','AllowSynthetic', ...
    'AllowLegacySession','KeepRawSamples','SaveAnalysis','SavePlots'};
for index = 1:numel(logicalFields)
    value = options.(logicalFields{index});
    if ~(islogical(value) && isscalar(value))
        error('IMU:InvalidAnalysisOptions', '%s must be logical.', logicalFields{index});
    end
end
if ~(ischar(options.OutputDirectory) || ...
        (isstring(options.OutputDirectory) && isscalar(options.OutputDirectory)))
    error('IMU:InvalidAnalysisOptions', 'OutputDirectory must be scalar text.');
end
end

function fileSystem = mergeFileSystem(fileSystem, custom)
if ~isstruct(custom) || ~isscalar(custom)
    error('IMU:InvalidAnalysisOptions', 'FileSystem must be a scalar structure.');
end
fields = fieldnames(custom);
unknown = setdiff(fields, fieldnames(fileSystem));
if ~isempty(unknown)
    error('IMU:InvalidAnalysisOptions', 'Unknown FileSystem operation: %s.', unknown{1});
end
for index = 1:numel(fields)
    if ~isa(custom.(fields{index}), 'function_handle')
        error('IMU:InvalidAnalysisOptions', ...
            'FileSystem.%s must be a function handle.', fields{index});
    end
    fileSystem.(fields{index}) = custom.(fields{index});
end
end

function fileSystem = defaultFileSystem()
fileSystem = struct('MakeDirectory', @makeDirectory, ...
    'RemoveDirectory', @removeDirectory, 'MoveDirectory', @moveDirectory, ...
    'WriteMat', @writeResultMat, 'WriteJson', @writeJson, ...
    'VerifyMat', @verifyResultMat, 'VerifyJson', @verifyJson, ...
    'IsFile', @isfile, 'IsDirectory', @isfolder);
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

function result = saveAnalysisTransaction(result, session, options)
fileSystem = options.FileSystem;
if strlength(string(options.OutputDirectory)) > 0
    finalDirectory = char(string(options.OutputDirectory));
else
    finalDirectory = fullfile(char(result.sessionDirectory), 'analysis');
end
stagingDirectory = [finalDirectory, '.inprogress'];
backupDirectory = [finalDirectory, '.previous'];
if fileSystem.IsDirectory(stagingDirectory)
    fileSystem.RemoveDirectory(stagingDirectory);
end
fileSystem.MakeDirectory(stagingDirectory);
cleanup = onCleanup(@()cleanupStaging(fileSystem, stagingDirectory));

result.analysisDirectory = string(finalDirectory);
result.resultMatFile = string(fullfile(finalDirectory, 'result.mat'));
result.eventsJsonFile = string(fullfile(finalDirectory, 'events.json'));
result.summaryJsonFile = string(fullfile(finalDirectory, 'summary.json'));
result.diagnosticPlotPngFile = string(fullfile(finalDirectory, 'diagnostic_plots.png'));
result.diagnosticPlotFigFile = string(fullfile(finalDirectory, 'diagnostic_plots.fig'));
if ~options.SavePlots
    result.diagnosticPlotPngFile = "";
    result.diagnosticPlotFigFile = "";
end
persistedResult = result;
persistedResult.success = true;
persistedResult.errors = strings(0, 1);

stagingMat = fullfile(stagingDirectory, 'result.mat');
stagingEvents = fullfile(stagingDirectory, 'events.json');
stagingSummary = fullfile(stagingDirectory, 'summary.json');
fileSystem.WriteMat(stagingMat, persistedResult);
fileSystem.WriteJson(stagingEvents, eventsForJson(persistedResult.events));
summary = analysisSummary(persistedResult, session);
fileSystem.WriteJson(stagingSummary, summary);
if options.SavePlots
    plotResult = persistedResult;
    plotResult.analysisDirectory = string(stagingDirectory);
    figureHandle = plotDrivingSessionAnalysis(plotResult);
    figureCleanup = onCleanup(@()closeValidFigure(figureHandle));
    close(figureHandle); clear figureCleanup;
end

fileSystem.VerifyMat(stagingMat);
fileSystem.VerifyJson(stagingEvents);
fileSystem.VerifyJson(stagingSummary);
required = {stagingMat, stagingEvents, stagingSummary};
if options.SavePlots
    required = [required, {fullfile(stagingDirectory, 'diagnostic_plots.png'), ...
        fullfile(stagingDirectory, 'diagnostic_plots.fig')}];
end
for index = 1:numel(required)
    if ~fileSystem.IsFile(required{index})
        error('IMU:AnalysisVerificationFailed', ...
            'Expected analysis file is missing: %s.', required{index});
    end
end
if options.SavePlots
    verifyPlots(stagingDirectory);
end

hadPrevious = fileSystem.IsDirectory(finalDirectory);
if fileSystem.IsDirectory(backupDirectory)
    fileSystem.RemoveDirectory(backupDirectory);
end
if hadPrevious
    requireMove(fileSystem, finalDirectory, backupDirectory);
end
try
    requireMove(fileSystem, stagingDirectory, finalDirectory);
catch exception
    if hadPrevious && ~fileSystem.IsDirectory(finalDirectory) && ...
            fileSystem.IsDirectory(backupDirectory)
        requireMove(fileSystem, backupDirectory, finalDirectory);
    end
    rethrow(exception);
end
if fileSystem.IsDirectory(backupDirectory)
    fileSystem.RemoveDirectory(backupDirectory);
end
clear cleanup;
result = persistedResult;
end

function summary = analysisSummary(result, session)
summary = struct('sessionId', string(session.metadata.sessionId), ...
    'uid', string(session.metadata.uid), 'busId', string(session.metadata.busId), ...
    'sessionFormatVersion', result.loadReport.sessionFormatVersion, ...
    'sampleRateHz', session.sampleRateHz, ...
    'analysisVersion', string(result.config.analysisVersion), ...
    'sampleCount', result.loadReport.samplesLoaded, ...
    'elapsedDurationSeconds', result.elapsedDurationSeconds, ...
    'observedSampleDurationSeconds', result.observedSampleDurationSeconds, ...
    'missingSamples', result.loadReport.missingSamples, ...
    'shortGapCount', result.loadReport.shortGapCount, ...
    'majorGapCount', result.loadReport.majorGapCount, ...
    'eventCounts', result.eventCounts, 'thresholds', result.config);
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

function makeDirectory(directory)
[success, message] = mkdir(directory);
if ~success, error('IMU:AnalysisWriteFailed', '%s', message); end
end

function removeDirectory(directory)
if ~isfolder(directory), return; end
[success, message] = rmdir(directory, 's');
if ~success, error('IMU:AnalysisCleanupFailed', '%s', message); end
end

function [success, message] = moveDirectory(source, destination)
[success, message] = movefile(source, destination);
end

function requireMove(fileSystem, source, destination)
[success, message] = fileSystem.MoveDirectory(source, destination);
if ~success, error('IMU:AnalysisFinalizeFailed', '%s', message); end
end

function writeResultMat(filename, value)
result = value;
save(filename, 'result', '-v7');
end

function writeJson(filename, value)
fileId = fopen(filename, 'w');
if fileId < 0, error('IMU:AnalysisWriteFailed', 'Cannot write %s.', filename); end
cleanup = onCleanup(@()fclose(fileId));
fprintf(fileId, '%s', jsonencode(value, 'PrettyPrint', true));
clear cleanup;
end

function verifyResultMat(filename)
contents = load(filename, 'result');
if ~isfield(contents, 'result') || ~contents.result.success || ...
        ~isempty(contents.result.errors)
    error('IMU:AnalysisVerificationFailed', ...
        'Saved result.mat does not contain a successful result.');
end
end

function verifyJson(filename)
jsondecode(fileread(filename));
end

function verifyPlots(directory)
imfinfo(fullfile(directory, 'diagnostic_plots.png'));
figureHandle = openfig(fullfile(directory, 'diagnostic_plots.fig'), ...
    'invisible');
cleanup = onCleanup(@()closeValidFigure(figureHandle));
close(figureHandle); clear cleanup;
end

function cleanupStaging(fileSystem, stagingDirectory)
if fileSystem.IsDirectory(stagingDirectory)
    fileSystem.RemoveDirectory(stagingDirectory);
end
end

function closeValidFigure(figureHandle)
if isgraphics(figureHandle), close(figureHandle); end
end
