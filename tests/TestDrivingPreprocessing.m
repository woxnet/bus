classdef TestDrivingPreprocessing < matlab.unittest.TestCase
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
        function outlierIsSuppressed(testCase)
            session = testCase.loadScenario("outlier", false);
            processed = preprocessDrivingSession(session);
            testCase.verifyTrue(processed.outlierReplaced(250));
            testCase.verifyLessThan(max(abs(processed.longitudinalFiltered)), 0.1);
        end

        function zeroPhaseStepHasNoMaterialShift(testCase)
            count = 500; values = zeros(count, 1); values(251:end) = 1;
            session = testCase.sessionFromSignals(values, zeros(count, 3), uint64(1:count));
            processed = preprocessDrivingSession(session);
            [~, crossing] = min(abs(processed.longitudinalFiltered - 0.5));
            testCase.verifyLessThanOrEqual(abs(crossing - 250.5), 2);
        end

        function jerkDoesNotCrossSequenceGap(testCase)
            session = testCase.loadScenario("sequence_gap", true);
            processed = preprocessDrivingSession(session);
            boundary = find(diff(double(processed.sequenceNumber)) > 1, 1) + 1;
            testCase.verifyNotEqual(processed.segmentId(boundary - 1), ...
                processed.segmentId(boundary));
            testCase.verifyTrue(isnan(processed.longitudinalJerk(boundary - 1)));
            testCase.verifyTrue(isnan(processed.longitudinalJerk(boundary)));
        end

        function timestampGapStartsNewSegment(testCase)
            count = 500;
            session = testCase.sessionFromSignals(zeros(count, 1), ...
                zeros(count, 3), uint64(1:count));
            session.data.hostTimestamp(251:end) = ...
                session.data.hostTimestamp(251:end) + seconds(1);
            processed = preprocessDrivingSession(session);
            testCase.verifyNotEqual(processed.segmentId(250), ...
                processed.segmentId(251));
            testCase.verifyTrue(isnan(processed.longitudinalJerk(250)));
            testCase.verifyTrue(isnan(processed.longitudinalJerk(251)));
        end

        function invalidConfigRejected(testCase)
            config = getDrivingAnalysisConfig();
            config.accelerationStopThreshold = config.accelerationStartThreshold;
            testCase.verifyError(@()validateDrivingAnalysisConfig(config), ...
                'IMU:InvalidDrivingAnalysisConfig');
        end

        function noSignalProcessingToolboxFunctions(testCase)
            root = fileparts(fileparts(mfilename('fullpath')));
            source = string(fileread(fullfile(root, 'src', ...
                'preprocessDrivingSession.m'))) + newline + ...
                string(fileread(fullfile(root, 'src', 'zeroPhaseEma.m')));
            forbidden = ["butter(","filtfilt(","lowpass(", ...
                "designfilt(","sgolayfilt("];
            for value = forbidden
                testCase.verifyFalse(contains(source, value, 'IgnoreCase', true));
            end
        end
    end
    methods (Access = private)
        function session = loadScenario(testCase, scenario, allowMissing)
            directory = createSyntheticDrivingSession(testCase.TemporaryDirectory, scenario);
            [session, report] = loadImuSession(directory, struct( ...
                'AllowSynthetic', true, 'AllowMissingSamples', allowMissing));
            testCase.assertTrue(report.valid, strjoin(report.errors, ' '));
        end

        function session = sessionFromSignals(~, longitudinal, remaining, sequence)
            count = numel(longitudinal); sequenceNumber = uint64(sequence(:));
            config = getDrivingAnalysisConfig();
            hostTimestamp = datetime('now', 'TimeZone', 'UTC') + ...
                seconds((0:count-1).' / config.targetSampleRateHz);
            sessionId = ones(count, 1, 'uint64');
            timeSeconds = double(sequenceNumber - sequenceNumber(1)) / config.targetSampleRateHz;
            longitudinalAcceleration = longitudinal(:);
            lateralAcceleration = remaining(:, 1);
            verticalAcceleration = remaining(:, 2);
            yawRate = remaining(:, 3);
            callbackAgeMs = ones(count, 1);
            session.data = table(sequenceNumber, hostTimestamp, sessionId, timeSeconds, ...
                longitudinalAcceleration, lateralAcceleration, verticalAcceleration, ...
                yawRate, callbackAgeMs);
            session.sampleRateHz = config.targetSampleRateHz;
        end
    end
end
