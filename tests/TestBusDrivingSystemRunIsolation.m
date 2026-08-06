classdef TestBusDrivingSystemRunIsolation < matlab.unittest.TestCase
    methods(TestClassSetup)
        function setup(~)
            root=fileparts(fileparts(mfilename('fullpath')));
            addpath(fullfile(root,'src'),fullfile(root,'tests'),fullfile(root,'examples'));
        end
    end
    methods(Test)
        function secondOperationRunStartsWithoutRunScopedTelemetry(testCase)
            probe=SystemControllerProbe(); probe.HasCalibration=true;
            controller=BusDrivingSystemController(struct(),probe.getDependencies());
            testCase.addTeardown(@()delete(controller));
            controller.startSystem(); firstRunId=controller.RunId; controller.startRealtime();
            sample=TestBusDrivingSystemRunIsolation.sample(1);
            probe.Monitor.OnSample(probe.Monitor,sample);
            event=struct('eventId',"first",'type',"BRAKING_CANDIDATE", ...
                'startElapsedSeconds',0,'durationSeconds',1);
            probe.Monitor.OnEventStarted(probe.Monitor,event);
            probe.Monitor.OnEventCompleted(probe.Monitor,event);
            controller.stopRealtime(); controller.TelemetryHub.ingestAcceptanceResult(struct('success',true));
            firstStages=controller.TelemetryHub.getStages(); firstStageIds=[firstStages.stageRunId];

            controller.startSystem(); snapshot=controller.getTelemetrySnapshot();
            testCase.verifyNotEqual(snapshot.runId,firstRunId);
            testCase.verifyEmpty(snapshot.signalHistory); testCase.verifyEmpty(snapshot.recentEvents);
            testCase.verifyEmpty(snapshot.activeEvents); testCase.verifyEmpty(fieldnames(snapshot.acceptance));
            testCase.verifyFalse(any(snapshot.completedStages=="Realtime"));
            secondStageIds=[snapshot.stageHistory.stageRunId];
            testCase.verifyEmpty(intersect(firstStageIds,secondStageIds));
        end
        function acceptanceStartsIndependentRunAndJournalIsTagged(testCase)
            clock=MutableUtcClock(datetime(2026,1,1,'TimeZone','UTC'));
            probe=SystemControllerProbe(); dependencies=probe.getDependencies(); dependencies.nowUtc=@()clock.now();
            dependencies.runAcceptance=@acceptance;
            controller=BusDrivingSystemController(struct(),dependencies); testCase.addTeardown(@()delete(controller));
            controller.runFullAcceptance(); first=controller.RunId; firstSequence=controller.RunSequence;
            controller.runFullAcceptance(); snapshot=controller.getTelemetrySnapshot();
            testCase.verifyNotEqual(snapshot.runId,first); testCase.verifyEqual(snapshot.runSequence,firstSequence+1);
            testCase.verifyEqual(snapshot.runMode,"acceptance"); testCase.verifyEqual(snapshot.runStartedAt,clock.now());
            testCase.verifyTrue(all(string({snapshot.log.runId})==snapshot.runId));
            testCase.verifyTrue(all(string({snapshot.stageHistory.runId})==snapshot.runId));
            testCase.verifyTrue(startsWith(snapshot.runId,"acceptance_"));
            function result=acceptance(options)
                options.Observer(struct('type',"stage_started",'stage',"runtime_fifo", ...
                    'state',"RUNNING",'progress',0,'message',"started",'payload',struct()));
                options.Observer(struct('type',"stage_completed",'stage',"runtime_fifo", ...
                    'state',"PASSED",'progress',1,'message',"complete",'payload',struct()));
                result=struct('success',true);
            end
        end
        function calibrationCancellationClosesEveryActivePhase(testCase)
            cases={"stationary",false;"forward",false;"verification",false;"stationary",true};
            for index=1:size(cases,1)
                utc=MutableUtcClock(datetime(2026,1,index,'TimeZone','UTC'));
                probe=SystemControllerProbe(); dependencies=probe.getDependencies(); dependencies.nowUtc=@()utc.now();
                controller=BusDrivingSystemController(struct(),dependencies); cleanup=onCleanup(@()delete(controller));
                controller.startSystem(); controller.startCalibration(); phase=cases{index,1};
                if phase~="stationary"
                    status=struct('state',upper(phase),'phase',phase,'progress',.5,'message',phase);
                    probe.CalibrationController.OnStateChanged(probe.CalibrationController,status);
                end
                if cases{index,2}, controller.confirmCurrentStep(); end
                utc.advance(seconds(4)); controller.cancel(); stages=controller.TelemetryHub.getStages();
                cancelled=stages(string({stages.state})=="CANCELLED"); testCase.verifyNotEmpty(cancelled);
                if phase=="verification", testCase.verifyTrue(any(string({cancelled.stage})=="Verification"));
                else, testCase.verifyTrue(any(string({cancelled.stage})=="Calibration")); end
                elapsed=[cancelled.elapsedSeconds]; utc.advance(seconds(20)); updated=controller.TelemetryHub.getStages();
                updated=updated(string({updated.state})=="CANCELLED");
                testCase.verifyEqual([updated.elapsedSeconds],elapsed,'AbsTol',1e-9);
                clear cleanup;
            end
        end
        function realtimeElapsedGrowsThenFreezesAfterStop(testCase)
            utc=MutableUtcClock(datetime(2026,2,1,'TimeZone','UTC'));
            probe=SystemControllerProbe(); probe.HasCalibration=true; dependencies=probe.getDependencies();
            dependencies.nowUtc=@()utc.now(); controller=BusDrivingSystemController(struct(),dependencies);
            testCase.addTeardown(@()delete(controller)); controller.startSystem(); controller.startRealtime();
            before=controller.getSummarySnapshot(); utc.advance(seconds(7)); during=controller.getSummarySnapshot();
            testCase.verifyEqual(before.currentStageRecord.stage,"Realtime");
            testCase.verifyGreaterThan(during.currentStageRecord.elapsedSeconds,before.currentStageRecord.elapsedSeconds);
            controller.stopRealtime(); stages=controller.TelemetryHub.getStages();
            realtime=stages(string({stages.stage})=="Realtime"); fixed=realtime(end).elapsedSeconds;
            testCase.verifyEqual(realtime(end).state,"PASSED"); testCase.verifyEqual(fixed,7,'AbsTol',1e-9);
            utc.advance(seconds(30)); stages=controller.TelemetryHub.getStages();
            realtime=stages(string({stages.stage})=="Realtime");
            testCase.verifyEqual(realtime(end).elapsedSeconds,fixed,'AbsTol',1e-9);
        end
        function syntheticUsesConfiguredFiftyHertzAndThirtySecondHistory(testCase)
            config=getBusDrivingSystemDashboardConfig(); config.sampleRateHz=50; config.signalHistorySeconds=30;
            controller=SyntheticBusDrivingSystemController(config); testCase.addTeardown(@()delete(controller));
            controller.startSimulation(60,1000); controller.waitForCompletion(2);
            snapshot=controller.getTelemetrySnapshot(); history=snapshot.signalHistory;
            testCase.verifyEqual(controller.TelemetryHub.SamplesIngested,3001);
            testCase.verifyEqual(numel(history),1500);
            testCase.verifyEqual(unique([history.effectiveFrequencyHz]),50);
            duration=history(end).elapsedSeconds-history(1).elapsedSeconds;
            testCase.verifyGreaterThanOrEqual(duration,29.9); testCase.verifyLessThanOrEqual(duration,30.1);
        end
        function dashboardClearsOldRunGraphicsAndTables(testCase)
            config=getBusDrivingSystemDashboardConfig(); config.maximumRenderMilliseconds=1e6;
            source=DashboardSnapshotProbe(config); dashboard=BusDrivingSystemDashboard(source,config,struct('createTimer',@createTimer));
            testCase.addTeardown(@()delete(dashboard)); dashboard.open();
            source.TelemetryHub.beginRun(struct('runId',"run-one"));
            source.TelemetryHub.ingestSample(TestBusDrivingSystemRunIsolation.sample(1));
            source.TelemetryHub.ingestSample(TestBusDrivingSystemRunIsolation.sample(2));
            event=struct('eventId',"one",'type',"BRAKING_CANDIDATE",'startElapsedSeconds',.02,'durationSeconds',1);
            source.TelemetryHub.ingestEventCompleted(event);
            dashboard.selectTab("Signals"); dashboard.render(); diagnostics=dashboard.getGraphicsDiagnostics();
            testCase.verifyNotEmpty(diagnostics.rawLines(1).XData);
            dashboard.selectTab("Events"); dashboard.render(); diagnostics=dashboard.getGraphicsDiagnostics();
            testCase.verifyNotEmpty(diagnostics.eventTable.Data);
            source.TelemetryHub.beginRun(struct('runId',"run-two")); dashboard.render();
            diagnostics=dashboard.getGraphicsDiagnostics();
            testCase.verifyEmpty(diagnostics.rawLines(1).XData); testCase.verifyEmpty(diagnostics.eventTable.Data);
            testCase.verifyFalse(diagnostics.detectorActivationObserved); testCase.verifyFalse(diagnostics.eventMarkerObserved);
            function value=createTimer(varargin), value=FakeRealtimeTimer(false,varargin{:}); end
        end
    end
    methods(Static,Access=private)
        function value=sample(index)
            value=struct('elapsedSeconds',index/50,'longitudinalRaw',1,'longitudinalFiltered',1, ...
                'lateralRaw',0,'lateralFiltered',0,'verticalRaw',0,'verticalFiltered',0, ...
                'yawRateRaw',0,'yawRateFiltered',0,'longitudinalJerk',0,'lateralJerk',0, ...
                'verticalJerk',0,'dataQuality',1,'callbackAgeMs',1,'effectiveFrequencyHz',50);
        end
    end
end
