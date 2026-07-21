classdef TestRealtimeDrivingMonitor < matlab.unittest.TestCase
    methods(TestClassSetup)
        function setup(~)
            root=fileparts(fileparts(mfilename('fullpath')));
            addpath(fullfile(root,'src'),fullfile(root,'tests'));
        end
    end
    methods(Test)
        function stationaryProducesNoEvents(testCase)
            [events,stats]=testCase.runScenario("stationary");
            testCase.verifyEmpty(events); testCase.verifyEqual(stats.samplesProcessed,80);
        end
        function brakingProducesOneEvent(testCase), testCase.verifyOne("braking","BRAKING_CANDIDATE"); end
        function accelerationProducesOneEvent(testCase), testCase.verifyOne("acceleration","ACCELERATION_CANDIDATE"); end
        function leftTurnProducesOneEvent(testCase), testCase.verifyOne("left","TURN_LEFT_CANDIDATE"); end
        function rightTurnProducesOneEvent(testCase), testCase.verifyOne("right","TURN_RIGHT_CANDIDATE"); end
        function verticalShockProducesOneEvent(testCase), testCase.verifyOne("shock","VERTICAL_SHOCK_CANDIDATE"); end

        function fifoOrderAndNoDuplicateProcessing(testCase)
            [monitor,imu,cleanup]=testCase.startedMonitor(); %#ok<ASGLU>
            imu.FreezeCallback=true;
            samples=testCase.signalSamples(10,0,0,0);
            imu.injectCallbackSamples(samples,1:10); monitor.poll();
            imu.injectCallbackSamples(samples(1),10); monitor.poll();
            history=monitor.getRecentSamples(); stats=monitor.getStats();
            testCase.verifyEqual([history.sequenceNumber],uint64(1:10));
            testCase.verifyEqual(stats.samplesProcessed,10);
            testCase.verifyEqual(stats.duplicateSamples,1);
        end
        function sequenceGapTerminatesEventAndResetsFilter(testCase)
            [monitor,imu,cleanup]=testCase.startedMonitor(); %#ok<ASGLU>
            imu.FreezeCallback=true;
            active=testCase.signalSamples(30,-3,0,0);
            imu.injectCallbackSamples(active,1:30); monitor.poll();
            calm=testCase.signalSamples(10,0,0,0);
            imu.injectCallbackSamples(calm,35:44); monitor.poll();
            events=monitor.getRecentEvents(); samples=monitor.getRecentSamples();
            testCase.verifyEqual(monitor.MissingSamples,4);
            testCase.verifyEqual(numel(events),1);
            testCase.verifyEqual(events.terminationReason,"sequence_gap");
            testCase.verifyEqual(events.endSequence,uint64(30));
            afterGap=samples([samples.sequenceNumber]==35);
            testCase.verifyTrue(isnan(afterGap.longitudinalJerk));
        end
        function overflowWarnsAndStopsWhenConfigured(testCase)
            [monitor,imu,cleanup]=testCase.startedMonitor(); %#ok<ASGLU>
            probe=RealtimeCallbackProbe(); monitor.OnWarning=@probe.warning;
            imu.injectCallbackSamples(testCase.signalSamples(300,0,0,0)); monitor.poll();
            testCase.verifyGreaterThan(probe.WarningCount,0);
            testCase.verifyGreaterThan(monitor.OverflowDropped,0);
            testCase.verifyEqual(monitor.DataQualityEventsDetected,1);
            testCase.verifyEqual(monitor.LatestDataQualityEvent.type,"CALLBACK_OVERFLOW");
            testCase.verifyFalse(monitor.IsRunning);
        end
        function overflowCanWarnWithoutStopping(testCase)
            options=testCase.options(); options.stopOnOverflow=false;
            [monitor,imu,cleanup]=testCase.startedMonitor(options); %#ok<ASGLU>
            probe=RealtimeCallbackProbe(); monitor.OnWarning=@probe.warning;
            imu.injectCallbackSamples(testCase.signalSamples(300,0,0,0)); monitor.poll();
            testCase.verifyGreaterThan(probe.WarningCount,0); testCase.verifyTrue(monitor.IsRunning);
        end
        function lateSampleReducesDataQuality(testCase)
            [monitor,imu,cleanup]=testCase.startedMonitor(); %#ok<ASGLU>
            samples=testCase.signalSamples(2,0,0,0);
            imu.injectCallbackSamples(samples,[1 2],[0 1000]); monitor.poll();
            history=monitor.getRecentSamples();
            testCase.verifyEqual(monitor.LateSamples,1);
            testCase.verifyLessThan(history(2).dataQuality,history(1).dataQuality);
        end
        function sampleHistoryIsBounded(testCase)
            options=testCase.options(); options.historySeconds=0.1;
            [monitor,imu,cleanup]=testCase.startedMonitor(options); %#ok<ASGLU>
            imu.injectCallbackSamples(testCase.signalSamples(20,0,0,0)); monitor.poll();
            testCase.verifyEqual(numel(monitor.getRecentSamples()),5);
        end
        function eventHistoryIsBounded(testCase)
            options=testCase.options(); options.eventHistoryLimit=2;
            [monitor,imu,cleanup]=testCase.startedMonitor(options); %#ok<ASGLU>
            samples=[testCase.signalSamples(25,-3,0,0);testCase.signalSamples(15,0,0,0); ...
                testCase.signalSamples(25,3,0,0);testCase.signalSamples(15,0,0,0); ...
                testCase.signalSamples(25,-3,0,0);testCase.signalSamples(15,0,0,0)];
            imu.injectCallbackSamples(samples); monitor.poll();
            testCase.verifyEqual(monitor.EventsDetected,3);
            testCase.verifyEqual(numel(monitor.getRecentEvents()),2);
        end
        function userCallbackFailureDoesNotStopMonitor(testCase)
            [monitor,imu,cleanup]=testCase.startedMonitor(); %#ok<ASGLU>
            probe=RealtimeCallbackProbe(); probe.ThrowOnSample=true; monitor.OnSample=@probe.sample;
            imu.injectCallbackSamples(testCase.signalSamples(1,0,0,0));
            testCase.verifyWarning(@()monitor.poll(),'IMU:RealtimeUserCallbackFailed');
            testCase.verifyTrue(monitor.IsRunning); testCase.verifyNotEmpty(monitor.LastError);
        end
        function repeatedStartIsRejected(testCase)
            [monitor,~,cleanup]=testCase.startedMonitor(); %#ok<ASGLU>
            testCase.verifyError(@()monitor.startManual(),'IMU:RealtimeMonitorAlreadyRunning');
        end
        function repeatedStopIsSafe(testCase)
            [monitor,~,cleanup]=testCase.startedMonitor(); %#ok<ASGLU>
            monitor.stop(); second=monitor.stop(); testCase.verifyFalse(second.isRunning);
        end
        function deleteStopsButDoesNotDisconnectImu(testCase)
            options=testCase.options(); imu=MockImuBrick2();
            monitor=RealtimeDrivingMonitor(imu,createTestImuCalibration(true),options);
            monitor.startManual(); delete(monitor);
            testCase.verifyFalse(imu.IsStreaming); testCase.verifyEqual(imu.DisconnectCount,0);
        end
        function syntheticCalibrationRejectedByDefault(testCase)
            options=testCase.options(); options.AllowSyntheticCalibration=false;
            monitor=RealtimeDrivingMonitor(MockImuBrick2(),createTestImuCalibration(true),options);
            cleanup=onCleanup(@()delete(monitor));
            testCase.verifyError(@()monitor.startManual(),'IMU:InvalidCalibrationFile');
        end
        function syntheticCalibrationRequiresExplicitOption(testCase)
            [monitor,~,cleanup]=testCase.startedMonitor(); %#ok<ASGLU>
            testCase.verifyTrue(monitor.IsRunning);
        end
        function onlineEventHasOfflineCompatibleFields(testCase)
            [events,~]=testCase.runScenario("braking");
            required={'type','startSequence','endSequence','durationSeconds','peakAcceleration'};
            testCase.verifyTrue(all(isfield(events,required)));
        end
        function monitorDoesNotCallOfflinePipeline(testCase)
            source=string(fileread(fullfile(fileparts(fileparts(mfilename('fullpath'))), ...
                'src','RealtimeDrivingMonitor.m')));
            forbidden=["analyzeImuSession(" "preprocessDrivingSession(" "zeroPhaseEma(" "detectDrivingEvents(" "latest("];
            for token=forbidden, testCase.verifyFalse(contains(source,token)); end
        end
    end
    methods(Access=private)
        function verifyOne(testCase,scenario,type)
            [events,~]=testCase.runScenario(scenario);
            testCase.verifyEqual(numel(events),1); testCase.verifyEqual(events.type,type);
        end
        function [events,stats]=runScenario(testCase,scenario)
            switch scenario
                case "stationary", samples=testCase.signalSamples(80,0,0,0);
                case "braking", samples=[testCase.signalSamples(20,0,0,0);testCase.signalSamples(40,-3,0,0);testCase.signalSamples(20,0,0,0)];
                case "acceleration", samples=[testCase.signalSamples(20,0,0,0);testCase.signalSamples(40,3,0,0);testCase.signalSamples(20,0,0,0)];
                case "left", samples=[testCase.signalSamples(20,0,0,0);testCase.signalSamples(40,0,3,0);testCase.signalSamples(20,0,0,0)];
                case "right", samples=[testCase.signalSamples(20,0,0,0);testCase.signalSamples(40,0,-3,0);testCase.signalSamples(20,0,0,0)];
                case "shock", samples=[testCase.signalSamples(20,0,0,0);testCase.signalSamples(8,0,0,3);testCase.signalSamples(20,0,0,0)];
            end
            [monitor,imu,cleanup]=testCase.startedMonitor(); %#ok<ASGLU>
            imu.injectCallbackSamples(samples); monitor.poll(); monitor.stop();
            events=monitor.getRecentEvents(); stats=monitor.getStats();
        end
        function [monitor,imu,cleanup]=startedMonitor(testCase,options)
            if nargin<2, options=testCase.options(); end
            imu=MockImuBrick2(); monitor=RealtimeDrivingMonitor(imu,createTestImuCalibration(true),options);
            cleanup=onCleanup(@()delete(monitor)); monitor.startManual();
        end
        function options=options(~)
            options=getRealtimeDrivingConfig(); options.UseTimer=false;
            options.enableLivePlot=false; options.enableRecording=false;
            options.AllowSyntheticCalibration=true;
        end
        function samples=signalSamples(~,count,x,y,z)
            yawRate=20*sign(y);
            sample=MockImuBrick2.makeSample([0 0 -9.81],[x y z],[0 0 yawRate]);
            samples=repmat(sample,count,1); samples=MockImuBrick2.withAdvancingTimestamps(samples,0.02);
        end
    end
end
