classdef TestRealtimeDrivingLifecycle < matlab.unittest.TestCase
    methods(TestClassSetup)
        function setup(~)
            root=fileparts(fileparts(mfilename('fullpath')));
            addpath(fullfile(root,'src'),fullfile(root,'tests'));
        end
    end
    methods(Test)
        function runtimeDependencyIsInvoked(testCase)
            probe=RealtimeDependencyProbe(); [monitor,imu,cleanup]=testCase.monitor(probe); %#ok<ASGLU>
            monitor.startManual(); testCase.verifyEqual(probe.RuntimeCalls,1); monitor.stop();
            source=fileread(which('RealtimeDrivingMonitor'));
            testCase.verifyTrue(contains(source,"'assertRuntimeReady',@assertImuRuntimeReady"));
        end
        function noOpRuntimeDependencyAllowsMockStart(testCase)
            [monitor,~,cleanup]=testCase.monitor(RealtimeDependencyProbe()); %#ok<ASGLU>
            monitor.startManual(); testCase.verifyTrue(monitor.IsRunning);
        end
        function runtimeFailureRollsBack(testCase)
            probe=RealtimeDependencyProbe(); probe.FailRuntime=true;
            testCase.verifyStartFailure(probe,struct(),'Test:RuntimeFailure');
        end
        function imuStartFailureRollsBack(testCase)
            probe=RealtimeDependencyProbe(); [monitor,imu,cleanup]=testCase.monitor(probe); %#ok<ASGLU>
            imu.FailStart=true; testCase.verifyError(@()monitor.startManual(),'MockImu:StartFailure');
            testCase.verifySafeStopped(monitor,imu,probe);
        end
        function recorderCreateFailureRollsBack(testCase)
            probe=RealtimeDependencyProbe(); probe.FailRecorderCreate=true;
            testCase.verifyStartFailure(probe,struct('enableRecording',true),'Test:RecorderCreateFailure');
        end
        function recorderStartFailureRollsBack(testCase)
            probe=RealtimeDependencyProbe(); probe.FailRecorderStart=true;
            testCase.verifyStartFailure(probe,struct('enableRecording',true),'Test:RecorderStartFailure');
            testCase.verifyFalse(isvalid(probe.Recorder));
        end
        function dashboardFailureRollsBack(testCase)
            probe=RealtimeDependencyProbe(); probe.FailDashboardOpen=true;
            testCase.verifyStartFailure(probe,struct('enableLivePlot',true),'Test:DashboardOpenFailure');
        end
        function timerCreateFailureRollsBack(testCase)
            probe=RealtimeDependencyProbe(); probe.FailTimerCreate=true;
            testCase.verifyStartFailure(probe,struct('UseTimer',true),'Test:TimerCreateFailure');
        end
        function timerStartFailureRollsBack(testCase)
            probe=RealtimeDependencyProbe(); probe.FailTimerStart=true;
            testCase.verifyStartFailure(probe,struct('UseTimer',true),'Test:TimerStartFailure');
        end
        function quiescePreservesQueueAndSession(testCase)
            imu=MockImuBrick2(); imu.FreezeCallback=true; imu.start(20);
            samples=MockImuBrick2.createStationarySequence(4,eye(3));
            imu.injectCallbackSamples(samples); before=imu.getCallbackStats();
            imu.quiesce(); after=imu.getCallbackStats();
            testCase.verifyFalse(imu.IsStreaming); testCase.verifyEqual(after.sessionId,before.sessionId);
            testCase.verifyEqual(after.buffered,uint64(4));
            testCase.verifyEqual(numel(imu.drainCallbackSamples(10)),4);
            imu.stop(); testCase.verifyGreaterThan(imu.getCallbackStats().sessionId,after.sessionId);
        end
        function stopDrainsTailIntoRecorderAndFinalStats(testCase)
            probe=RealtimeDependencyProbe();
            [monitor,imu,cleanup]=testCase.monitor(probe,struct('enableRecording',true)); %#ok<ASGLU>
            monitor.startManual(); samples=MockImuBrick2.createStationarySequence(7,eye(3));
            imu.injectCallbackSamples(samples); summary=monitor.stop();
            testCase.verifyEqual(summary.tailSamplesDrained,7);
            testCase.verifyEqual(summary.samplesProcessed,7);
            testCase.verifyEqual(summary.lastSequence,uint64(7));
            testCase.verifyEqual(probe.Recorder.AppendedCount,7);
            testCase.verifyFalse(probe.Recorder.FinalizedWhileStreaming);
            testCase.verifyFalse(summary.stopDrainTimedOut); testCase.verifyTrue(summary.success);
        end
        function recorderFinalizationFailureIsUnsuccessful(testCase)
            probe=RealtimeDependencyProbe(); probe.FailRecorderStop=true;
            callback=RealtimeCallbackProbe();
            [monitor,imu,cleanup]=testCase.monitor(probe,struct('enableRecording',true)); %#ok<ASGLU>
            monitor.OnError=@callback.error; monitor.startManual(); summary=monitor.stop();
            testCase.verifyFalse(summary.success); testCase.verifyNotEmpty(summary.errors);
            testCase.verifyFalse(imu.IsStreaming); testCase.verifyFalse(isvalid(probe.Recorder));
            testCase.verifyEqual(callback.ErrorCount,1);
        end
        function monotonicClockControlsDurationAndFrequency(testCase)
            probe=RealtimeDependencyProbe(); probe.ClockElapsed=2;
            [monitor,imu,cleanup]=testCase.monitor(probe); %#ok<ASGLU>
            monitor.startManual(); imu.injectCallbackSamples(testCase.samples(50,0,0,0)); monitor.poll();
            stats=monitor.getStats(); testCase.verifyEqual(stats.durationSeconds,2);
            testCase.verifyEqual(stats.averageFrequencyHz,25);
        end
        function repeatedTimerCyclesDoNotLeak(testCase)
            probe=RealtimeDependencyProbe(); [monitor,imu,cleanup]=testCase.monitor(probe,struct('UseTimer',true)); %#ok<ASGLU>
            for index=1:20, monitor.start(); monitor.stop(); end
            testCase.verifyEqual(probe.TimerCreateCount,20);
            testCase.verifyTrue(all(~isvalid(probe.Timers)));
        end
        function invalidCallbackMetadataIsRejected(testCase)
            ages={NaN,Inf,-1};
            for index=1:numel(ages)
                [monitor,imu,cleanup]=testCase.monitor(RealtimeDependencyProbe()); %#ok<ASGLU>
                monitor.startManual(); imu.injectCallbackSamples(testCase.samples(1,0,0,0),1,ages{index}); monitor.poll();
                testCase.verifyEqual(monitor.InvalidSamples,1); testCase.verifyEqual(monitor.MaximumCallbackAgeMs,0);
                testCase.verifyEqual(monitor.LatestDataQualityEvent.type,"INVALID_CALLBACK_METADATA");
                monitor.stop(); clear cleanup;
            end
            [monitor,imu,cleanup]=testCase.monitor(RealtimeDependencyProbe()); %#ok<ASGLU>
            monitor.startManual(); sample=testCase.samples(1,0,0,0); sample.hostTimestamp=NaT;
            imu.injectCallbackSamples(sample); monitor.poll(); testCase.verifyEqual(monitor.InvalidSamples,1);
        end
        function invalidSampleTerminatesButDoesNotPoisonNextSegment(testCase)
            [monitor,imu,cleanup]=testCase.monitor(RealtimeDependencyProbe()); %#ok<ASGLU>
            monitor.startManual(); imu.injectCallbackSamples(testCase.samples(25,-3,0,0),1:25); monitor.poll();
            imu.injectCallbackSamples(testCase.samples(1,0,0,0),26,NaN); monitor.poll();
            imu.injectCallbackSamples(testCase.samples(5,0,0,0),27:31); monitor.poll(); monitor.stop();
            events=monitor.getRecentEvents();
            testCase.verifyEqual(events(1).terminationReason,"invalid_sample");
            history=monitor.getRecentSamples();
            testCase.verifyTrue(all([history.dataValid]));
        end
        function dataQualityRecoversAfterGap(testCase)
            [monitor,imu,cleanup]=testCase.monitor(RealtimeDependencyProbe()); %#ok<ASGLU>
            monitor.startManual(); imu.injectCallbackSamples(testCase.samples(1,0,0,0),1); monitor.poll();
            imu.injectCallbackSamples(testCase.samples(1,0,0,0),3); monitor.poll();
            imu.injectCallbackSamples(testCase.samples(3,0,0,0),4:6); monitor.poll();
            history=monitor.getRecentSamples(); gap=history([history.sequenceNumber]==3);
            normal=history([history.sequenceNumber]==6);
            testCase.verifyTrue(gap.gapBeforeSample); testCase.verifyLessThan(gap.dataQuality,1);
            testCase.verifyFalse(normal.gapBeforeSample); testCase.verifyEqual(normal.dataQuality,1);
        end
        function stopFromWarningIsSafe(testCase)
            options=struct('stopOnOverflow',false); [monitor,imu,cleanup]=testCase.monitor(RealtimeDependencyProbe(),options); %#ok<ASGLU>
            monitor.OnWarning=@(~,~)monitor.stop(); monitor.startManual();
            imu.injectCallbackSamples(testCase.samples(300,0,0,0)); monitor.poll();
            testCase.verifyFalse(monitor.IsRunning);
        end
        function stopFromTimerCallbackIsSafe(testCase)
            probe=RealtimeDependencyProbe(); [monitor,imu,cleanup]=testCase.monitor(probe,struct('UseTimer',true)); %#ok<ASGLU>
            monitor.OnSample=@(~,~)monitor.stop(); monitor.start();
            imu.injectCallbackSamples(testCase.samples(1,0,0,0)); probe.Timers(1).fire();
            testCase.verifyFalse(monitor.IsRunning);
        end
        function deleteDuringRecorderFailureIsSafe(testCase)
            probe=RealtimeDependencyProbe(); probe.FailRecorderStop=true;
            [monitor,imu,cleanup]=testCase.monitor(probe,struct('enableRecording',true)); %#ok<ASGLU>
            monitor.startManual(); delete(monitor); testCase.verifyFalse(imu.IsStreaming);
        end
        function onStoppedRunsExactlyOnce(testCase)
            probe=RealtimeCallbackProbe(); [monitor,~,cleanup]=testCase.monitor(RealtimeDependencyProbe()); %#ok<ASGLU>
            monitor.OnStopped=@probe.stopped; monitor.startManual(); monitor.stop(); monitor.stop();
            testCase.verifyEqual(probe.StoppedCount,1);
        end
        function userCallbackFailureIsNotInternalError(testCase)
            callback=RealtimeCallbackProbe(); callback.ThrowOnSample=true;
            [monitor,imu,cleanup]=testCase.monitor(RealtimeDependencyProbe()); %#ok<ASGLU>
            monitor.OnSample=@callback.sample; monitor.startManual();
            imu.injectCallbackSamples(testCase.samples(1,0,0,0));
            testCase.verifyWarning(@()monitor.poll(),'IMU:RealtimeUserCallbackFailed');
            monitor.OnSample=[]; summary=monitor.stop(); testCase.verifyEmpty(summary.errors);
        end
        function monitorIsOnlyFifoConsumer(testCase)
            probe=RealtimeDependencyProbe(); [monitor,imu,cleanup]=testCase.monitor(probe,struct('enableRecording',true)); %#ok<ASGLU>
            monitor.startManual(); imu.injectCallbackSamples(testCase.samples(3,0,0,0)); monitor.poll(); monitor.stop();
            testCase.verifyEqual(probe.Recorder.AppendedCount,monitor.SamplesProcessed);
            testCase.verifyEqual(imu.DrainCallCount,4);
        end
        function nearbyEventsMerge(testCase)
            events=testCase.brakingPair(8,false); testCase.verifyEqual(numel(events),1);
        end
        function distantEventsRemainSeparate(testCase)
            events=testCase.brakingPair(35,false); testCase.verifyEqual(numel(events),2);
        end
        function gapPreventsPendingMerge(testCase)
            events=testCase.brakingPair(8,true); testCase.verifyEqual(numel(events),2);
        end
        function pendingEventPublishesAtStop(testCase)
            [monitor,imu,cleanup]=testCase.monitor(RealtimeDependencyProbe()); %#ok<ASGLU>
            monitor.startManual(); imu.injectCallbackSamples(testCase.samples(25,-3,0,0)); monitor.poll();
            testCase.verifyEqual(monitor.EventsDetected,0); monitor.stop();
            testCase.verifyEqual(monitor.EventsDetected,1);
        end
    end
    methods(Access=private)
        function verifyStartFailure(testCase,probe,overrides,identifier)
            [monitor,imu,cleanup]=testCase.monitor(probe,overrides); %#ok<ASGLU>
            testCase.verifyError(@()monitor.start(),identifier); testCase.verifySafeStopped(monitor,imu,probe);
        end
        function verifySafeStopped(testCase,monitor,imu,probe)
            testCase.verifyFalse(monitor.IsRunning); testCase.verifyFalse(imu.IsStreaming);
            if ~isempty(probe.Recorder)
                testCase.verifyTrue(~isvalid(probe.Recorder) || ~probe.Recorder.IsRecording);
            end
            if ~isempty(probe.Timers), testCase.verifyTrue(all(~isvalid(probe.Timers))); end
        end
        function [monitor,imu,cleanup]=monitor(~,probe,overrides)
            if nargin<3, overrides=struct(); end
            options=getRealtimeDrivingConfig(); options.UseTimer=false;
            options.enableLivePlot=false; options.enableRecording=false;
            options.AllowSyntheticCalibration=true; fields=fieldnames(overrides);
            for index=1:numel(fields), options.(fields{index})=overrides.(fields{index}); end
            imu=MockImuBrick2(); imu.FreezeCallback=true;
            monitor=RealtimeDrivingMonitor(imu,createTestImuCalibration(true),options,probe.dependencies());
            cleanup=onCleanup(@()delete(monitor));
        end
        function samples=samples(~,count,x,y,z)
            yaw=20*sign(y); sample=MockImuBrick2.makeSample([0 0 -9.81],[x y z],[0 0 yaw]);
            samples=repmat(sample,count,1); samples=MockImuBrick2.withAdvancingTimestamps(samples,0.02);
        end
        function events=brakingPair(testCase,silenceSamples,withGap)
            [monitor,imu,cleanup]=testCase.monitor(RealtimeDependencyProbe()); %#ok<ASGLU>
            monitor.startManual(); samples=[testCase.samples(25,-3,0,0); ...
                testCase.samples(silenceSamples,0,0,0);testCase.samples(25,-3,0,0);testCase.samples(20,0,0,0)];
            sequence=1:numel(samples); if withGap, sequence(26:end)=sequence(26:end)+3; end
            imu.injectCallbackSamples(samples,sequence); monitor.poll(); monitor.stop(); events=monitor.getRecentEvents();
        end
    end
end
