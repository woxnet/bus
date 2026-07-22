classdef TestImuAcceptanceClassApi < matlab.unittest.TestCase
    methods(TestClassSetup)
        function setup(~)
            root=fileparts(fileparts(mfilename('fullpath')));
            addpath(fullfile(root,'src'));
        end
    end
    methods(Test)
        function currentClassApisPass(testCase)
            diagnostics=assertImuAcceptanceClassApi();
            testCase.verifyTrue(diagnostics.imuBrick2MethodsValid);
            testCase.verifyTrue(diagnostics.controllerMethodsValid);
            testCase.verifyTrue(diagnostics.monitorMethodsValid);
            testCase.verifyFalse(diagnostics.matlabRestartRequired);
        end
        function missingReleaseOwnerDetectedBeforeConnection(testCase)
            options=testCase.options("releaseStreamOwner");
            testCase.verifyError(@()assertImuAcceptanceClassApi(options), ...
                'IMU:StaleMatlabClassDefinition');
        end
        function missingControllerCloseDetectedBeforeCalibration(testCase)
            options=testCase.options("close");
            testCase.verifyError(@()assertImuAcceptanceClassApi(options), ...
                'IMU:StaleMatlabClassDefinition');
        end
        function staleErrorContainsRecoveryInstructions(testCase)
            options=testCase.options("getStats");
            try
                assertImuAcceptanceClassApi(options);
                testCase.assertFail('Expected stale class definition error.');
            catch exception
                testCase.verifyEqual(exception.identifier,'IMU:StaleMatlabClassDefinition');
                testCase.verifyTrue(contains(exception.message, ...
                    'MATLAB has an older class definition loaded.'));
                testCase.verifyTrue(contains(exception.message, ...
                    'Close IMU objects and restart MATLAB.'));
                testCase.verifyTrue(contains(exception.message, ...
                    'Verify the checkout commit before retrying.'));
            end
        end
        function unknownGitCommitFailsClosed(testCase)
            testCase.verifyError(@()getImuAcceptanceCommit( ...
                @(~)deal(1,'')),'IMU:AcceptanceCommitUnknown');
        end
    end
    methods(Access=private)
        function options=options(~,missingMethod)
            options=struct();
            options.MethodListFunction=@methodList;
            options.WhichFunction=@(name)"mock/"+string(name)+".m";
            function values=methodList(name)
                switch string(name)
                    case "ImuBrick2"
                        values=["claimStreamOwner","releaseStreamOwner","quiesce", ...
                            "clearCallbackBuffer","drainCallbackSamples","getCallbackStats"];
                    case "ImuInstallationCalibrationController"
                        values=["runBlocking","cancel","close","getStatus"];
                    otherwise
                        values=["start","stop","getStats"];
                end
                values(values==missingMethod)=[];
            end
        end
    end
end
