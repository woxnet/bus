classdef TestBusDrivingSystemDashboard < matlab.unittest.TestCase
    methods(TestClassSetup)
        function setup(~), root=fileparts(fileparts(mfilename('fullpath'))); addpath(fullfile(root,'src')); end
    end
    methods(Test)
        function configCapsRefreshRate(testCase)
            config=getBusDrivingSystemDashboardConfig(); testCase.verifyEqual(config.refreshHz,5); testCase.verifyLessThanOrEqual(config.maximumRefreshHz,10);
        end
        function dashboardNeverConsumesOrReprocessesSamples(testCase)
            source=string(fileread(which('BusDrivingSystemDashboard')));
            testCase.verifyFalse(contains(source,'drainCallbackSamples'));
            testCase.verifyFalse(contains(source,'applyMountCalibration'));
            testCase.verifyFalse(contains(source,'RealtimeEventState'));
        end
        function exposesAllTabs(testCase)
            source=SyntheticBusDrivingSystemController(); dashboard=BusDrivingSystemDashboard(source);
            testCase.addTeardown(@()delete(dashboard)); testCase.verifyEqual(numel(dashboard.getTabNames()),8);
        end
    end
end
