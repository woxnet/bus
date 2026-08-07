classdef TestBusDrivingSystemIntegrity < matlab.unittest.TestCase
    methods(TestClassSetup)
        function setup(~)
            root=fileparts(fileparts(mfilename('fullpath')));
            addpath(fullfile(root,'src'),fullfile(root,'tests'));
        end
    end
    methods(Test)
        function forwardSampleHotPathIsSnapshotAndCommitFree(testCase)
            probe=SystemControllerProbe(); probe.HasCalibration=true;
            controller=BusDrivingSystemController(struct(),probe.getDependencies());
            testCase.addTeardown(@()delete(controller)); controller.startSystem(); controller.startRealtime();
            telemetryCallbacks=0; controller.OnTelemetry=@(~,~)countTelemetry();
            sample=struct('elapsedSeconds',0,'dataQuality',1);
            for index=1:1000
                sample.elapsedSeconds=index/50;
                probe.Monitor.OnSample(probe.Monitor,sample);
            end
            testCase.verifyEqual(controller.TelemetryHub.SamplesIngested,1000);
            testCase.verifyEqual(telemetryCallbacks,0);
            testCase.verifyEqual(probe.CommitCalls,1);
            source=string(fileread(which('BusDrivingSystemController')));
            body=extractBetween(source,'function forwardSample(obj,sample)','function forwardEventStarted');
            testCase.verifyFalse(contains(body,'getSnapshot'));
            testCase.verifyFalse(contains(body,'getCommit'));
            testCase.verifyFalse(contains(body,'emitTelemetry'));
            function countTelemetry(), telemetryCallbacks=telemetryCallbacks+1; end
        end
        function repeatedSnapshotsArePure(testCase)
            probe=SystemControllerProbe(); controller=BusDrivingSystemController(struct(),probe.getDependencies());
            testCase.addTeardown(@()delete(controller)); controller.startSystem();
            before=controller.TelemetryHub.getCounters();
            for index=1:1000, controller.getTelemetrySnapshot(); end
            after=controller.TelemetryHub.getCounters();
            testCase.verifyEqual(after,before); testCase.verifyEqual(probe.CommitCalls,1);
        end
        function lifecycleLogDeduplicatesIdenticalState(testCase)
            hub=BusDrivingSystemTelemetryHub(); status=struct('lifecycleState',"READY", ...
                'currentStage',"Result",'stageProgress',1,'message',"Ready",'severity',"info");
            for index=1:1000, hub.ingestState(status); end
            testCase.verifyEqual(numel(hub.getLog()),1);
            status.message="Still ready"; hub.ingestState(status);
            testCase.verifyEqual(numel(hub.getLog()),2);
        end
        function calibrationResultPreservesActivationRollbackAndCancellation(testCase)
            hub=BusDrivingSystemTelemetryHub(); rotation=[0 -1 0;1 0 0;0 0 1];
            result=struct('verificationPerformed',true,'verificationPassed',false,'verificationScore',.4, ...
                'activationAttempted',true,'activationVerified',false,'rollbackAttempted',true, ...
                'rollbackSucceeded',true,'finalFile',"final.mat",'workingFile',"work.mat", ...
                'backupFile',"backup.mat",'cancelReason',"operator",'errors',"error",'warnings',"warning", ...
                'rotationVehicleFromSensor',rotation,'bias',[1 2 3],'qualityScore',.8);
            hub.ingestCalibrationResult(result); actual=hub.getSnapshot().calibration;
            names=fieldnames(result);
            for index=1:numel(names), testCase.verifyEqual(actual.(names{index}),result.(names{index})); end
        end
        function callbackAndLatestSamplesAreRobust(testCase)
            hub=BusDrivingSystemTelemetryHub(); hub.ingestMonitorStatus(struct('callbackStats',[]));
            sensor=struct('x',1); vehicle=struct('x',2); processed=struct('x',3,'callbackAgeMs',7);
            hub.ingestMonitorStatus(struct('callbackStats',struct(), ...
                'latestSensorSample',sensor,'latestVehicleSample',vehicle,'latestProcessedSample',processed));
            snapshot=hub.getSnapshot(); testCase.verifyEqual(snapshot.latestSensorSample,sensor);
            testCase.verifyEqual(snapshot.latestVehicleSample,vehicle); testCase.verifyEqual(snapshot.latestProcessedSample,processed);
        end
        function acceptanceAndNormalizedJournalAreRetained(testCase)
            hub=BusDrivingSystemTelemetryHub(); result=struct('success',true,'failurePhase',"", ...
                'runtimeSuccess',true,'realtimeSuccess',true,'observerWarnings',"observer warning");
            hub.ingestAcceptanceResult(result);
            hub.ingestStage(struct('type',"stage_progress",'stage',"runtime_fifo",'progress',.5,'message',"live"));
            hub.ingestWarning(struct('message',"one",'code',1));
            hub.ingestWarning(struct('message',"two",'details',struct('x',2)));
            snapshot=hub.getSnapshot(); testCase.verifyTrue(snapshot.acceptance.success);
            required={'timestamp','severity','source','stage','type','message','payload'};
            testCase.verifyTrue(all(isfield(snapshot.log,required)));
            testCase.verifyTrue(any(string({snapshot.log.stage})=="runtime_fifo"));
        end
        function activeEventsAreUniqueByDetectorType(testCase)
            hub=BusDrivingSystemTelemetryHub();
            hub.ingestEventStarted(struct('type',"BRAKING_CANDIDATE",'value',1));
            hub.ingestEventStarted(struct('type',"BRAKING_CANDIDATE",'value',2));
            snapshot=hub.getSnapshot(); testCase.verifyEqual(numel(snapshot.activeEvents),1);
            testCase.verifyEqual(snapshot.activeEvents.value,2);
        end
        function fiftyHertzHistoryCapacityIsFifteenHundred(testCase)
            config=getBusDrivingSystemDashboardConfig(); config.signalHistorySeconds=30; config.sampleRateHz=50;
            hub=BusDrivingSystemTelemetryHub(config); sample=struct('elapsedSeconds',0);
            for index=1:1600, sample.elapsedSeconds=index/50; hub.ingestSample(sample); end
            testCase.verifyEqual(numel(hub.getSignalHistory()),1500);
        end
        function controllerCloseAndRestartOwnImuResources(testCase)
            probe=SystemControllerProbe(); probe.HasCalibration=true;
            controller=BusDrivingSystemController(struct(),probe.getDependencies());
            controller.startSystem(); first=probe.Imus(1); controller.startRealtime(); controller.stopRealtime();
            controller.startSystem(); testCase.verifyEqual(first.DisconnectCalls,1);
            second=probe.Imus(2); controller.close(); controller.close();
            testCase.verifyEqual(second.DisconnectCalls,1); testCase.verifyTrue(controller.IsClosed);
            testCase.verifyFalse(controller.IsConnected);
        end
        function unifiedCalibrationDisablesLegacyWindow(testCase)
            source=string(fileread(which('BusDrivingSystemController')));
            testCase.verifyTrue(contains(source,'workflowOptions.enableDashboard=false'));
            testCase.verifyFalse(contains(source,'saveSystemSnapshot'));
        end
        function acceptanceProgressControlsPipelineAndSummary(testCase)
            probe=SystemControllerProbe(); dependencies=probe.getDependencies(); dependencies.runAcceptance=@runAcceptance;
            controller=BusDrivingSystemController(struct(),dependencies); testCase.addTeardown(@()delete(controller));
            observedStages=strings(0,1); controller.OnStageProgress=@(~,value)capture(value);
            controller.runFullAcceptance(); snapshot=controller.getTelemetrySnapshot();
            testCase.verifyTrue(any(observedStages=="runtime_fifo"));
            testCase.verifyTrue(snapshot.acceptance.success);
            testCase.verifyTrue(snapshot.acceptance.runtimeSuccess);
            dashboardSource=string(fileread(which('BusDrivingSystemDashboard')));
            testCase.verifyTrue(contains(dashboardSource,'summary=s.acceptance'));
            function result=runAcceptance(options)
                options.Observer(struct('timestamp',datetime('now','TimeZone','UTC'), ...
                    'type',"stage_progress",'stage',"runtime_fifo",'state',"RUNNING", ...
                    'progress',.5,'message',"Runtime FIFO live progress",'payload',struct()));
                result=struct('success',true,'runtimeSuccess',true,'realtimeSuccess',true);
            end
            function capture(value)
                if isstruct(value) && isfield(value,'stage'), observedStages(end+1,1)=string(value.stage); end
            end
        end
    end
end
