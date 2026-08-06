classdef TestBusDrivingSystemController < matlab.unittest.TestCase
    methods(TestClassSetup)
        function setup(~), root=fileparts(fileparts(mfilename('fullpath'))); addpath(fullfile(root,'src'),fullfile(root,'tests')); end
    end
    methods(Test)
        function missingCalibrationWaitsForOperator(testCase)
            probe=SystemControllerProbe(); c=BusDrivingSystemController(struct(),probe.getDependencies());
            testCase.addTeardown(@()delete(c)); c.startSystem();
            testCase.verifyEqual(c.State,"CALIBRATION_REQUIRED"); testCase.verifyEqual(probe.CalibrationStarts,0);
        end
        function explicitCalibrationUsesExistingController(testCase)
            probe=SystemControllerProbe(); c=BusDrivingSystemController(struct(),probe.getDependencies());
            testCase.addTeardown(@()delete(c)); c.startSystem(); c.startCalibration();
            testCase.verifyEqual(probe.CalibrationStarts,1); testCase.verifyEqual(c.State,"CALIBRATING");
            probe.CalibrationController.complete(); testCase.verifyEqual(c.State,"READY");
        end
        function realtimeHappyPathStopsSafely(testCase)
            probe=SystemControllerProbe(); probe.HasCalibration=true;
            c=BusDrivingSystemController(struct(),probe.getDependencies()); testCase.addTeardown(@()delete(c));
            states=strings(0,1); c.OnStateChanged=@(~,s)capture(s);
            c.startSystem(); c.startRealtime(); summary=c.stopRealtime();
            testCase.verifyTrue(summary.success); testCase.verifyEqual(c.State,"STOPPED");
            testCase.verifyTrue(all(ismember(["READY","STREAMING","QUIESCING","DRAINING_TAIL","FINALIZING_RECORDING","RELEASING_STREAM","STOPPED"],states)));
            function capture(status), states(end+1,1)=status.lifecycleState; end
        end
        function callbackFailureIsIsolated(testCase)
            probe=SystemControllerProbe(); c=BusDrivingSystemController(struct(),probe.getDependencies());
            testCase.addTeardown(@()delete(c)); c.OnStateChanged=@(~,~)error('Test:Callback','failure');
            warningState=warning('off','IMU:SystemControllerCallbackFailed'); cleanup=onCleanup(@()warning(warningState)); %#ok<NASGU>
            c.startSystem(); testCase.verifyEqual(c.State,"CALIBRATION_REQUIRED");
        end
    end
end
