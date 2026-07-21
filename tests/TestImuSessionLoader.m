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
            testCase.verifyEqual(session.sampleRateHz, 50);
            testCase.verifyEqual(report.sessionFormatVersion, 2);
            testCase.verifyFalse(report.legacySession);
            testCase.verifyTrue(report.sampleRateMatchesAnalysis);
            testCase.verifyTrue(report.identityVerifiedPerSample);
            testCase.verifyFalse(report.rawSamplesRetained);
            testCase.verifyEmpty(session.rawSensorSamples);
            testCase.verifyGreaterThan(report.estimatedMemoryBytes, 0);
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

        function rawSamplesRequireExplicitRetention(testCase)
            directory = createSyntheticDrivingSession( ...
                testCase.TemporaryDirectory, "stationary");
            [session, report] = loadImuSession(directory, struct( ...
                'AllowSynthetic', true, 'KeepRawSamples', true));
            testCase.verifyTrue(report.valid);
            testCase.verifyTrue(report.rawSamplesRetained);
            testCase.verifyEqual(numel(session.rawSensorSamples), 500);
            testCase.verifyEqual(numel(session.rawVehicleSamples), 500);
        end

        function maximumSamplesLimitRejectedBeforeChunks(testCase)
            directory = createSyntheticDrivingSession( ...
                testCase.TemporaryDirectory, "stationary");
            [~, report] = loadImuSession(directory, struct( ...
                'AllowSynthetic', true, 'MaximumSamplesInMemory', 499));
            testCase.verifyFalse(report.valid);
            testCase.verifyTrue(any(contains(report.errors, ...
                "IMU:MaximumSamplesInMemoryExceeded")));
            testCase.verifyEqual(report.samplesLoaded, 0);
        end

        function legacySessionRejectedByDefault(testCase)
            directory = createSyntheticDrivingSession( ...
                testCase.TemporaryDirectory, "stationary");
            testCase.makeLegacy(directory, true);
            [~, report] = loadImuSession(directory, struct('AllowSynthetic', true));
            testCase.verifyFalse(report.valid);
            testCase.verifyTrue(report.legacySession);
        end

        function legacySessionRequiresExplicitRateAndUsesMetadataIdentity(testCase)
            directory = createSyntheticDrivingSession( ...
                testCase.TemporaryDirectory, "stationary");
            testCase.makeLegacy(directory, true);
            [~, missingRate] = loadImuSession(directory, struct( ...
                'AllowSynthetic', true, 'AllowLegacySession', true));
            testCase.verifyFalse(missingRate.valid);
            [session, report] = loadImuSession(directory, struct( ...
                'AllowSynthetic', true, 'AllowLegacySession', true, ...
                'LegacySampleRateHz', 50));
            testCase.verifyTrue(report.valid, strjoin(report.errors, ' '));
            testCase.verifyEqual(session.sampleRateHz, 50);
            testCase.verifyTrue(report.legacySession);
            testCase.verifyFalse(report.identityVerifiedPerSample);
            testCase.verifyNotEmpty(report.warnings);
        end

        function version2RequiresPerSampleIdentity(testCase)
            directory = createSyntheticDrivingSession( ...
                testCase.TemporaryDirectory, "stationary");
            filename = fullfile(directory, 'samples_000001.mat');
            contents = load(filename);
            contents.sensorSamples{1} = rmfield(contents.sensorSamples{1}, ...
                {'imuUid','busId'});
            contents.vehicleSamples{1} = rmfield(contents.vehicleSamples{1}, ...
                {'imuUid','busId'});
            sensorSamples = contents.sensorSamples;
            vehicleSamples = contents.vehicleSamples;
            save(filename, 'sensorSamples', 'vehicleSamples', '-v7');
            [~, report] = loadImuSession(directory, struct('AllowSynthetic', true));
            testCase.verifyFalse(report.valid);
            testCase.verifyTrue(any(contains(report.errors, "required for format v2")));
        end

        function metadataAndSummaryRatesMustMatch(testCase)
            directory = createSyntheticDrivingSession( ...
                testCase.TemporaryDirectory, "stationary");
            filename = fullfile(directory, 'summary.json');
            summary = jsondecode(fileread(filename));
            summary.sampleRateHz = 40;
            testCase.writeJson(filename, summary);
            [~, report] = loadImuSession(directory, struct('AllowSynthetic', true));
            testCase.verifyFalse(report.valid);
            testCase.verifyTrue(any(contains(report.errors, "sample rates differ")));
        end

        function shortAndMajorGapsAreClassified(testCase)
            shortDirectory = createSyntheticDrivingSession( ...
                testCase.TemporaryDirectory, "stationary");
            testCase.addSequenceGap(shortDirectory, 2);
            [~, shortReport] = loadImuSession(shortDirectory, struct( ...
                'AllowSynthetic', true, 'AllowMissingSamples', true));
            testCase.verifyTrue(shortReport.valid, strjoin(shortReport.errors, ' '));
            testCase.verifyEqual(shortReport.shortGapCount, 1);
            testCase.verifyEqual(shortReport.majorGapCount, 0);

            majorDirectory = createSyntheticDrivingSession( ...
                testCase.TemporaryDirectory, "sequence_gap");
            [~, majorReport] = loadImuSession(majorDirectory, struct( ...
                'AllowSynthetic', true, 'AllowMissingSamples', true));
            testCase.verifyTrue(majorReport.valid, strjoin(majorReport.errors, ' '));
            testCase.verifyEqual(majorReport.shortGapCount, 0);
            testCase.verifyEqual(majorReport.majorGapCount, 1);
        end
    end
    methods (Access = private)
        function writeJson(~, filename, value)
            fileId = fopen(filename, 'w'); assert(fileId >= 0);
            cleanup = onCleanup(@()fclose(fileId));
            fprintf(fileId, '%s', jsonencode(value, 'PrettyPrint', true));
            clear cleanup;
        end

        function makeLegacy(testCase, directory, removeIdentity)
            for name = ["metadata.json", "summary.json"]
                filename = fullfile(directory, name);
                value = jsondecode(fileread(filename));
                value = rmfield(value, {'sessionFormatVersion', ...
                    'sampleRateHz','callbackPeriodMs'});
                testCase.writeJson(filename, value);
            end
            if ~removeIdentity, return; end
            chunks = dir(fullfile(directory, 'samples_*.mat'));
            for chunk = chunks.'
                filename = fullfile(chunk.folder, chunk.name);
                contents = load(filename);
                for index = 1:numel(contents.sensorSamples)
                    contents.sensorSamples{index} = rmfield( ...
                        contents.sensorSamples{index}, {'imuUid','busId'});
                    contents.vehicleSamples{index} = rmfield( ...
                        contents.vehicleSamples{index}, {'imuUid','busId'});
                end
                sensorSamples = contents.sensorSamples;
                vehicleSamples = contents.vehicleSamples;
                save(filename, 'sensorSamples', 'vehicleSamples', '-v7');
            end
        end

        function addSequenceGap(testCase, directory, missingCount)
            chunks = dir(fullfile(directory, 'samples_*.mat'));
            globalIndex = 0;
            for chunk = chunks.'
                filename = fullfile(chunk.folder, chunk.name);
                contents = load(filename);
                for index = 1:numel(contents.sensorSamples)
                    globalIndex = globalIndex + 1;
                    if globalIndex >= 251
                        contents.sensorSamples{index}.sequenceNumber = ...
                            contents.sensorSamples{index}.sequenceNumber + missingCount;
                        contents.vehicleSamples{index}.sequenceNumber = ...
                            contents.vehicleSamples{index}.sequenceNumber + missingCount;
                    end
                end
                sensorSamples = contents.sensorSamples;
                vehicleSamples = contents.vehicleSamples;
                save(filename, 'sensorSamples', 'vehicleSamples', '-v7');
            end
            filename = fullfile(directory, 'summary.json');
            summary = jsondecode(fileread(filename));
            summary.missingSamples = missingCount;
            testCase.writeJson(filename, summary);
        end
    end
end
