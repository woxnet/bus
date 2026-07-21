classdef TestDrivingAnalysisPersistence < matlab.unittest.TestCase
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
        function matWriteFailureIsTransactional(testCase)
            directory = testCase.session();
            fileSystem = struct('WriteMat', ...
                @(varargin)error('Test:InjectedMatFailure', 'Injected MAT failure.'));
            result = testCase.analyzeWithFileSystem(directory, fileSystem);
            testCase.verifyAtomicFailure(directory, result, "Injected MAT failure");
        end

        function eventsJsonWriteFailureIsTransactional(testCase)
            directory = testCase.session();
            fileSystem = struct('WriteJson', @(filename,value) ...
                testCase.writeJsonMaybeFail(filename, value, 'events.json'));
            result = testCase.analyzeWithFileSystem(directory, fileSystem);
            testCase.verifyAtomicFailure(directory, result, "events.json");
        end

        function summaryJsonWriteFailureIsTransactional(testCase)
            directory = testCase.session();
            fileSystem = struct('WriteJson', @(filename,value) ...
                testCase.writeJsonMaybeFail(filename, value, 'summary.json'));
            result = testCase.analyzeWithFileSystem(directory, fileSystem);
            testCase.verifyAtomicFailure(directory, result, "summary.json");
        end

        function successfulTransactionContainsFinalSuccessfulResult(testCase)
            directory = testCase.session();
            result = analyzeImuSession(directory, struct('AllowSynthetic', true));
            testCase.verifyTrue(result.success, strjoin(result.errors, ' '));
            testCase.verifyEmpty(result.errors);
            testCase.verifyTrue(isfolder(fullfile(directory, 'analysis')));
            testCase.verifyFalse(isfolder(fullfile(directory, 'analysis.inprogress')));
            testCase.verifyTrue(isfile(result.resultMatFile));
            testCase.verifyTrue(isfile(result.eventsJsonFile));
            testCase.verifyTrue(isfile(result.summaryJsonFile));
            saved = load(result.resultMatFile, 'result');
            testCase.verifyTrue(saved.result.success);
            testCase.verifyEmpty(saved.result.errors);
            testCase.verifyEqual(result.success, isempty(result.errors));
        end

        function outputDirectoryCanBeInjected(testCase)
            directory = testCase.session();
            output = fullfile(testCase.TemporaryDirectory, 'custom-output');
            result = analyzeImuSession(directory, struct( ...
                'AllowSynthetic', true, 'OutputDirectory', output));
            testCase.verifyTrue(result.success, strjoin(result.errors, ' '));
            testCase.verifyEqual(result.analysisDirectory, string(output));
            testCase.verifyTrue(isfolder(output));
            testCase.verifyFalse(isfolder(fullfile(directory, 'analysis')));
        end

        function requestedPlotsAreIncludedAndReadable(testCase)
            directory = testCase.session();
            result = analyzeImuSession(directory, struct( ...
                'AllowSynthetic', true, 'SavePlots', true));
            testCase.verifyTrue(result.success, strjoin(result.errors, ' '));
            testCase.verifyTrue(isfile(result.diagnosticPlotPngFile));
            testCase.verifyTrue(isfile(result.diagnosticPlotFigFile));
            info = imfinfo(result.diagnosticPlotPngFile);
            testCase.verifyGreaterThan(info.Width, 0);
        end

        function sampleRateMismatchHasStableDiagnostic(testCase)
            directory = testCase.session();
            testCase.setSampleRate(directory, 40);
            result = analyzeImuSession(directory, struct( ...
                'AllowSynthetic', true, 'SaveAnalysis', false));
            testCase.verifyFalse(result.success);
            testCase.verifyFalse(result.loadReport.sampleRateMatchesAnalysis);
            testCase.verifyTrue(any(contains(result.errors, ...
                "IMU:SessionSampleRateMismatch")));
            testCase.verifyEqual(result.success, isempty(result.errors));
        end

        function customTargetRateIsPassedToLoader(testCase)
            directory = testCase.session();
            testCase.setSampleRate(directory, 40);
            config = getDrivingAnalysisConfig();
            config.targetSampleRateHz = 40;
            result = analyzeImuSession(directory, struct( ...
                'AllowSynthetic', true, 'SaveAnalysis', false, 'Config', config));
            testCase.verifyTrue(result.success, strjoin(result.errors, ' '));
            testCase.verifyTrue(result.loadReport.sampleRateMatchesAnalysis);
            testCase.verifyEqual(result.processed.sampleRateHz, 40);
            testCase.verifyEqual(result.success, isempty(result.errors));
        end
    end
    methods (Access = private)
        function directory = session(testCase)
            directory = createSyntheticDrivingSession( ...
                testCase.TemporaryDirectory, "braking");
        end

        function result = analyzeWithFileSystem(~, directory, fileSystem)
            result = analyzeImuSession(directory, struct( ...
                'AllowSynthetic', true, 'FileSystem', fileSystem));
        end

        function verifyAtomicFailure(testCase, directory, result, message)
            testCase.verifyFalse(result.success);
            testCase.verifyNotEmpty(result.errors);
            testCase.verifyTrue(any(contains(result.errors, message)));
            testCase.verifyEqual(result.success, isempty(result.errors));
            testCase.verifyFalse(isfolder(fullfile(directory, 'analysis')));
            testCase.verifyFalse(isfolder(fullfile(directory, 'analysis.inprogress')));
        end

        function writeJsonMaybeFail(~, filename, value, target)
            if endsWith(filename, target)
                error('Test:InjectedJsonFailure', ...
                    'Injected failure for %s.', target);
            end
            fileId = fopen(filename, 'w'); assert(fileId >= 0);
            cleanup = onCleanup(@()fclose(fileId));
            fprintf(fileId, '%s', jsonencode(value, 'PrettyPrint', true));
            clear cleanup;
        end

        function setSampleRate(testCase, directory, sampleRateHz)
            callbackPeriodMs = 1000 / sampleRateHz;
            for name = ["metadata.json", "summary.json"]
                filename = fullfile(directory, name);
                value = jsondecode(fileread(filename));
                value.sampleRateHz = sampleRateHz;
                value.callbackPeriodMs = callbackPeriodMs;
                testCase.writeJson(filename, value);
            end
        end

        function writeJson(~, filename, value)
            fileId = fopen(filename, 'w'); assert(fileId >= 0);
            cleanup = onCleanup(@()fclose(fileId));
            fprintf(fileId, '%s', jsonencode(value, 'PrettyPrint', true));
            clear cleanup;
        end
    end
end
