classdef TestImuSessionLoader < matlab.unittest.TestCase
    properties
        TemporaryDirectory
    end
    methods (TestClassSetup)
        function setup(testCase)
            root = fileparts(fileparts(mfilename('fullpath')));
            addpath(fullfile(root, 'src'));
            testCase.TemporaryDirectory = tempname;
            mkdir(testCase.TemporaryDirectory);
            testCase.addTeardown(@()rmdir(testCase.TemporaryDirectory, 's'));
        end
    end
    methods (Test)
        function validMultiChunkSessionLoads(testCase)
            directory = createSyntheticDrivingSession( ...
                testCase.TemporaryDirectory, "stationary");
            [session, report] = loadImuSession(directory, ...
                struct('AllowSynthetic', true));
            testCase.verifyTrue(report.valid);
            testCase.verifyEqual(report.chunkCount, 3);
            testCase.verifyEqual(report.samplesLoaded, 500);
            testCase.verifyEqual(height(session.data), 500);
            required = {'sequenceNumber','hostTimestamp','sessionId', ...
                'longitudinalAcceleration','lateralAcceleration', ...
                'verticalAcceleration','rollRate','pitchRate','yawRate', ...
                'gravityX','gravityY','gravityZ','temperature','callbackAgeMs'};
            testCase.verifyTrue(all(ismember(required, ...
                session.data.Properties.VariableNames)));
        end

        function missingChunkRejected(testCase)
            directory = createSyntheticDrivingSession( ...
                testCase.TemporaryDirectory, "stationary");
            delete(fullfile(directory, 'samples_000002.mat'));
            [~, report] = loadImuSession(directory, struct('AllowSynthetic', true));
            testCase.verifyFalse(report.valid);
            testCase.verifyTrue(any(contains(report.errors, "numbering")));
        end

        function wrongSamplesWrittenRejected(testCase)
            directory = createSyntheticDrivingSession( ...
                testCase.TemporaryDirectory, "stationary");
            filename = fullfile(directory, 'summary.json');
            summary = jsondecode(fileread(filename)); summary.samplesWritten = 499;
            testCase.writeJson(filename, summary);
            [~, report] = loadImuSession(directory, struct('AllowSynthetic', true));
            testCase.verifyFalse(report.valid);
            testCase.verifyTrue(any(contains(report.errors, "samplesWritten")));
        end

        function duplicateSequenceRejected(testCase)
            directory = createSyntheticDrivingSession( ...
                testCase.TemporaryDirectory, "stationary");
            filename = fullfile(directory, 'samples_000002.mat');
            contents = load(filename);
            contents.sensorSamples{1}.sequenceNumber = uint64(175);
            contents.vehicleSamples{1}.sequenceNumber = uint64(175);
            sensorSamples = contents.sensorSamples;
            vehicleSamples = contents.vehicleSamples;
            save(filename, 'sensorSamples', 'vehicleSamples', '-v7');
            [~, report] = loadImuSession(directory, struct('AllowSynthetic', true));
            testCase.verifyFalse(report.valid);
            testCase.verifyGreaterThan(report.duplicateSamples, 0);
        end

        function sequenceGapReportedAndOptionRequired(testCase)
            directory = createSyntheticDrivingSession( ...
                testCase.TemporaryDirectory, "sequence_gap");
            [~, rejected] = loadImuSession(directory, struct('AllowSynthetic', true));
            testCase.verifyFalse(rejected.valid);
            [session, accepted] = loadImuSession(directory, struct( ...
                'AllowSynthetic', true, 'AllowMissingSamples', true));
            testCase.verifyTrue(accepted.valid);
            testCase.verifyEqual(accepted.missingSamples, 4);
            testCase.verifySize(accepted.gaps, [1 3]);
            testCase.verifyEqual(height(session.data), 500);
        end

        function incompleteSessionRejectedByDefault(testCase)
            directory = createSyntheticDrivingSession( ...
                testCase.TemporaryDirectory, "stationary");
            filename = fullfile(directory, 'metadata.json');
            metadata = jsondecode(fileread(filename)); metadata.status = 'incomplete';
            testCase.writeJson(filename, metadata);
            [~, rejected] = loadImuSession(directory, struct('AllowSynthetic', true));
            testCase.verifyFalse(rejected.valid);
            [~, accepted] = loadImuSession(directory, struct( ...
                'AllowSynthetic', true, 'AllowIncomplete', true));
            testCase.verifyTrue(accepted.valid);
        end

        function syntheticSessionNeedsExplicitPermission(testCase)
            directory = createSyntheticDrivingSession( ...
                testCase.TemporaryDirectory, "stationary");
            [~, rejected] = loadImuSession(directory);
            testCase.verifyFalse(rejected.valid);
            [~, accepted] = loadImuSession(directory, struct('AllowSynthetic', true));
            testCase.verifyTrue(accepted.valid);
        end
    end
    methods (Access = private)
        function writeJson(~, filename, value)
            fileId = fopen(filename, 'w'); assert(fileId >= 0);
            cleanup = onCleanup(@()fclose(fileId));
            fprintf(fileId, '%s', jsonencode(value, 'PrettyPrint', true));
            clear cleanup;
        end
    end
end
