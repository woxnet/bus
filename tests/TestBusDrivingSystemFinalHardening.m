classdef TestBusDrivingSystemFinalHardening < matlab.unittest.TestCase
    methods(TestClassSetup)
        function setup(~)
            root=fileparts(fileparts(mfilename('fullpath')));
            addpath(fullfile(root,'src'),fullfile(root,'tests'),fullfile(root,'examples'));
        end
    end
    methods(Test)
        function closeEntryPointsUseRequestClose(testCase)
            source=string(fileread(which('BusDrivingSystemDashboard')));
            testCase.verifyTrue(contains(source,"'CloseRequestFcn',@(~,~)obj.requestClose()"));
            testCase.verifyTrue(contains(source,"@(~,~)obj.requestClose()"));
            testCase.verifyFalse(contains(source,"@(~,~)obj.close()"));
        end
        function realtimeCloseChoicesAreSafe(testCase)
            [controller,probe]=testCase.readyController(); controller.startRealtime();
            dashboard=BusDrivingSystemDashboard(controller,[],struct('confirmClose',@leave));
            result=dashboard.requestClose();
            testCase.verifyEqual(result,"detached"); testCase.verifyTrue(probe.Monitor.IsRunning);
            testCase.verifyFalse(controller.IsClosed); testCase.verifyTrue(dashboard.IsClosed);
            cancelled=BusDrivingSystemDashboard(controller,[],struct('confirmClose',@cancel));
            testCase.verifyEqual(cancelled.requestClose(),"cancelled");
            testCase.verifyFalse(cancelled.IsClosed); testCase.verifyTrue(probe.Monitor.IsRunning);
            stopped=BusDrivingSystemDashboard(controller,[],struct('confirmClose',@stop));
            testCase.verifyEqual(stopped.requestClose(),"closed"); testCase.verifyTrue(controller.IsClosed);
            delete(dashboard); delete(cancelled); delete(stopped);
            function choice=leave(~,~,~,~,~), choice='Leave system running'; end
            function choice=cancel(~,~,~,~,~), choice='Cancel'; end
            function choice=stop(~,~,~,~,~), choice='Stop system and close'; end
        end
        function calibrationCloseChoicesAreSafe(testCase)
            probe=SystemControllerProbe(); controller=BusDrivingSystemController(struct(),probe.getDependencies());
            controller.startSystem(); controller.startCalibration();
            dashboard=BusDrivingSystemDashboard(controller,[],struct('confirmClose',@leave));
            result=dashboard.requestClose();
            testCase.verifyEqual(result,"detached"); testCase.verifyTrue(probe.CalibrationController.IsRunning);
            testCase.verifyFalse(controller.IsClosed);
            cancelled=BusDrivingSystemDashboard(controller,[],struct('confirmClose',@cancel));
            testCase.verifyEqual(cancelled.requestClose(),"cancelled"); testCase.verifyFalse(cancelled.IsClosed);
            closed=BusDrivingSystemDashboard(controller,[],struct('confirmClose',@closeCalibration));
            testCase.verifyEqual(closed.requestClose(),"closed"); testCase.verifyTrue(controller.IsClosed);
            testCase.verifyFalse(probe.CalibrationController.IsRunning);
            delete(dashboard); delete(cancelled); delete(closed);
            function choice=leave(~,~,~,~,~), choice='Leave calibration running'; end
            function choice=cancel(~,~,~,~,~), choice='Cancel'; end
            function choice=closeCalibration(~,~,~,~,~), choice='Cancel calibration and close'; end
        end
        function leaveAcceptanceRunningOnlyDetachesDashboard(testCase)
            probe=SystemControllerProbe(); dependencies=probe.getDependencies(); dashboard=[]; closeResult=""; observed=false;
            choiceValue='Cancel close';
            dependencies.runAcceptance=@acceptance;
            controller=BusDrivingSystemController(struct(),dependencies);
            dashboard=BusDrivingSystemDashboard(controller,[],struct('confirmClose',@leave));
            controller.runFullAcceptance();
            testCase.verifyEqual(closeResult,"detached"); testCase.verifyTrue(observed);
            testCase.verifyTrue(dashboard.IsClosed); testCase.verifyFalse(controller.IsClosed);
            testCase.verifyEqual(controller.State,"COMPLETED"); delete(dashboard); controller.close();
            function result=acceptance(options)
                testCase.verifyEqual(dashboard.requestClose(),"cancelled");
                testCase.verifyFalse(dashboard.IsClosed); testCase.verifyFalse(controller.IsClosed);
                choiceValue='Leave acceptance running';
                closeResult=dashboard.requestClose();
                options.Observer(struct('type',"stage_progress",'stage',"runtime_fifo", ...
                    'state',"RUNNING",'progress',.5,'message',"continued",'payload',struct()));
                observed=true; result=struct('success',true);
            end
            function choice=leave(~,~,~,~,~), choice=choiceValue; end
        end
        function controllerCloseRejectsActiveAcceptance(testCase)
            probe=SystemControllerProbe(); dependencies=probe.getDependencies(); caught="";
            dependencies.runAcceptance=@acceptance; controller=BusDrivingSystemController(struct(),dependencies);
            controller.runFullAcceptance(); testCase.verifyEqual(caught,"IMU:AcceptanceInProgress"); controller.close();
            function result=acceptance(~)
                try, controller.close(); catch exception, caught=string(exception.identifier); end
                result=struct('success',true);
            end
        end
        function acceptanceMutualExclusionIsCentralized(testCase)
            probe=SystemControllerProbe(); controller=BusDrivingSystemController(struct(),probe.getDependencies());
            controller.startSystem(); controller.startCalibration();
            testCase.verifyError(@()controller.runFullAcceptance(),'IMU:SystemBusy'); controller.close();

            probe=SystemControllerProbe(); dependencies=probe.getDependencies(); repeated="";
            dependencies.runAcceptance=@recursive; controller=BusDrivingSystemController(struct(),dependencies);
            controller.runFullAcceptance(); testCase.verifyEqual(repeated,"IMU:AcceptanceAlreadyRunning"); controller.close();
            function result=recursive(~)
                try, controller.runFullAcceptance(); catch exception, repeated=string(exception.identifier); end
                result=struct('success',true);
            end
        end
        function acceptanceIsRejectedDuringSafeStop(testCase)
            [controller,~]=testCase.readyController(); caught=strings(0,1);
            controller.OnStateChanged=@observe; controller.startRealtime(); controller.stopRealtime();
            testCase.verifyTrue(any(caught=="IMU:SystemBusy")); controller.close();
            function observe(~,status)
                if any(string(status.lifecycleState)==["STOPPING","QUIESCING","DRAINING_TAIL","FINALIZING_RECORDING","RELEASING_OWNER"])
                    try, controller.runFullAcceptance(); catch exception, caught(end+1,1)=string(exception.identifier); end
                end
            end
        end
        function actionPredicatesFollowLifecycle(testCase)
            probe=SystemControllerProbe(); controller=BusDrivingSystemController(struct(),probe.getDependencies());
            status=controller.getStatus(); actions=status.actions;
            testCase.verifyTrue(actions.canStartSystem); testCase.verifyTrue(actions.canRunAcceptance);
            controller.startSystem(); status=controller.getStatus(); actions=status.actions;
            testCase.verifyTrue(actions.canStartCalibration); testCase.verifyFalse(actions.canRunAcceptance);
            controller.startCalibration(); status=controller.getStatus(); actions=status.actions;
            testCase.verifyTrue(actions.canConfirmCalibration); testCase.verifyFalse(actions.canStartRealtime);
            probe.CalibrationController.complete(); status=controller.getStatus(); actions=status.actions;
            testCase.verifyTrue(actions.canStartRealtime); testCase.verifyTrue(actions.canRunAcceptance);
            controller.startRealtime(); status=controller.getStatus(); actions=status.actions;
            testCase.verifyTrue(actions.canStopRealtime); testCase.verifyFalse(actions.canRunAcceptance);
            controller.stopRealtime(); status=controller.getStatus(); actions=status.actions;
            testCase.verifyTrue(actions.canRunAcceptance); controller.close();
            status=controller.getStatus(); testCase.verifyFalse(status.actions.canClose);
        end
        function failuresReachTelemetryExactlyOnce(testCase)
            phases=["bootstrap","class_api","imu_connection","preflight","calibration_start","monitor_start","acceptance"];
            for phase=phases, exercise(phase); end
            function exercise(phase)
                probe=SystemControllerProbe(); dependencies=probe.getDependencies();
                identifier="Test:"+phase; probe.HasCalibration=phase=="monitor_start";
                switch phase
                    case "bootstrap", dependencies.getCommit=@()fail(identifier);
                    case "class_api", dependencies.checkClassApi=@()fail(identifier);
                    case "imu_connection", dependencies.createImu=@()fail(identifier);
                    case "preflight", dependencies.runPreflight=@(~)fail(identifier);
                    case "calibration_start", dependencies.createCalibrationController=@(~)fail(identifier);
                    case "monitor_start", dependencies.createRealtimeMonitor=@(~,~)fail(identifier);
                    case "acceptance", dependencies.runAcceptance=@(~)fail(identifier);
                end
                controller=BusDrivingSystemController(struct(),dependencies); errorCount=0; stateCount=0; telemetryCount=0;
                controller.OnError=@(~,~)incrementError(); controller.OnStateChanged=@(~,status)incrementState(status);
                controller.OnTelemetry=@(~,snapshot)incrementTelemetry(snapshot);
                try
                    if phase=="acceptance", controller.runFullAcceptance();
                    else
                        controller.startSystem();
                        if phase=="calibration_start", controller.startCalibration(); end
                        if phase=="monitor_start", controller.startRealtime(); end
                    end
                catch exception
                    testCase.verifyEqual(string(exception.identifier),identifier);
                end
                snapshot=controller.getTelemetrySnapshot();
                testCase.verifyEqual(snapshot.lifecycleState,"FAILED",char(phase));
                testCase.verifyEqual(snapshot.severity,"error",char(phase));
                testCase.verifyEqual(errorCount,1,char(phase)); testCase.verifyEqual(stateCount,1,char(phase));
                testCase.verifyEqual(telemetryCount,1,char(phase)); controller.close();
                function value=fail(id), error(char(id),'Injected %s failure.',phase); value=[]; end
                function incrementError(), errorCount=errorCount+1; end
                function incrementState(status), if string(status.lifecycleState)=="FAILED", stateCount=stateCount+1; end, end
                function incrementTelemetry(snapshot), if string(snapshot.lifecycleState)=="FAILED", telemetryCount=telemetryCount+1; end, end
            end
        end
        function stageTimingUsesInjectedClockAndSeparatesRuns(testCase)
            clock=MutableUtcClock(datetime(2026,1,1,0,0,0,'TimeZone','UTC'));
            hub=BusDrivingSystemTelemetryHub([],@()clock.now());
            runStage("runtime_fifo",60); runStage("realtime_monitor",120);
            clock.advance(seconds(10)); hub.ingestStage(event("stage_started","runtime_fifo",0));
            clock.advance(seconds(20)); summary=hub.getSummarySnapshot();
            testCase.verifyEqual(summary.currentStageRecord.elapsedSeconds,20,'AbsTol',1e-9);
            hub.ingestStage(event("stage_completed","runtime_fifo",1));
            stages=hub.getStages(); runtime=stages(string({stages.stage})=="runtime_fifo");
            testCase.verifyEqual(numel(runtime),2); testCase.verifyNotEqual(runtime(1).stageRunId,runtime(2).stageRunId);
            function runStage(stage,duration)
                hub.ingestStage(event("stage_started",stage,0)); clock.advance(seconds(duration));
                summary=hub.getSummarySnapshot(); testCase.verifyEqual(summary.currentStageRecord.elapsedSeconds,duration,'AbsTol',1e-9);
                hub.ingestStage(event("stage_completed",stage,1)); record=hub.getStages(); record=record(end);
                testCase.verifyEqual(record.elapsedSeconds,duration,'AbsTol',1e-9); testCase.verifyFalse(isnat(record.completedAt));
                clock.advance(seconds(5));
            end
            function value=event(type,stage,progress)
                value=struct('type',type,'stage',stage,'state',"RUNNING",'progress',progress,'message',stage,'payload',struct());
            end
        end
        function telemetryRevisionsOnlyAdvanceForTheirModels(testCase)
            hub=BusDrivingSystemTelemetryHub(); before=hub.getCounters(); hub.ingestSample(struct('elapsedSeconds',0));
            afterSignal=hub.getCounters(); testCase.verifyEqual(afterSignal.signalRevision,before.signalRevision+1);
            testCase.verifyEqual(afterSignal.eventRevision,before.eventRevision);
            hub.ingestEventStarted(struct('type',"BRAKING_CANDIDATE")); afterEvent=hub.getCounters();
            testCase.verifyEqual(afterEvent.eventRevision,afterSignal.eventRevision+1);
            hub.ingestCalibration(struct('state',"READY")); hub.ingestAcceptanceResult(struct('success',true));
            final=hub.getSummarySnapshot(); testCase.verifyEqual(final.calibrationRevision,1);
            testCase.verifyEqual(final.acceptanceRevision,1); testCase.verifyGreaterThan(final.logRevision,0);
        end
    end
    methods(Access=private)
        function [controller,probe]=readyController(~)
            probe=SystemControllerProbe(); probe.HasCalibration=true;
            controller=BusDrivingSystemController(struct(),probe.getDependencies()); controller.startSystem();
        end
    end
end
