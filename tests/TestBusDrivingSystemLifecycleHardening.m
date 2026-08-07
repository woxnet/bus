classdef TestBusDrivingSystemLifecycleHardening < matlab.unittest.TestCase
    methods(TestClassSetup)
        function setup(~)
            root=fileparts(fileparts(mfilename('fullpath')));
            addpath(fullfile(root,'src'),fullfile(root,'tests'));
        end
    end
    methods(Test)
        function autonomousStopsFinalizeEveryStageExactlyOnce(testCase)
            reasons=["maximum_recording_duration","minimum_free_disk","maximum_session_bytes", ...
                "recorder_failure","callback_overflow"];
            for reason=reasons
                probe=SystemControllerProbe(); probe.HasCalibration=true;
                controller=BusDrivingSystemController(struct(),probe.getDependencies());
                cleanup=onCleanup(@()delete(controller)); %#ok<NASGU>
                callbacks=RealtimeCallbackProbe(); controller.OnStopped=@callbacks.stopped;
                controller.startSystem(); controller.startRealtime();
                before=controller.TelemetryHub.getStages();
                stoppingBefore=sum(string({before.stage})=="Stopping");
                resultBefore=sum(string({before.stage})=="Result");
                probe.Monitor.triggerAutonomousStop(reason);
                testCase.verifyEqual(controller.State,"STOPPED",char(reason));
                stages=controller.TelemetryHub.getStages();
                testCase.verifyStage(stages,"Realtime","PASSED");
                testCase.verifyStage(stages,"Recording","PASSED");
                testCase.verifyStage(stages,"Stopping","PASSED");
                testCase.verifyStage(stages,"Result","PASSED");
                testCase.verifyEqual(callbacks.StoppedCount,1,char(reason));
                controller.stopRealtime();
                stages=controller.TelemetryHub.getStages();
                testCase.verifyEqual(sum(string({stages.stage})=="Stopping")-stoppingBefore,1,char(reason));
                testCase.verifyEqual(sum(string({stages.stage})=="Result")-resultBefore,1,char(reason));
                testCase.verifyEqual(callbacks.StoppedCount,1,char(reason));
                clear cleanup;
            end
        end
        function failedMonitorClosesOperationWithoutPassedResult(testCase)
            probe=SystemControllerProbe(); probe.HasCalibration=true;
            controller=BusDrivingSystemController(struct(),probe.getDependencies());
            testCase.addTeardown(@()delete(controller));
            controller.startSystem(); controller.startRealtime();
            before=controller.TelemetryHub.getStages();
            resultBefore=sum(string({before.stage})=="Result");
            probe.Monitor.triggerFailure("injected recorder failure");
            testCase.verifyEqual(controller.State,"FAILED");
            testCase.verifyEqual(string(controller.LastError.message),"injected recorder failure");
            stages=controller.TelemetryHub.getStages();
            testCase.verifyStage(stages,"Realtime","FAILED");
            testCase.verifyStage(stages,"Recording","FAILED");
            testCase.verifyStage(stages,"Stopping","FAILED");
            result=stages(string({stages.stage})=="Result");
            testCase.verifyEqual(numel(result),resultBefore);
        end
        function acceptanceReleasesOperationHardwareOwnership(testCase)
            probe=SystemControllerProbe(); probe.HasCalibration=true;
            controller=BusDrivingSystemController(struct(),probe.getDependencies());
            testCase.addTeardown(@()delete(controller)); controller.startSystem();
            operationImu=controller.Imu;
            probe.AcceptanceAction=@accept;
            controller.runFullAcceptance();
            testCase.verifyEqual(operationImu.DisconnectCalls,1);
            testCase.verifyEmpty(controller.Imu);
            testCase.verifyFalse(controller.IsConnected);
            testCase.verifyEqual(controller.State,"COMPLETED");
            controller.startSystem();
            testCase.verifyNotEqual(controller.Imu,operationImu);
            testCase.verifyTrue(controller.IsConnected);
            function result=accept(~)
                testCase.verifyEqual(operationImu.DisconnectCalls,1);
                testCase.verifyFalse(controller.IsConnected);
                acceptanceImu=FakeSystemImu();
                activeConnections=double(operationImu.DisconnectCalls==0)+double(acceptanceImu.DisconnectCalls==0);
                testCase.verifyLessThanOrEqual(activeConnections,1);
                acceptanceImu.disconnect();
                result=struct('success',true);
            end
        end
        function journalKeepsControllerAcceptanceAndOperatorSources(testCase)
            operationProbe=SystemControllerProbe();
            operation=BusDrivingSystemController(struct(),operationProbe.getDependencies());
            testCase.addTeardown(@()delete(operation));
            operation.startSystem(); operation.startCalibration(); operation.confirmCurrentStep();
            operationLog=operation.TelemetryHub.getLog();

            acceptanceProbe=SystemControllerProbe();
            acceptance=BusDrivingSystemController(struct(),acceptanceProbe.getDependencies());
            testCase.addTeardown(@()delete(acceptance));
            acceptanceProbe.AcceptanceAction=@publishAcceptanceStage;
            acceptance.runFullAcceptance();
            operationLog=[operationLog; acceptance.TelemetryHub.getLog()]; %#ok<AGROW>
            sources=string({operationLog.source});
            testCase.verifyTrue(all(ismember(["controller","operator","acceptance"],sources)));
            function result=publishAcceptanceStage(options)
                event=struct('type',"stage_started",'stage',"acceptance probe", ...
                    'progress',0,'message',"acceptance started",'payload',struct());
                options.Observer(event); result=struct('success',true);
            end
        end
        function calibrationRequiredTracksVerification(testCase)
            probe=SystemControllerProbe();
            controller=BusDrivingSystemController(struct(),probe.getDependencies());
            testCase.addTeardown(@()delete(controller)); controller.startSystem();
            snapshot=controller.getTelemetrySnapshot();
            testCase.verifyTrue(snapshot.calibration.required);
            controller.startCalibration();
            probe.CalibrationController.complete();
            snapshot=controller.getTelemetrySnapshot();
            testCase.verifyFalse(snapshot.calibration.required);
        end
    end
    methods(Access=private)
        function verifyStage(testCase,stages,name,state)
            records=stages(string({stages.stage})==string(name));
            testCase.verifyNotEmpty(records,char(name));
            testCase.verifyEqual(string(records(end).state),string(state),char(name));
        end
    end
end
