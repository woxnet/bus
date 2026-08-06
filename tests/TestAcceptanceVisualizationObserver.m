classdef TestAcceptanceVisualizationObserver < matlab.unittest.TestCase
    methods(TestClassSetup)
        function setup(~), root=fileparts(fileparts(mfilename('fullpath'))); addpath(fullfile(root,'src'),fullfile(root,'tests')); end
    end
    methods(Test)
        function observerReceivesAllFullAcceptanceStages(testCase)
            directory=tempname; mkdir(directory); testCase.addTeardown(@()rmdir(directory,'s'));
            probe=FullAcceptanceProbe(directory); stages=strings(0,1);
            options=struct('Dependencies',probe.dependencies(),'ArtifactDirectory',directory,'Observer',@observe);
            result=runFullImuHardwareAcceptance(options); testCase.verifyTrue(result.success);
            required=["bootstrap","class_api","commit_check","installation_calibration","runtime_fifo","realtime_monitor","summary_validation","artifact_save"];
            testCase.verifyTrue(all(ismember(required,stages)));
            function observe(event), stages(end+1,1)=event.stage; end
        end
        function observerFailureDoesNotFailAcceptance(testCase)
            directory=tempname; mkdir(directory); testCase.addTeardown(@()rmdir(directory,'s'));
            probe=FullAcceptanceProbe(directory); options=struct('Dependencies',probe.dependencies(), ...
                'ArtifactDirectory',directory,'Observer',@(~)error('Test:Observer','failure'));
            state=warning('off','IMU:AcceptanceObserverFailed'); cleanup=onCleanup(@()warning(state)); %#ok<NASGU>
            result=runFullImuHardwareAcceptance(options); testCase.verifyTrue(result.success); testCase.verifyNotEmpty(result.observerWarnings);
        end
    end
end
