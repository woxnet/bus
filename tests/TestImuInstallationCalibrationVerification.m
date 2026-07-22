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
        function rejectsConstantRotation(testCase)
            stationary=testCase.stationarySamples([0 0 2],[0 0 0]);
            report=testCase.verifySequence(stationary);
            testCase.verifyFalse(report.success);
            testCase.verifyGreaterThan(report.maximumStationaryAngularVelocity,1.5);
        end
        function rejectsShortAngularImpulse(testCase)
            angular=[0 0 0;0 0 0;0 0 3;0 0 0];
            stationary=testCase.stationarySamples(angular,zeros(4,3));
            report=testCase.verifySequence(stationary);
            testCase.verifyFalse(report.success); testCase.verifyEqual(report.maximumStationaryAngularVelocity,3);
        end
        function rejectsZeroMeanAngularVibration(testCase)
            angular=[0 0 2;0 0 -2;0 0 2;0 0 -2];
            report=testCase.verifySequence(testCase.stationarySamples(angular,zeros(4,3)));
            testCase.verifyFalse(report.success); testCase.verifyEqual(report.rmsStationaryAngularVelocity,2,'AbsTol',1e-12);
        end
        function rejectsZeroMeanLinearOscillation(testCase)
            linear=[.3 0 0;-.3 0 0;.3 0 0;-.3 0 0];
            report=testCase.verifySequence(testCase.stationarySamples(zeros(4,3),linear));
            testCase.verifyFalse(report.success); testCase.verifyEqual(report.maximumStationaryLinearAcceleration,.3,'AbsTol',1e-12);
        end
        function rejectsCancellingForwardYawAndLateralPeaks(testCase)
            stationary=testCase.stationarySamples(zeros(4,3),zeros(4,3));
            lateral=[.5;-.5;.5;-.5]; yaw=[8;-8;8;-8];
            forward=repmat(MockImuBrick2.makeSample([0 0 -9.81],[1 0 0],[0 0 0]),4,1);
            for index=1:4
                forward(index).linearAcceleration=[1 lateral(index) 0];
                forward(index).angularVelocity=[0 0 yaw(index)];
            end
            report=testCase.verifySequence(stationary,forward);
            testCase.verifyFalse(report.success);
            testCase.verifyEqual(report.maximumAbsoluteLateralAcceleration,.5,'AbsTol',1e-12);
            testCase.verifyEqual(report.maximumAbsoluteYawRate,8,'AbsTol',1e-12);
        end
    end
    methods (Access=private)
        function options=options(~)
            options=getImuInstallationCalibrationWorkflowConfig();
            options.verificationStationarySeconds=.02; options.verificationForwardSeconds=.02;
        end
        function samples=stationarySamples(~,angular,linear)
            if isvector(angular), angular=repmat(angular,4,1); end
            if isvector(linear), linear=repmat(linear,4,1); end
            samples=repmat(MockImuBrick2.makeSample([0 0 -9.81],[0 0 0],[0 0 0]),4,1);
            for index=1:4
                samples(index).angularVelocity=angular(index,:);
                samples(index).linearAcceleration=linear(index,:);
            end
        end
        function report=verifySequence(testCase,stationary,forward)
            if nargin<3, forward=MockImuBrick2.createForwardAccelerationSequence(4,eye(3),1); end
            imu=MockImuBrick2([stationary;forward]); options=testCase.options();
            options.verificationStationarySeconds=.08; options.verificationForwardSeconds=.08;
            report=verifyImuInstallationCalibration(imu,createTestImuCalibration(true), ...
                options,struct('sleep',@(~)[]));
        end
    end
end
