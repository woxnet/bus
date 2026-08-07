classdef TestBusDrivingSystemVisualizationLifecycle < matlab.unittest.TestCase
    methods(TestClassSetup)
        function setup(~), root=fileparts(fileparts(mfilename('fullpath'))); addpath(fullfile(root,'src'),fullfile(root,'tests')); end
    end
    methods(Test)
        function safeStopStagesReachTelemetry(testCase)
            probe=SystemControllerProbe(); probe.HasCalibration=true; c=BusDrivingSystemController(struct(),probe.getDependencies());
            testCase.addTeardown(@()delete(c)); c.startSystem(); c.startRealtime(); c.stopRealtime();
            log=c.TelemetryHub.getLog(); messages=string({log.message});
            testCase.verifyTrue(any(contains(messages,"QUIESCING"))); testCase.verifyTrue(any(contains(messages,"DRAINING_TAIL")));
        end
        function dashboardFailureCannotStopMonitor(testCase)
            probe=SystemControllerProbe(); probe.HasCalibration=true; c=BusDrivingSystemController(struct(),probe.getDependencies());
            testCase.addTeardown(@()delete(c)); c.OnTelemetry=@(~,~)error('Test:Dashboard','render');
            warningState=warning('off','IMU:SystemControllerCallbackFailed'); cleanup=onCleanup(@()warning(warningState)); %#ok<NASGU>
            c.startSystem(); c.startRealtime(); testCase.verifyTrue(probe.Monitor.IsRunning);
        end
    end
end
