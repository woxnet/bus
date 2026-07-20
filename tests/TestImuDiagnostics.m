classdef TestImuDiagnostics < matlab.unittest.TestCase
%TESTIMUDIAGNOSTICS Hardware-independent tests for IMU diagnostics.
    properties
        SourcePath
        TemporaryDirectory
        FakeJarFile
    end

    methods (TestClassSetup)
        function addSourcePath(testCase)
            root = fileparts(fileparts(mfilename('fullpath')));
            testCase.SourcePath = fullfile(root, 'src');
            addpath(testCase.SourcePath);
            testCase.addTeardown(@()rmpath(testCase.SourcePath));
            testCase.TemporaryDirectory = tempname;
            mkdir(testCase.TemporaryDirectory);
            testCase.addTeardown(@()rmdir(testCase.TemporaryDirectory, 's'));
            testCase.FakeJarFile = fullfile(testCase.TemporaryDirectory, 'valid-signature.jar');
            writeBytes(testCase.FakeJarFile, uint8(['P','K',3,4]));
        end
    end

    methods (Test)
        function configurationContainsExpectedUid(testCase)
            config = getImuConfig();
            testCase.verifyEqual(config.uid, join(["6d", "KiM3"], ""));
        end

        function configurationContainsExpectedPort(testCase)
            testCase.verifyEqual(getImuConfig().port, 4223);
        end

        function configurationContainsExpectedFrequency(testCase)
            config = getImuConfig();
            testCase.verifyEqual(config.sampleRateHz, 50);
            testCase.verifyEqual(config.samplePeriodSeconds, 0.02);
            testCase.verifyEqual(config.callbackPeriodMs, 20);
        end

        function emptyJarIsRejected(testCase)
            filename = fullfile(testCase.TemporaryDirectory, 'empty.jar');
            writeBytes(filename, uint8([]));
            result = setupTinkerforgeBindings(filename);
            testCase.verifyFalse(result.success);
            testCase.verifyEqual(result.fileSizeBytes, 0);
            testCase.verifyFalse(result.jarSignatureValid);
        end

        function invalidJarSignatureIsRejected(testCase)
            filename = fullfile(testCase.TemporaryDirectory, 'not-a-jar.bin');
            writeBytes(filename, uint8('not a jar'));
            result = setupTinkerforgeBindings(filename);
            testCase.verifyFalse(result.success);
            testCase.verifyGreaterThan(result.fileSizeBytes, 0);
            testCase.verifyFalse(result.jarSignatureValid);
        end

        function missingJarAppearsInReport(testCase)
            dependencies = testCase.dependencies();
            dependencies.jarFile = fullfile(testCase.TemporaryDirectory, 'missing.jar');
            report = diagnoseImuBrick2(testCase.validMock(), dependencies);
            testCase.verifyFalse(report.success);
            testCase.verifyFalse(report.jarAvailable);
            testCase.verifyEqual(report.jarSizeBytes, 0);
            testCase.verifyFalse(report.jarSignatureValid);
        end

        function successfulMockReport(testCase)
            imu = testCase.validMock();
            report = testCase.diagnose(imu);
            testCase.verifyTrue(report.success);
            testCase.verifyEqual(report.samplesRequested, 100);
            testCase.verifyEqual(report.samplesRead, 100);
            testCase.verifyTrue(report.fieldsValid);
            testCase.verifyTrue(report.valuesFinite);
            testCase.verifyTrue(report.timestampsAdvance);
            testCase.verifyEqual(report.meanGravityMagnitude, 9.81, 'AbsTol', 1e-10);
            testCase.verifyGreaterThanOrEqual(report.averageReadFrequencyHz, 40);
            testCase.verifyLessThanOrEqual(report.averageReadFrequencyHz, 60);
        end

        function missingGravityField(testCase)
            sample = rmfield(testCase.validSample(), 'gravity');
            report = testCase.diagnose(MockImuBrick2(sample));
            testCase.verifyFalse(report.success);
            testCase.verifyFalse(report.fieldsValid);
            testCase.verifyTrue(any(contains(report.errors, "gravity")));
        end

        function missingQuaternionField(testCase)
            sample = rmfield(testCase.validSample(), 'quaternion');
            report = testCase.diagnose(MockImuBrick2(sample));
            testCase.verifyFalse(report.success);
            testCase.verifyFalse(report.fieldsValid);
            testCase.verifyTrue(any(contains(report.errors, "quaternion")));
        end

        function nanValue(testCase)
            sample = testCase.validSample(); sample.gravity(1) = NaN;
            report = testCase.diagnose(MockImuBrick2(sample));
            testCase.verifyFalse(report.success);
            testCase.verifyFalse(report.valuesFinite);
        end

        function infiniteValue(testCase)
            sample = testCase.validSample(); sample.angularVelocity(2) = Inf;
            report = testCase.diagnose(MockImuBrick2(sample));
            testCase.verifyFalse(report.success);
            testCase.verifyFalse(report.valuesFinite);
        end

        function invalidVectorSize(testCase)
            sample = testCase.validSample(); sample.gravity = [0 -9.81];
            report = testCase.diagnose(MockImuBrick2(sample));
            testCase.verifyFalse(report.success);
            testCase.verifyFalse(report.fieldsValid);
        end

        function invalidGravityMagnitude(testCase)
            samples = repmat(MockImuBrick2.makeSample([0 0 -4], [0 0 0], [0 0 0]), 100, 1);
            samples = MockImuBrick2.withAdvancingTimestamps(samples);
            report = testCase.diagnose(MockImuBrick2(samples));
            testCase.verifyFalse(report.success);
            testCase.verifyEqual(report.meanGravityMagnitude, 4, 'AbsTol', 1e-10);
        end

        function readErrorThenRecovery(testCase)
            imu = testCase.validMock(); imu.FailureReads = [5 6];
            report = testCase.diagnose(imu);
            testCase.verifyTrue(report.success);
            testCase.verifyEqual(report.samplesRead, 100);
            testCase.verifyEqual(report.readErrors, 2);
            testCase.verifyNotEmpty(report.warnings);
        end

        function consecutiveReadErrorLimit(testCase)
            imu = testCase.validMock(); imu.FailureReads = 1:4;
            report = testCase.diagnose(imu);
            testCase.verifyFalse(report.success);
            testCase.verifyEqual(report.readErrors, 4);
            testCase.verifyEqual(report.samplesRead, 0);
        end

        function timestampsDoNotAdvance(testCase)
            samples = repmat(testCase.validSample(), 100, 1);
            report = testCase.diagnose(MockImuBrick2(samples));
            testCase.verifyFalse(report.success);
            testCase.verifyFalse(report.timestampsAdvance);
        end

        function insufficientSamples(testCase)
            samples = MockImuBrick2.createStationarySequence(5, eye(3));
            imu = MockImuBrick2(samples); imu.RepeatLast = false;
            report = testCase.diagnose(imu);
            testCase.verifyFalse(report.success);
            testCase.verifyEqual(report.samplesRead, 5);
            testCase.verifyNotEmpty(report.errors);
        end

        function externalMockIsNotDisconnected(testCase)
            imu = testCase.validMock();
            report = testCase.diagnose(imu);
            testCase.verifyTrue(report.success);
            testCase.verifyEqual(imu.DisconnectCount, 0);
        end

        function frequencyBelowMinimumIsRejected(testCase)
            overrides = struct('samplePeriodSeconds', 0.03);
            report = testCase.diagnose(testCase.validMock(), overrides);
            testCase.verifyFalse(report.success);
            testCase.verifyLessThan(report.averageReadFrequencyHz, 40);
        end

        function frequencyAboveMaximumIsRejected(testCase)
            overrides = struct('samplePeriodSeconds', 0.01);
            report = testCase.diagnose(testCase.validMock(), overrides);
            testCase.verifyFalse(report.success);
            testCase.verifyGreaterThan(report.averageReadFrequencyHz, 60);
        end

        function internallyCreatedImuIsDisconnected(testCase)
            imu = testCase.validMock();
            dependencies = testCase.dependencies();
            dependencies.imuFactory = @(~)imu;
            report = diagnoseImuBrick2([], dependencies);
            testCase.verifyTrue(report.success);
            testCase.verifyEqual(imu.DisconnectCount, 1);
        end

        function missingJarLoaderDoesNotBlockMockTests(testCase)
            missing = fullfile(testCase.TemporaryDirectory, 'startup-missing.jar');
            testCase.verifyWarning(@()loadTinkerforgeBindings(missing), ...
                'IMU:TinkerforgeBindingsUnavailable');
            report = testCase.diagnose(testCase.validMock());
            testCase.verifyTrue(report.success);
        end
    end

    methods (Access = private)
        function imu = validMock(~)
            imu = MockImuBrick2(MockImuBrick2.createStationarySequence(100, eye(3)));
        end

        function sample = validSample(~)
            sample = MockImuBrick2.makeSample([0 0 -9.81], [0 0 0], [0 0 0]);
        end

        function report = diagnose(testCase, imu, configOverrides)
            if nargin < 3, configOverrides = struct(); end
            dependencies = testCase.dependencies();
            dependencies.configOverrides = configOverrides;
            report = diagnoseImuBrick2(imu, dependencies);
        end

        function dependencies = dependencies(testCase)
            dependencies.jarFile = testCase.FakeJarFile;
            dependencies.javaBindingsCheck = @(~,~)true;
            dependencies.daemonProbe = @(~,~)true;
            dependencies.imuFactory = @(~)testCase.validMock();
            dependencies.pauseFunction = @pause;
            dependencies.configOverrides = struct();
        end
    end
end

function writeBytes(filename, bytes)
fileId = fopen(filename, 'wb');
assert(fileId >= 0, 'Could not create test file.');
cleanup = onCleanup(@()fclose(fileId));
fwrite(fileId, bytes, 'uint8');
clear cleanup;
end
