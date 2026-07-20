classdef TestImuDiagnostics < matlab.unittest.TestCase
%TESTIMUDIAGNOSTICS Hardware-independent tests for IMU diagnostics.
    properties
        ProjectRoot
    end

    methods (TestClassSetup)
        function addSourcePath(testCase)
            testCase.ProjectRoot = fileparts(fileparts(mfilename('fullpath')));
            sourcePath = fullfile(testCase.ProjectRoot, 'src');
            addpath(sourcePath);
            testCase.addTeardown(@()rmpath(sourcePath));
        end
    end

    methods (Test)
        function configuredUidIsCorrect(testCase)
            config = getImuConfig();
            expectedUid = join(["6d", "KiM3"], "");
            testCase.verifyEqual(config.uid, expectedUid);
            testCase.verifyEqual(config.host, "localhost");
            testCase.verifyEqual(config.port, 4223);
            testCase.verifyEqual(config.sampleRateHz, 50);
            testCase.verifyEqual(config.callbackPeriodMs, 20);
        end

        function missingJarIsReported(testCase)
            options = struct('jarFile', [tempname, '.jar']);
            report = diagnoseImuBrick2(options);
            testCase.verifyFalse(report.success);
            testCase.verifyFalse(report.jarAvailable);
            testCase.verifyNotEmpty(report.errors);
        end

        function unavailableBrickDaemonIsReported(testCase)
            imu = MockImuBrick2();
            options = testCase.optionsFor(imu);
            options.daemonProbe = @(~,~)false;
            report = diagnoseImuBrick2(options);
            testCase.verifyFalse(report.success);
            testCase.verifyFalse(report.brickDaemonConnected);
            testCase.verifyFalse(report.imuConnected);
        end

        function readFailureIsReported(testCase)
            imu = MockImuBrick2();
            imu.FailureReads = 1;
            report = diagnoseImuBrick2(testCase.optionsFor(imu));
            testCase.verifyFalse(report.success);
            testCase.verifyTrue(report.imuConnected);
            testCase.verifyEqual(report.samplesRead, 0);
            testCase.verifyNotEmpty(report.errors);
        end

        function validMockReport(testCase)
            samples = MockImuBrick2.createStationarySequence(20, eye(3));
            imu = MockImuBrick2(samples);
            report = diagnoseImuBrick2(testCase.optionsFor(imu));
            testCase.verifyTrue(report.success);
            testCase.verifyEqual(report.samplesRead, 20);
            testCase.verifyEqual(report.meanGravityMagnitude, 9.81, 'AbsTol', 1e-10);
            testCase.verifyEqual(report.meanAngularVelocity, [0 0 0], 'AbsTol', 1e-10);
            testCase.verifyEqual(report.temperature, 20);
            testCase.verifyEmpty(report.errors);
        end

        function nanIsDetected(testCase)
            sample = MockImuBrick2.makeSample([0 0 -9.81], [0 0 0], [0 0 0]);
            sample.gravity(2) = NaN;
            report = diagnoseImuBrick2(testCase.optionsFor(MockImuBrick2(sample)));
            testCase.verifyFalse(report.success);
            testCase.verifyNotEmpty(report.errors);
        end

        function invalidGravityIsDetected(testCase)
            sample = MockImuBrick2.makeSample([0 0 -4], [0 0 0], [0 0 0]);
            report = diagnoseImuBrick2(testCase.optionsFor(MockImuBrick2(sample)));
            testCase.verifyFalse(report.success);
            testCase.verifyEqual(report.samplesRead, 20);
            testCase.verifyEqual(report.meanGravityMagnitude, 4, 'AbsTol', 1e-10);
            testCase.verifyNotEmpty(report.errors);
        end
    end

    methods (Access = private)
        function options = optionsFor(testCase, imu)
            options.jarFile = fullfile(testCase.ProjectRoot, 'lib', 'Tinkerforge.jar');
            options.javaBindingsCheck = @(~,~)true;
            options.daemonProbe = @(~,~)true;
            options.imuFactory = @(~)imu;
            options.sampleCount = 20;
            options.paceReads = false;
        end
    end
end
