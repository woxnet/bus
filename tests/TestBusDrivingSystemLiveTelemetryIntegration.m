classdef TestBusDrivingSystemLiveTelemetryIntegration < matlab.unittest.TestCase
    methods(TestClassSetup)
        function setup(~)
            root=fileparts(fileparts(mfilename('fullpath')));
            addpath(fullfile(root,'src'),fullfile(root,'tests'),fullfile(root,'examples'));
        end
    end
    methods(Test)
        function runtimeStatusRefreshesMetricsAndIsRateLimited(testCase)
            clock=MutableMonotonicClock(); probe=SystemControllerProbe(); probe.HasCalibration=true;
            dependencies=probe.getDependencies(); dependencies.monotonicClockStart=@()clock.start();
            dependencies.monotonicClockElapsed=@(token)clock.elapsed(token);
            controller=BusDrivingSystemController(struct(),dependencies); testCase.addTeardown(@()delete(controller));
            controller.startSystem(); controller.startRealtime(); monitor=probe.Monitor; monitor.resetStatusCalls();
            baseline=controller.RuntimeTelemetryRefreshCount; controller.refreshRealtimeTelemetry();
            testCase.verifyEqual(monitor.StatusCalls,0); testCase.verifyEqual(controller.RuntimeTelemetryRefreshCount,baseline);
            monitor.Received=120; monitor.Buffered=12; monitor.CallbackAgeMs=18; monitor.MaximumCallbackAgeMs=27;
            monitor.SamplesWritten=100; monitor.BytesWritten=4096; monitor.RecordingDurationSeconds=2.4;
            monitor.FreeDiskBytes=2^30; clock.advance(.2); controller.refreshRealtimeTelemetry();
            snapshot=controller.getSummarySnapshot(); testCase.verifyEqual(snapshot.callback.received,120);
            testCase.verifyEqual(snapshot.callback.buffered,12); testCase.verifyEqual(snapshot.callback.bufferCapacity,10);
            testCase.verifyEqual(snapshot.callback.currentCallbackAgeMs,18); testCase.verifyEqual(snapshot.callback.maximumCallbackAgeMs,27);
            testCase.verifyEqual(snapshot.recording.samplesWritten,100); testCase.verifyEqual(snapshot.recording.bytesWritten,4096);
            testCase.verifyEqual(snapshot.recording.durationSeconds,2.4); testCase.verifyEqual(snapshot.recording.freeDiskBytes,2^30);
            testCase.verifyEqual(monitor.DrainCalls,0); calls=monitor.StatusCalls;
            clock.advance(.19); controller.refreshRealtimeTelemetry(); testCase.verifyEqual(monitor.StatusCalls,calls);
            clock.advance(.01); controller.refreshRealtimeTelemetry(); testCase.verifyEqual(monitor.StatusCalls,calls+1);
        end
        function hundredThousandSamplesNeverQueryMonitorStatus(testCase)
            probe=SystemControllerProbe(); probe.HasCalibration=true;
            controller=BusDrivingSystemController(struct(),probe.getDependencies()); testCase.addTeardown(@()delete(controller));
            controller.startSystem(); controller.startRealtime(); monitor=probe.Monitor; monitor.resetStatusCalls();
            sample=struct('elapsedSeconds',0,'dataQuality',1);
            for index=1:100000
                sample.elapsedSeconds=index/50; monitor.OnSample(monitor,sample);
            end
            testCase.verifyEqual(monitor.StatusCalls,0); testCase.verifyEqual(monitor.DrainCalls,0);
            testCase.verifyEqual(controller.TelemetryHub.SamplesIngested,100000);
        end
        function dashboardRunnerPropagatesOneConfigAndDependencies(testCase)
            config=getBusDrivingSystemDashboardConfig(); config.signalHistorySeconds=60; config.sampleRateHz=50;
            probe=SystemControllerProbe(); probe.HasCalibration=true; timerCreated=0; timerObject=[];
            options=struct('Dependencies',probe.getDependencies(),'DashboardConfig',config, ...
                'DashboardDependencies',struct('createTimer',@createTimer),'OpenDashboard',true);
            [controller,dashboard]=runBusDrivingSystemDashboard(options);
            testCase.addTeardown(@()delete(dashboard)); testCase.addTeardown(@()delete(controller));
            testCase.verifyEqual(timerCreated,1); testCase.verifyEqual(dashboard.Config,controller.TelemetryHub.Config);
            sample=struct('elapsedSeconds',0);
            for index=1:3001, sample.elapsedSeconds=index/50; controller.TelemetryHub.ingestSample(sample); end
            testCase.verifyEqual(numel(controller.TelemetryHub.getSignalHistory()),3000);
            function value=createTimer(varargin)
                timerCreated=timerCreated+1; value=FakeRealtimeTimer(false,varargin{:}); timerObject=value; %#ok<NASGU>
            end
        end
        function unifiedCalibrationAcceptanceUsesObserverWithoutLegacyDashboard(testCase)
            events=struct.empty(0,1); legacyDashboardEnabled=true; confirmCalls=0; imu=FakeAcceptanceImu();
            config=struct('uid',"fake-uid",'host',"localhost",'port',4223, ...
                'busId',"fake-bus",'calibrationDirectory',"artifacts");
            dependencies=struct('assertClassApi',@()[],'getCommit',@()"0123456789012345678901234567890123456789", ...
                'assertRuntimeReady',@()[],'getConfig',@()config,'createImu',@(~)imu, ...
                'runPreflight',@(~)struct('success',true,'errors',strings(0,1)), ...
                'createController',@createController,'loadCalibration',@(~,~,~)calibration(), ...
                'applyCalibration',@(~,~)[]);
            options=struct('Observer',@observe,'Confirm',@confirm,'Dependencies',dependencies);
            report=runInstallationCalibrationHardwareAcceptance(options);
            testCase.verifyTrue(report.success); testCase.verifyFalse(legacyDashboardEnabled);
            progress=events(string({events.type})=="stage_progress");
            testCase.verifyGreaterThan(numel(progress),1);
            testCase.verifyTrue(all(arrayfun(@(e)all(isfield(e.payload, ...
                {'state','phase','progress','message','samplesCollected','samplesRequired','samplesRemaining','quality','verification'})),progress)));
            testCase.verifyTrue(any(arrayfun(@(e)isfield(e.payload,'verification') && isfinite(e.payload.verification),progress)));
            testCase.verifyGreaterThan(confirmCalls,0); testCase.verifyTrue(imu.Disconnected);
            function value=createController(~,~,workflowOptions,workflowDependencies)
                legacyDashboardEnabled=workflowOptions.enableDashboard;
                value=FakeAcceptanceCalibrationController(workflowOptions,workflowDependencies);
            end
            function observe(event), if isempty(events), events=event; else, events(end+1,1)=event; end, end
            function value=confirm(~), confirmCalls=confirmCalls+1; value=true; end
            function value=calibration()
                value=struct('rotationVehicleFromSensor',eye(3),'bias',[0 0 0],'quality',struct('score',.9));
            end
        end
        function closedControllerRejectsEveryMutatingAction(testCase)
            probe=SystemControllerProbe(); controller=BusDrivingSystemController(struct(),probe.getDependencies()); controller.close();
            actions={@()controller.startSystem(),@()controller.runPreflight(),@()controller.startCalibration(), ...
                @()controller.confirmCurrentStep(),@()controller.rejectCurrentStep(),@()controller.startRealtime(), ...
                @()controller.stopRealtime(),@()controller.runFullAcceptance(),@()controller.cancel(), ...
                @()controller.refreshRealtimeTelemetry()};
            for index=1:numel(actions), testCase.verifyError(actions{index},'IMU:SystemControllerClosed'); end
            status=controller.getStatus(); testCase.verifyTrue(status.isClosed);
            controller.getTelemetrySnapshot(); controller.getSummarySnapshot();
        end
        function operationStagesUseInjectedClock(testCase)
            utc=MutableUtcClock(datetime(2026,1,1,'TimeZone','UTC')); mono=MutableMonotonicClock();
            probe=SystemControllerProbe(); probe.HasCalibration=true; dependencies=probe.getDependencies();
            dependencies.nowUtc=@()utc.now(); dependencies.monotonicClockStart=@()mono.start();
            dependencies.monotonicClockElapsed=@(token)mono.elapsed(token); dependencies.getCommit=@getCommit;
            dependencies.runPreflight=@(~)preflight(); dependencies.createRealtimeMonitor=@(~,~)monitor();
            controller=BusDrivingSystemController(struct(),dependencies); testCase.addTeardown(@()delete(controller));
            controller.startSystem(); controller.startRealtime(); controller.stopRealtime(); stages=controller.TelemetryHub.getStages();
            verify("Bootstrap",2.5); verify("Preflight",10); verify("Realtime",1.5); verify("Stopping",.8);
            function value=getCommit(), advance(2.5); value="0123456789012345678901234567890123456789"; end
            function value=preflight(), advance(10); value=struct('success',true,'errors',strings(0,1)); end
            function value=monitor(), value=FakeSystemMonitor(); value.StartAction=@()advance(1.5); value.StopAction=@()advance(.8); end
            function advance(value), utc.advance(seconds(value)); mono.advance(value); end
            function verify(name,duration)
                records=stages(string({stages.stage})==name); testCase.verifyNotEmpty(records);
                testCase.verifyEqual(records(end).elapsedSeconds,duration,'AbsTol',1e-9);
            end
        end
        function destructorDetachesDuringAcceptance(testCase)
            probe=SystemControllerProbe(); dependencies=probe.getDependencies(); dashboard=[]; observed=false;
            dependencies.runAcceptance=@acceptance; controller=BusDrivingSystemController(struct(),dependencies);
            dashboard=BusDrivingSystemDashboard(controller); lastwarn(''); controller.runFullAcceptance();
            testCase.verifyTrue(observed); testCase.verifyFalse(controller.IsClosed); testCase.verifyEqual(controller.State,"COMPLETED");
            [~,identifier]=lastwarn(); testCase.verifyNotEqual(string(identifier),"IMU:AcceptanceInProgress");
            controller.close();
            function result=acceptance(options)
                delete(dashboard); options.Observer(struct('type',"stage_progress",'stage',"runtime_fifo", ...
                    'state',"RUNNING",'progress',.5,'message',"continued",'payload',struct()));
                observed=true; result=struct('success',true);
            end
        end
    end
end
