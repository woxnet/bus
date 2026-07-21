classdef TestDrivingEventDetector < matlab.unittest.TestCase
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
        function stationaryCreatesNoEvents(testCase)
            result = testCase.analyze("stationary");
            testCase.verifyEmpty(result.events);
        end

        function brakingCreatesOneEvent(testCase)
            testCase.verifyScenarioCount("braking", 'BRAKING_CANDIDATE', 1);
        end

        function accelerationCreatesOneEvent(testCase)
            testCase.verifyScenarioCount("acceleration", 'ACCELERATION_CANDIDATE', 1);
        end

        function leftTurnDetected(testCase)
            testCase.verifyScenarioCount("left_turn", 'TURN_LEFT_CANDIDATE', 1);
        end

        function rightTurnDetected(testCase)
            testCase.verifyScenarioCount("right_turn", 'TURN_RIGHT_CANDIDATE', 1);
        end

        function verticalShockDetected(testCase)
            testCase.verifyScenarioCount("vertical_shock", ...
                'VERTICAL_SHOCK_CANDIDATE', 1);
        end

        function shortEventRejected(testCase)
            processed = testCase.processedPulse([101 110], [], false);
            events = detectDrivingEvents(processed);
            testCase.verifyEmpty(events);
        end

        function nearbyEventsMerge(testCase)
            processed = testCase.processedPulse([101 125; 136 160], [], false);
            events = detectDrivingEvents(processed);
            testCase.verifyEqual(sum(string({events.type}) == ...
                "ACCELERATION_CANDIDATE"), 1);
        end

        function eventsAcrossSequenceGapDoNotMerge(testCase)
            processed = testCase.processedPulse([101 125; 136 160], 136, true);
            events = detectDrivingEvents(processed);
            testCase.verifyEqual(sum(string({events.type}) == ...
                "ACCELERATION_CANDIDATE"), 2);
            firstEvent = events(1);
            secondEvent = events(2);
            testCase.verifyLessThan(firstEvent.contextEndIndex, 136);
            testCase.verifyGreaterThanOrEqual(secondEvent.contextStartIndex, 136);
        end

        function outlierCreatesNoEvents(testCase)
            result = testCase.analyze("outlier");
            testCase.verifyEmpty(result.events);
        end

        function mixedScenarioHasAllCandidateTypes(testCase)
            result = testCase.analyze("mixed_events");
            counts = result.eventCounts;
            testCase.verifyEqual(counts.BRAKING_CANDIDATE, 1);
            testCase.verifyEqual(counts.ACCELERATION_CANDIDATE, 1);
            testCase.verifyEqual(counts.TURN_LEFT_CANDIDATE, 1);
            testCase.verifyEqual(counts.TURN_RIGHT_CANDIDATE, 1);
            testCase.verifyEqual(counts.VERTICAL_SHOCK_CANDIDATE, 1);
            required = {'eventId','type','startSequence','endSequence', ...
                'dataQuality','thresholds'};
            testCase.verifyTrue(all(isfield(result.events, required)));
        end

        function jsonOutputsRoundTrip(testCase)
            result = testCase.analyze("braking");
            testCase.verifyTrue(isfile(result.resultMatFile));
            testCase.verifyTrue(isfile(result.eventsJsonFile));
            testCase.verifyTrue(isfile(result.summaryJsonFile));
            events = jsondecode(fileread(result.eventsJsonFile));
            summary = jsondecode(fileread(result.summaryJsonFile));
            testCase.verifyEqual(numel(events), 1);
            testCase.verifyEqual(summary.eventCounts.BRAKING_CANDIDATE, 1);
            saved = load(result.resultMatFile, 'result');
            testCase.verifyTrue(saved.result.success);
            testCase.verifyEmpty(saved.result.errors);
        end

        function elapsedAndObservedDurationsHaveDistinctGapSemantics(testCase)
            directory = createSyntheticDrivingSession( ...
                testCase.TemporaryDirectory, "sequence_gap");
            result = analyzeImuSession(directory, struct( ...
                'AllowSynthetic', true, 'AllowMissingSamples', true, ...
                'SaveAnalysis', false));
            testCase.verifyTrue(result.success, strjoin(result.errors, ' '));
            testCase.verifyEqual(result.elapsedDurationSeconds, 10.08, ...
                'AbsTol', 1e-12);
            testCase.verifyEqual(result.observedSampleDurationSeconds, 10, ...
                'AbsTol', 1e-12);
            testCase.verifyEqual(result.totalDurationSeconds, ...
                result.elapsedDurationSeconds);
        end
    end
    methods (Access = private)
        function result = analyze(testCase, scenario)
            directory = createSyntheticDrivingSession(testCase.TemporaryDirectory, scenario);
            result = analyzeImuSession(directory, struct('AllowSynthetic', true));
            testCase.assertTrue(result.success, strjoin(result.errors, ' '));
        end

        function verifyScenarioCount(testCase, scenario, field, expected)
            result = testCase.analyze(scenario);
            testCase.verifyEqual(result.eventCounts.(field), expected);
        end

        function processed = processedPulse(~, ranges, gapIndex, createGap)
            config = getDrivingAnalysisConfig(); count = 250;
            sequence = uint64((1:count).'); segmentId = ones(count, 1);
            if createGap
                sequence(gapIndex:end) = sequence(gapIndex:end) + 10;
                segmentId(gapIndex:end) = 2;
            end
            longitudinal = zeros(count, 1);
            for index = 1:size(ranges, 1)
                longitudinal(ranges(index, 1):ranges(index, 2)) = 1.8;
            end
            timeSeconds = double(sequence - sequence(1)) / config.targetSampleRateHz;
            hostTimestamp = datetime('now', 'TimeZone', 'UTC') + seconds(timeSeconds);
            zerosColumn = zeros(count, 1);
            processed = struct('sequenceNumber', sequence, ...
                'hostTimestamp', hostTimestamp, 'timeSeconds', timeSeconds, ...
                'sampleRateHz', config.targetSampleRateHz, ...
                'callbackAgeMs', ones(count, 1), ...
                'longitudinalFiltered', longitudinal, ...
                'longitudinalJerk', zerosColumn, ...
                'lateralFiltered', zerosColumn, 'lateralJerk', zerosColumn, ...
                'verticalFiltered', zerosColumn, 'verticalJerk', zerosColumn, ...
                'yawRateFiltered', zerosColumn, 'segmentId', segmentId, ...
                'dataValid', true(count, 1), 'outlierReplaced', false(count, 1));
        end
    end
end
