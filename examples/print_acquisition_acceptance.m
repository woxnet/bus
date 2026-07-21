if ~exist('summary', 'var')
    projectRoot = fileparts(fileparts(mfilename('fullpath')));
    files = dir(fullfile(projectRoot, 'artifacts', ...
        'acquisition_acceptance_*.mat'));
    if isempty(files)
        error('IMU:AcceptanceSummaryMissing', ...
            'No acquisition acceptance summary was found.');
    end
    [~, newest] = max([files.datenum]);
    contents = load(fullfile(files(newest).folder, files(newest).name), 'summary');
    summary = contents.summary;
end

fprintf('Commit: %s\n', summary.commit);
fprintf('MATLAB version: %s\n', summary.matlabVersion);
fprintf('Startup: %s\n', passFail(summary.startup.success));
fprintf('Unit tests: %s\n', passFail(summary.unitTests.success));
fprintf('Java bridge: %s\n', passFail( ...
    summary.startup.bridgeClassLoaded && summary.startup.loadedSourcesMatch));
fprintf('Preflight: %s\n', passFail(summary.preflight.success));
fprintf('60-second acceptance: %s\n', ...
    passFail(summary.hardwareAcceptance.success));
fprintf('120-second recording: %s\n', passFail(summary.recordedSession.success));
fprintf('\nCallback frequency: %.3f Hz\n', ...
    summary.hardwareAcceptance.meanFrequencyHz);
fprintf('Missing sequences: %d\n', summary.hardwareAcceptance.missing);
fprintf('Overflow drops: %d\n', summary.hardwareAcceptance.overflowDropped);
fprintf('Stale session drops: %d\n', ...
    summary.hardwareAcceptance.staleSessionDropped);
fprintf('Maximum age: %.3f ms\n', ...
    summary.hardwareAcceptance.sampleAgeMaximumMs);
fprintf('Recorded sample count: %d\n', ...
    summary.recordedSession.samplesWritten);
fprintf('Session directory: %s\n', summary.recordedSession.directory);

function text = passFail(success)
if success, text = 'PASS'; else, text = 'FAIL'; end
end
