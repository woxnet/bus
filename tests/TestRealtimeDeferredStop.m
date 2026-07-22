classdef TestRealtimeDeferredStop < matlab.unittest.TestCase
    methods(TestClassSetup)
        function setup(~)
            root=fileparts(fileparts(mfilename('fullpath')));
            addpath(fullfile(root,'src'),fullfile(root,'tests'));
        end
    end
    methods(Test)
        function onSampleStopWaitsForBatchBoundary(testCase)
            [monitor,imu,probe,cleanup]=testCase.monitor(); %#ok<ASGLU>
            stopped=RealtimeCallbackProbe(); monitor.OnStopped=@stopped.stopped;
            monitor.OnSample=@(~,~)monitor.stop(); monitor.startManual();
            imu.injectCallbackSamples(testCase.samples(20,0)); monitor.poll();
            summary=testCase.verifyCompleteBatch(monitor,imu,probe,"operator_stop");
            testCase.verifyEqual(stopped.StoppedCount,1);
            before=summary.samplesProcessed; monitor.poll();
            testCase.verifyEqual(monitor.getStats().samplesProcessed,before);
        end

        function onEventStartedStopWaitsForBatchBoundary(testCase)
            [monitor,imu,probe,cleanup]=testCase.monitor(testCase.eventOptions()); %#ok<ASGLU>
            monitor.OnEventStarted=@(~,~)monitor.stop(); monitor.startManual();
            imu.injectCallbackSamples(testCase.samples(20,5)); monitor.poll();
            testCase.verifyCompleteBatch(monitor,imu,probe,"operator_stop");
        end

        function onEventCompletedStopWaitsForBatchBoundary(testCase)
            options=testCase.eventOptions(); options.maximumEventSilenceSeconds=.02;
            [monitor,imu,probe,cleanup]=testCase.monitor(options); %#ok<ASGLU>
            monitor.OnEventCompleted=@(~,~)monitor.stop(); monitor.startManual();
            imu.injectCallbackSamples([testCase.samples(6,5);testCase.samples(14,0)]);
            monitor.poll(); testCase.verifyCompleteBatch(monitor,imu,probe,"operator_stop");
        end

        function onWarningStopWaitsForBatchBoundary(testCase)
            [monitor,imu,probe,cleanup]=testCase.monitor(struct('enableLivePlot',true)); %#ok<ASGLU>
            monitor.OnWarning=@(~,~)monitor.stop(); monitor.startManual();
            probe.Dashboard.FailOnUpdate=true;
            imu.injectCallbackSamples(testCase.samples(20,0)); monitor.poll();
            testCase.verifyCompleteBatch(monitor,imu,probe,"operator_stop");
        end

        function sequenceGapStopWaitsForBatchBoundary(testCase)
            [monitor,imu,probe,cleanup]=testCase.monitor(struct('stopOnSequenceGap',true)); %#ok<ASGLU>
            monitor.startManual(); sequences=[1:10 12:21];
            imu.injectCallbackSamples(testCase.samples(20,0),sequences); monitor.poll();
            summary=testCase.verifyCompleteBatch(monitor,imu,probe,"sequence_gap");
            testCase.verifyEqual(summary.missingSamples,1);
        end
    end
    methods(Access=private)
        function summary=verifyCompleteBatch(testCase,monitor,imu,probe,reason)
            summary=monitor.getStats();
            testCase.verifyFalse(monitor.IsRunning);
            testCase.verifyEqual(summary.samplesProcessed,20);
            testCase.verifyEqual(summary.recording.samplesWritten,20);
            testCase.verifyTrue(summary.stopDeferredUntilBatchBoundary);
            testCase.verifyEqual(summary.deferredStopReason,string(reason));
            testCase.verifyEqual(summary.stopReason,string(reason));
            testCase.verifyEqual(imu.StreamOwner,"none");
            testCase.verifyEqual(probe.Recorder.FinalizedStreamOwner,"RealtimeDrivingMonitor");
            testCase.verifyEqual(monitor.getStats(),summary);
        end
        function [monitor,imu,probe,cleanup]=monitor(~,overrides)
            if nargin<2, overrides=struct(); end
            options=getRealtimeDrivingConfig(); options.UseTimer=false;
            options.enableLivePlot=false; options.enableRecording=true;
            options.AllowSyntheticCalibration=true; options.minimumFreeDiskBytes=1;
            fields=fieldnames(overrides);
            for index=1:numel(fields), options.(fields{index})=overrides.(fields{index}); end
            probe=RealtimeDependencyProbe(); imu=MockImuBrick2(); imu.FreezeCallback=true;
            monitor=RealtimeDrivingMonitor(imu,createTestImuCalibration(true),options,probe.dependencies());
            cleanup=onCleanup(@()delete(monitor));
        end
        function options=eventOptions(~)
            options=struct('minimumEventDurationSeconds',.02, ...
                'medianWindowSamples',1,'outlierMadThreshold',1000, ...
                'lowPassCutoffHz',20);
        end
        function values=samples(~,count,longitudinal)
            sample=MockImuBrick2.makeSample([0 0 -9.81], ...
                [longitudinal 0 0],[0 0 0]);
            values=repmat(sample,count,1);
            values=MockImuBrick2.withAdvancingTimestamps(values,.02);
        end
    end
end
