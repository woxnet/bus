classdef TestRealtimeOnlineOfflineComparison < matlab.unittest.TestCase
    properties
        TemporaryDirectory string
    end
    methods(TestMethodSetup)
        function setup(testCase)
            root=fileparts(fileparts(mfilename('fullpath')));
            addpath(fullfile(root,'src'),fullfile(root,'tests'));
            testCase.TemporaryDirectory=string(tempname); mkdir(testCase.TemporaryDirectory);
        end
    end
    methods(TestMethodTeardown)
        function cleanup(testCase)
            if isfolder(testCase.TemporaryDirectory), rmdir(testCase.TemporaryDirectory,'s'); end
        end
    end
    methods(Test)
        function syntheticScenariosHaveMatchingCounts(testCase)
            scenarios=["braking","acceleration","left_turn","right_turn","vertical_shock"];
            for scenario=scenarios
                directory=createSyntheticDrivingSession(testCase.TemporaryDirectory,scenario);
                offline=analyzeImuSession(directory,struct('AllowSynthetic',true,'SaveAnalysis',false));
                testCase.assertTrue(offline.success,strjoin(offline.errors,' '));
                realtime=testCase.runRealtime(directory);
                comparison=compareRealtimeAndOfflineEvents(realtime,offline.events, ...
                    'StartEndToleranceSamples',25, ...
                    'PeakAccelerationTolerance',1.0, ...
                    'DurationToleranceSeconds',1.0);
                testCase.verifyTrue(comparison.countMatch,char(scenario));
                testCase.verifyTrue(comparison.allWithinTolerance,char(scenario));
            end
        end
        function comparisonReportsMismatches(testCase)
            base=struct('type',"BRAKING_CANDIDATE",'startSequence',uint64(10), ...
                'endSequence',uint64(20),'peakAcceleration',-2,'durationSeconds',0.2);
            other=base; other.type="ACCELERATION_CANDIDATE";
            report=compareRealtimeAndOfflineEvents(base,other,5);
            testCase.verifyTrue(report.countMatch); testCase.verifyFalse(report.allWithinLatency);
        end
        function matchingUsesTypeAndNearestStart(testCase)
            offline=[testCase.event("BRAKING_CANDIDATE",100,120,-2); ...
                testCase.event("ACCELERATION_CANDIDATE",50,70,2); ...
                testCase.event("BRAKING_CANDIDATE",10,30,-2)];
            realtime=[testCase.event("BRAKING_CANDIDATE",12,32,-2.1); ...
                testCase.event("ACCELERATION_CANDIDATE",52,72,2.1); ...
                testCase.event("BRAKING_CANDIDATE",98,118,-1.9)];
            report=compareRealtimeAndOfflineEvents(realtime,offline, ...
                'StartEndToleranceSamples',3,'PeakAccelerationTolerance',0.2, ...
                'DurationToleranceSeconds',0.01);
            testCase.verifyTrue(report.allWithinTolerance);
            testCase.verifyEqual([report.details.offlineIndex],[3 2 1]);
        end
        function peakAndDurationArePartOfTolerance(testCase)
            offline=testCase.event("BRAKING_CANDIDATE",10,20,-2);
            realtime=offline; realtime.peakAcceleration=-4; realtime.durationSeconds=2;
            report=compareRealtimeAndOfflineEvents(realtime,offline, ...
                'PeakAccelerationTolerance',0.5,'DurationToleranceSeconds',0.1);
            testCase.verifyFalse(report.allWithinTolerance);
            testCase.verifyTrue(report.allWithinLatency);
            testCase.verifyTrue(report.details.withinLatency);
            testCase.verifyFalse(report.details.withinPeakTolerance);
            testCase.verifyFalse(report.details.withinDurationTolerance);
        end
    end
    methods(Access=private)
        function value=event(~,type,startSequence,endSequence,peak)
            value=struct('type',string(type),'startSequence',uint64(startSequence), ...
                'endSequence',uint64(endSequence),'peakAcceleration',peak, ...
                'durationSeconds',double(endSequence-startSequence+1)/50);
        end
        function events=runRealtime(~,directory)
            options=getRealtimeDrivingConfig(); options.UseTimer=false;
            options.enableLivePlot=false; options.enableRecording=false;
            options.AllowSyntheticCalibration=true; options.stopOnOverflow=false;
            imu=MockImuBrick2(); imu.FreezeCallback=true;
            monitor=RealtimeDrivingMonitor(imu,createTestImuCalibration(true),options, ...
                struct('assertRuntimeReady',@()[]));
            cleanup=onCleanup(@()delete(monitor));
            monitor.startManual(); files=dir(fullfile(directory,'samples_*.mat'));
            for index=1:numel(files)
                loaded=load(fullfile(files(index).folder,files(index).name),'sensorSamples');
                samples=vertcat(loaded.sensorSamples{:});
                imu.injectCallbackSamples(samples); monitor.poll();
            end
            monitor.stop(); events=monitor.getRecentEvents();
        end
    end
end
