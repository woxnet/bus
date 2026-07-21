function summary = summarizeImuAcquisitionAcceptance( ...
    startupStatus, unitTestResults, preflightReport, ...
    hardwareAcceptanceReport, recordedSession, outputDirectory)
%SUMMARIZEIMUACQUISITIONACCEPTANCE Save the complete acquisition gate result.

if nargin < 6 || isempty(outputDirectory), outputDirectory = 'artifacts'; end
if numel(startupStatus) > 1, startupStatus = startupStatus(end); end
config = getImuConfig();

startup = startupStatus;
startup.success = scalarLogical(startupStatus, 'available') && ...
    ~scalarLogical(startupStatus, 'restartRequired') && ...
    scalarLogical(startupStatus, 'loadedSourcesMatch') && ...
    ~scalarLogical(startupStatus, 'javaAddPathCalled') && ...
    isfield(startupStatus, 'pathsAdded') && isempty(startupStatus.pathsAdded);

unitTests = summarizeUnitTests(unitTestResults);
preflight = preflightReport;
preflight.success = scalarLogical(preflightReport, 'success');
hardwareAcceptance = hardwareAcceptanceReport;
hardwareAcceptance.success = hardwarePassed(hardwareAcceptanceReport, config);
recording = recordedSession;
recording.success = recordingPassed(recordedSession, config);

summary = struct( ...
    'success', startup.success && unitTests.success && preflight.success && ...
        hardwareAcceptance.success && recording.success, ...
    'commit', currentCommit(), ...
    'matlabVersion', string(version), ...
    'javaVersion', string(javaMethod('getProperty', ...
        'java.lang.System', 'java.version')), ...
    'startup', startup, ...
    'unitTests', unitTests, ...
    'preflight', preflight, ...
    'hardwareAcceptance', hardwareAcceptance, ...
    'recordedSession', recording, ...
    'errors', strings(0, 1), ...
    'warnings', strings(0, 1), ...
    'matFile', "", 'jsonFile', "");

summary.errors = failedStages(summary);
summary.warnings = collectWarnings( ...
    startupStatus, preflightReport, hardwareAcceptanceReport, recordedSession);

outputDirectory = resolveProjectPath(outputDirectory);
if ~isfolder(outputDirectory), mkdir(outputDirectory); end
stamp = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
base = fullfile(outputDirectory, ['acquisition_acceptance_', stamp]);
summary.matFile = string(base) + ".mat";
summary.jsonFile = string(base) + ".json";
save(char(summary.matFile), 'summary');
writeJson(char(summary.jsonFile), summary);
end

function result = summarizeUnitTests(results)
if isempty(results)
    result = struct('success', false, 'Passed', 0, 'Failed', 0, ...
        'Incomplete', 0, 'Duration', 0);
    return;
end
passed = logical([results.Passed]);
failed = logical([results.Failed]);
incomplete = logical([results.Incomplete]);
durations = double([results.Duration]);
result = struct('success', all(passed) && ~any(failed) && ~any(incomplete), ...
    'Passed', sum(passed), 'Failed', sum(failed), ...
    'Incomplete', sum(incomplete), 'Duration', sum(durations));
end

function result = hardwarePassed(report, config)
result = scalarLogical(report, 'success') && ...
    finiteAtLeast(report, 'durationSeconds', 60) && ...
    finiteEqual(report, 'missing', 0) && ...
    finiteEqual(report, 'overflowDropped', 0) && ...
    finiteEqual(report, 'staleSessionDropped', 0) && ...
    finiteBetween(report, 'meanFrequencyHz', ...
        config.minimumDiagnosticFrequencyHz, config.maximumDiagnosticFrequencyHz) && ...
    finiteAtMost(report, 'sampleAgeMaximumMs', config.maximumCallbackSampleAgeMs) && ...
    finiteNear(report, 'gravityMagnitudeMean', ...
        config.gravityReference, config.maximumGravityError) && ...
    finiteNear(report, 'quaternionNormMean', 1, 0.1);
end

function result = recordingPassed(session, config)
directoryExists = isfield(session, 'directory') && ...
    isfolder(char(string(session.directory)));
result = isfield(session, 'status') && string(session.status) == "complete" && ...
    finiteAtLeast(session, 'durationSeconds', 120) && ...
    finiteAtLeast(session, 'samplesWritten', ...
        120 * config.minimumDiagnosticFrequencyHz) && ...
    finiteEqual(session, 'duplicateSamples', 0) && ...
    finiteEqual(session, 'missingSamples', 0) && ...
    finiteEqual(session, 'overflowDropped', 0) && ...
    finiteEqual(session, 'staleSessionDropped', 0) && directoryExists;
end

function errors = failedStages(summary)
errors = strings(0, 1);
names = ["startup", "unitTests", "preflight", ...
    "hardwareAcceptance", "recordedSession"];
for index = 1:numel(names)
    if ~summary.(names(index)).success
        errors(end+1, 1) = names(index) + " acceptance failed."; %#ok<AGROW>
    end
end
end

function warnings = collectWarnings(varargin)
warnings = strings(0, 1);
for index = 1:numel(varargin)
    value = varargin{index};
    if isstruct(value) && isfield(value, 'warnings') && ~isempty(value.warnings)
        warnings = [warnings; string(value.warnings(:))]; %#ok<AGROW>
    end
end
end

function result = scalarLogical(value, field)
result = isstruct(value) && isscalar(value) && isfield(value, field) && ...
    islogical(value.(field)) && isscalar(value.(field)) && value.(field);
end

function result = finiteEqual(value, field, expected)
result = finiteScalar(value, field) && value.(field) == expected;
end

function result = finiteAtLeast(value, field, minimum)
result = finiteScalar(value, field) && value.(field) >= minimum;
end

function result = finiteAtMost(value, field, maximum)
result = finiteScalar(value, field) && value.(field) <= maximum;
end

function result = finiteBetween(value, field, minimum, maximum)
result = finiteAtLeast(value, field, minimum) && ...
    finiteAtMost(value, field, maximum);
end

function result = finiteNear(value, field, expected, tolerance)
result = finiteScalar(value, field) && abs(value.(field) - expected) <= tolerance;
end

function result = finiteScalar(value, field)
result = isstruct(value) && isscalar(value) && isfield(value, field) && ...
    isnumeric(value.(field)) && isscalar(value.(field)) && isfinite(value.(field));
end

function commit = currentCommit()
[status, output] = system('git rev-parse HEAD');
if status == 0, commit = string(strtrim(output)); else, commit = "unknown"; end
end

function writeJson(filename, value)
temporary = [filename, '.tmp'];
fileId = fopen(temporary, 'w');
if fileId < 0
    error('IMU:AcceptanceSaveFailed', 'Cannot write %s.', temporary);
end
cleanup = onCleanup(@()fclose(fileId));
fprintf(fileId, '%s', jsonencode(value, 'PrettyPrint', true));
clear cleanup;
[success, message] = movefile(temporary, filename, 'f');
if ~success, error('IMU:AcceptanceSaveFailed', '%s', message); end
end
