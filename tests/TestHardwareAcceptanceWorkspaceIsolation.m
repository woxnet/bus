classdef TestHardwareAcceptanceWorkspaceIsolation < matlab.unittest.TestCase
    properties
        Root
        TemporaryDirectory
    end
    methods(TestClassSetup)
        function setup(testCase)
            testCase.Root=fileparts(fileparts(mfilename('fullpath')));
            addpath(fullfile(testCase.Root,'src'),fullfile(testCase.Root,'tests'));
            testCase.TemporaryDirectory=tempname; mkdir(testCase.TemporaryDirectory);
            testCase.addTeardown(@()rmdir(testCase.TemporaryDirectory,'s'));
        end
    end
    methods(Test)
        function startupPreservesCallerProjectRoot(testCase)
            projectRoot="sentinel"; %#ok<NASGU>
            run(fullfile(testCase.Root,'startup.m'));
            testCase.verifyEqual(projectRoot,"sentinel");
        end
        function startupPreservesCallerCleanupVariables(testCase)
            controllerCleanup="sentinel"; imuCleanup="sentinel"; %#ok<NASGU>
            run(fullfile(testCase.Root,'startup.m'));
            testCase.verifyEqual(controllerCleanup,"sentinel");
            testCase.verifyEqual(imuCleanup,"sentinel");
        end
        function fullAcceptanceDoesNotRunNestedScripts(testCase)
            source=string(fileread(fullfile(testCase.Root,'src', ...
                'runFullImuHardwareAcceptance.m')));
            testCase.verifyFalse(contains(source,'run('));
        end
        function sequentialMockRunsHaveIndependentCleanup(testCase)
            probe=FullAcceptanceProbe(testCase.TemporaryDirectory);
            options=struct('Dependencies',probe.dependencies(), ...
                'ArtifactDirectory',testCase.TemporaryDirectory);
            first=runFullImuHardwareAcceptance(options);
            testCase.verifyTrue(first.success); testCase.verifyEqual(probe.CleanupCalls,3);
            testCase.verifyEqual(first.checkoutCommit,probe.Commit);
            testCase.verifyEqual(first.imuBrick2Source,"mock/ImuBrick2.m");
            testCase.verifyTrue(first.imuBrick2MethodsValid);
            testCase.verifyTrue(first.controllerMethodsValid);
            testCase.verifyTrue(first.monitorMethodsValid);
            testCase.verifyFalse(first.matlabRestartRequired);
            second=runFullImuHardwareAcceptance(options);
            testCase.verifyTrue(second.success); testCase.verifyEqual(probe.CleanupCalls,6);
            testCase.verifyEqual([probe.CalibrationCalls probe.RuntimeCalls probe.RealtimeCalls], ...
                [2 2 2]);
        end
        function calibrationFailureStopsLaterPhases(testCase)
            probe=FullAcceptanceProbe(testCase.TemporaryDirectory); probe.FailCalibration=true;
            options=struct('Dependencies',probe.dependencies(), ...
                'ArtifactDirectory',testCase.TemporaryDirectory);
            combined=runFullImuHardwareAcceptance(options);
            testCase.verifyFalse(combined.success);
            testCase.verifyEqual(combined.failurePhase,"installation_calibration");
            testCase.verifyTrue(combined.infrastructureFailure);
            testCase.verifyEqual(probe.CalibrationCalls,1);
            testCase.verifyEqual(probe.RuntimeCalls,0); testCase.verifyEqual(probe.RealtimeCalls,0);
            testCase.verifyFalse(isfield(combined,'runtimeReport'));
            testCase.verifyTrue(isfile(combined.jsonFile));
        end
        function unknownCommitStopsBeforeHardwarePhases(testCase)
            probe=FullAcceptanceProbe(testCase.TemporaryDirectory);
            dependencies=probe.dependencies();
            dependencies.getCommit=@()getImuAcceptanceCommit(@(~)deal(1,''));
            combined=runFullImuHardwareAcceptance(struct( ...
                'Dependencies',dependencies, ...
                'ArtifactDirectory',testCase.TemporaryDirectory));
            testCase.verifyFalse(combined.success);
            testCase.verifyEqual(combined.failurePhase,"bootstrap");
            testCase.verifyTrue(combined.infrastructureFailure);
            testCase.verifyEqual([probe.CalibrationCalls probe.RuntimeCalls probe.RealtimeCalls], ...
                [0 0 0]);
            testCase.verifyTrue(any(contains(combined.errors, ...
                'IMU:AcceptanceCommitUnknown')));
        end
        function staleClassBootstrapRequiresRestart(testCase)
            probe=FullAcceptanceProbe(testCase.TemporaryDirectory);
            dependencies=probe.dependencies();
            api=probe.api(); api.controllerMethodsValid=false;
            api.matlabRestartRequired=true;
            dependencies.assertClassApi=@()api;
            combined=runFullImuHardwareAcceptance(struct( ...
                'Dependencies',dependencies, ...
                'ArtifactDirectory',testCase.TemporaryDirectory));
            testCase.verifyEqual(combined.failurePhase,"bootstrap");
            testCase.verifyTrue(combined.infrastructureFailure);
            testCase.verifyTrue(combined.matlabRestartRequired);
            testCase.verifyEqual(probe.CalibrationCalls,0);
        end
        function publicFunctionsDoNotContaminateBaseWorkspace(testCase)
            sentinel="unchanged"; assignin('base','acceptanceWorkspaceSentinel',sentinel);
            testCase.addTeardown(@()evalin('base','clear acceptanceWorkspaceSentinel'));
            probe=FullAcceptanceProbe(testCase.TemporaryDirectory);
            runFullImuHardwareAcceptance(struct('Dependencies',probe.dependencies(), ...
                'ArtifactDirectory',testCase.TemporaryDirectory));
            testCase.verifyEqual(evalin('base','acceptanceWorkspaceSentinel'),sentinel);
        end
        function exampleScriptsAreThinWrappers(testCase)
            files={'run_installation_calibration_hardware_acceptance.m', ...
                'run_realtime_hardware_acceptance.m','run_full_imu_hardware_acceptance.m'};
            for index=1:numel(files)
                source=string(fileread(fullfile(testCase.Root,'examples',files{index})));
                testCase.verifyFalse(contains(source,'onCleanup'));
                testCase.verifyFalse(contains(source,'projectRoot'));
            end
        end
    end
end
