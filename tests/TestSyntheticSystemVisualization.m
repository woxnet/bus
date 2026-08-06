classdef TestSyntheticSystemVisualization < matlab.unittest.TestCase
    methods(TestClassSetup)
        function setup(~), root=fileparts(fileparts(mfilename('fullpath'))); addpath(fullfile(root,'src'),fullfile(root,'examples')); end
    end
    methods(Test)
        function demoCoversSixtySecondsWithoutHardware(testCase)
            [controller,dashboard,summary]=run_synthetic_system_visualization_demo(false);
            testCase.addTeardown(@()delete(dashboard)); snapshot=controller.getTelemetrySnapshot();
            testCase.verifyTrue(summary.success); testCase.verifyGreaterThanOrEqual(summary.durationSeconds,60);
            testCase.verifyEqual(numel(snapshot.recentEvents),3); testCase.verifyNotEmpty(snapshot.warnings);
            testCase.verifyEqual(snapshot.mode,"synthetic");
        end
    end
end
