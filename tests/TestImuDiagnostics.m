classdef TestImuDiagnostics < matlab.unittest.TestCase
%TESTIMUDIAGNOSTICS Tests for data-source validation and hardware preflight.
    properties
        ProjectRoot
        TemporaryDirectory
        FakeJarFile
    end

    methods (TestClassSetup)
        function setup(testCase)
            testCase.ProjectRoot = fileparts(fileparts(mfilename('fullpath')));
            addpath(fullfile(testCase.ProjectRoot, 'src'));
            testCase.TemporaryDirectory = tempname;
            mkdir(testCase.TemporaryDirectory);
            testCase.addTeardown(@()rmdir(testCase.TemporaryDirectory, 's'));
            testCase.FakeJarFile = fullfile(testCase.TemporaryDirectory, 'fake.jar');
            writeBytes(testCase.FakeJarFile, uint8(['P','K',3,4]));
        end
    end

    methods (Test)
        function trackedJarAbsentFromIndex(testCase)
            [status, output] = system(sprintf('git -C "%s" ls-files -- lib/Tinkerforge.jar', ...
                testCase.ProjectRoot));
            testCase.verifyEqual(status, 0);
            testCase.verifyEmpty(strtrim(output));
        end

        function zipWithoutTinkerforgeClassesRejected(testCase)
            dummy = fullfile(testCase.TemporaryDirectory, 'dummy.txt');
            writeBytes(dummy, uint8('dummy'));
            archive = fullfile(testCase.TemporaryDirectory, 'dummy.zip');
            zip(archive, dummy);
            testCase.verifyWarning(@()loadTinkerforgeBindings(archive), ...
                'IMU:TinkerforgeBindingsUnavailable');
            warning('off', 'IMU:TinkerforgeBindingsUnavailable');
            cleanup = onCleanup(@()warning('on', 'IMU:TinkerforgeBindingsUnavailable'));
            status = loadTinkerforgeBindings(archive);
            testCase.verifyFalse(status.available);
            testCase.verifyFalse(status.classesAvailable);
            clear cleanup;
        end

        function mockDiagnosticNeedsNoJar(testCase)
            report = diagnoseImuDataSource(testCase.validMock());
            testCase.verifyTrue(report.success);
            testCase.verifyEqual(report.samplesRead, 100);
        end

        function sensorFusionModeApplied(testCase)
            imu = testCase.hardwareMock();
            report = diagnoseImuBrick2(imu, testCase.dependencies());
            testCase.verifyTrue(report.success);
            testCase.verifyEqual(report.sensorFusionMode, 2);
            testCase.verifyTrue(report.sensorFusionModeValid);
        end

        function wrongSensorFusionModeRejected(testCase)
            imu = testCase.hardwareMock();
            imu.SensorFusionMode = 1;
            imu.IgnoreSensorFusionSet = true;
            report = diagnoseImuBrick2(imu, testCase.dependencies());
            testCase.verifyFalse(report.success);
            testCase.verifyFalse(report.sensorFusionModeValid);
        end

        function callbackPeriodBugFirmwareRejected(testCase)
            imu = testCase.hardwareMock();
            imu.Identity.firmwareVersion = [2 0 11];
            report = diagnoseImuBrick2(imu, testCase.dependencies());
            testCase.verifyFalse(report.success);
            testCase.verifyFalse(report.firmwareVersionValid);
            testCase.verifyEqual(report.callbackSamplesRead, 100);
        end

        function callbackHasUniqueSequences(testCase)
            report = diagnoseImuBrick2(testCase.hardwareMock(), testCase.dependencies());
            testCase.verifyTrue(report.success);
            testCase.verifyEqual(report.callbackSamplesRead, 100);
            testCase.verifyTrue(report.callbackSequenceAdvances);
            testCase.verifyEqual(report.callbackMissingSequences, 0);
            testCase.verifyEqual(report.callbackDroppedSamples, 0);
            testCase.verifyLessThanOrEqual(report.callbackMaximumAgeMs, 40);
        end

        function missingCallbackSequenceRejected(testCase)
            imu = testCase.hardwareMock(); imu.CallbackSequenceStep = 2;
            report = diagnoseImuBrick2(imu, testCase.dependencies());
            testCase.verifyFalse(report.success);
            testCase.verifyGreaterThan(report.callbackMissingSequences, 0);
        end

        function staleCallbackRejected(testCase)
            imu = testCase.hardwareMock(); imu.CallbackTimestampOffsetSeconds = 0.1;
            report = diagnoseImuBrick2(imu, testCase.dependencies());
            testCase.verifyFalse(report.success);
            testCase.verifyGreaterThan(report.callbackMaximumAgeMs, 40);
        end

        function droppedCallbackRejected(testCase)
            imu = testCase.hardwareMock(); imu.InjectedDroppedSamples = 1;
            report = diagnoseImuBrick2(imu, testCase.dependencies());
            testCase.verifyFalse(report.success);
            testCase.verifyEqual(report.callbackDroppedSamples, 1);
        end

        function staleSessionSequenceRejected(testCase)
            imu = testCase.hardwareMock(); imu.CallbackSequenceStart = 100;
            report = diagnoseImuBrick2(imu, testCase.dependencies());
            testCase.verifyFalse(report.success);
            testCase.verifyFalse(report.callbackRestartClean);
        end

        function latestAndSequentialDrainSemantics(testCase)
            imu = testCase.hardwareMock(); imu.start(1); pause(0.01);
            newest = imu.latest();
            testCase.verifyEqual(newest.sequenceNumber, imu.LastCallbackSequence);
            testCase.verifyEqual(imu.CallbackBufferedCount, uint64(0));
            imu.stop(); imu.start(1); pause(0.005);
            samples = imu.drainCallbackSamples(3);
            sequences = cellfun(@(sample)double(sample.sequenceNumber), samples);
            testCase.verifyEqual(sequences, (1:numel(samples)).');
        end

        function stopStartClearsOldCallbacks(testCase)
            imu = testCase.hardwareMock(); imu.start(1); pause(0.005);
            old = imu.nextCallbackSample(); %#ok<NASGU>
            imu.stop(); imu.start(1); pause(0.002);
            fresh = imu.nextCallbackSample();
            testCase.verifyEqual(fresh.sequenceNumber, uint64(1));
            testCase.verifyEqual(fresh.callbackDroppedBeforeSample, uint64(0));
        end

        function frozenCallbackRejected(testCase)
            imu = testCase.hardwareMock(); imu.FreezeCallback = true;
            report = diagnoseImuBrick2(imu, testCase.dependencies());
            testCase.verifyFalse(report.success);
            testCase.verifyLessThan(report.callbackSamplesRead, 100);
        end

        function slowCallbackRejected(testCase)
            imu = testCase.hardwareMock(); imu.CallbackPeriodScale = 2;
            report = diagnoseImuBrick2(imu, testCase.dependencies());
            testCase.verifyFalse(report.success);
            testCase.verifyLessThan(report.callbackFrequencyHz, 40);
        end

        function fastCallbackRejected(testCase)
            imu = testCase.hardwareMock(); imu.CallbackPeriodScale = 0.5;
            report = diagnoseImuBrick2(imu, testCase.dependencies());
            testCase.verifyFalse(report.success);
            testCase.verifyGreaterThan(report.callbackFrequencyHz, 60);
        end

        function previousCallbackPeriodRestored(testCase)
            imu = testCase.hardwareMock(); imu.start(37);
            report = diagnoseImuBrick2(imu, testCase.dependencies());
            testCase.verifyTrue(report.success);
            testCase.verifyTrue(imu.IsStreaming);
            testCase.verifyEqual(imu.StreamingPeriodMs, 37);
        end

        function stoppedStreamRemainsStopped(testCase)
            imu = testCase.hardwareMock();
            report = diagnoseImuBrick2(imu, testCase.dependencies());
            testCase.verifyTrue(report.success);
            testCase.verifyFalse(imu.IsStreaming);
        end

        function identityUidMismatchRejected(testCase)
            imu = testCase.hardwareMock(); imu.Identity.uid = "wrong";
            report = diagnoseImuBrick2(imu, testCase.dependencies());
            testCase.verifyFalse(report.success);
            testCase.verifyFalse(report.configuredUidMatches);
        end

        function missingFieldRejected(testCase)
            sample = rmfield(MockImuBrick2.makeSample([0 0 -9.81], [0 0 0], [0 0 0]), 'gravity');
            report = diagnoseImuDataSource(MockImuBrick2(sample));
            testCase.verifyFalse(report.success);
            testCase.verifyFalse(report.fieldsValid);
        end

        function nonFiniteValueRejected(testCase)
            sample = MockImuBrick2.makeSample([NaN 0 -9.81], [0 0 0], [0 0 0]);
            report = diagnoseImuDataSource(MockImuBrick2(sample));
            testCase.verifyFalse(report.success);
            testCase.verifyFalse(report.valuesFinite);
        end

        function temporaryReadErrorsRecover(testCase)
            imu = testCase.validMock(); imu.FailureReads = [2 3];
            report = diagnoseImuDataSource(imu);
            testCase.verifyTrue(report.success);
            testCase.verifyEqual(report.readErrors, 2);
        end
    end

    methods (Access = private)
        function imu = validMock(~)
            imu = MockImuBrick2(MockImuBrick2.createStationarySequence(100, eye(3)));
        end

        function imu = hardwareMock(~)
            imu = MockImuBrick2(MockImuBrick2.createStationarySequence(20, eye(3)));
            imu.RepeatLast = true;
        end

        function dependencies = dependencies(testCase)
            dependencies.jarFile = testCase.FakeJarFile;
            dependencies.bindingsLoader = @(~)struct('available', true, ...
                'errors', strings(0,1));
            dependencies.daemonProbe = @(~,~)true;
            dependencies.imuFactory = @(~)testCase.hardwareMock();
            dependencies.pauseFunction = @pause;
            dependencies.fusionSettleDelaySeconds = 0;
        end
    end
end

function writeBytes(filename, bytes)
fileId = fopen(filename, 'wb');
assert(fileId >= 0);
cleanup = onCleanup(@()fclose(fileId));
fwrite(fileId, bytes, 'uint8');
clear cleanup;
end
