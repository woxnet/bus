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
                comparison=compareRealtimeAndOfflineEvents(realtime,offline.events,25);
                testCase.verifyTrue(comparison.countMatch,char(scenario));
                testCase.verifyTrue(comparison.allWithinLatency,char(scenario));
            end
        end
        function comparisonReportsMismatches(testCase)
            base=struct('type',"BRAKING_CANDIDATE",'startSequence',uint64(10), ...
                'endSequence',uint64(20),'peakAcceleration',-2,'durationSeconds',0.2);
            other=base; other.type="ACCELERATION_CANDIDATE";
            report=compareRealtimeAndOfflineEvents(base,other,5);
            testCase.verifyTrue(report.countMatch); testCase.verifyFalse(report.allWithinLatency);
        end
    end
    methods(Access=private)
        function events=runRealtime(~,directory)
            options=getRealtimeDrivingConfig(); options.UseTimer=false;
            options.enableLivePlot=false; options.enableRecording=false;
            options.AllowSyntheticCalibration=true; options.stopOnOverflow=false;
            imu=MockImuBrick2(); imu.FreezeCallback=true;
            monitor=RealtimeDrivingMonitor(imu,createTestImuCalibration(true),options);
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
