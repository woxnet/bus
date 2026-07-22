classdef TestImuInstallationCalibrationVerification < matlab.unittest.TestCase
    methods (TestClassSetup)
        function paths(testCase)
            root=fileparts(fileparts(mfilename('fullpath'))); addpath(fullfile(root,'src'),fullfile(root,'tests'));
            testCase.addTeardown(@()rmpath(fullfile(root,'src'),fullfile(root,'tests')));
        end
    end
    methods (Test)
        function acceptsAlignedCandidate(testCase)
            imu=MockImuBrick2([MockImuBrick2.createStationarySequence(1); ...
                MockImuBrick2.createForwardAccelerationSequence(1,eye(3),1)]);
            report=verifyImuInstallationCalibration(imu,createTestImuCalibration(true), ...
                testCase.options(),struct('sleep',@(~)[]));
            testCase.verifyTrue(report.success); testCase.verifyGreaterThan(report.forwardAccelerationMean,0);
            testCase.verifyEqual(report.meanGravityVehicle,[0 0 -9.81],'AbsTol',1e-10);
        end
        function rejectsReversedForwardAxis(testCase)
            imu=MockImuBrick2([MockImuBrick2.createStationarySequence(1); ...
                MockImuBrick2.createForwardAccelerationSequence(1,eye(3),-1)]);
            report=verifyImuInstallationCalibration(imu,createTestImuCalibration(true), ...
                testCase.options(),struct('sleep',@(~)[]));
            testCase.verifyFalse(report.success); testCase.verifyLessThan(report.forwardAccelerationMean,0);
        end
        function rejectsStationaryTilt(testCase)
            bad=MockImuBrick2.makeSample([1 0 -9.7],[0 0 0],[0 0 0]);
            forward=MockImuBrick2.createForwardAccelerationSequence(1,eye(3),1);
            report=verifyImuInstallationCalibration(MockImuBrick2([bad;forward]), ...
                createTestImuCalibration(true),testCase.options(),struct('sleep',@(~)[]));
            testCase.verifyFalse(report.success);
        end
    end
    methods (Access=private)
        function options=options(~)
            options=getImuInstallationCalibrationWorkflowConfig();
            options.verificationStationarySeconds=.02; options.verificationForwardSeconds=.02;
        end
    end
end
