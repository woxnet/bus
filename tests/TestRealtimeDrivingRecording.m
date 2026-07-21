classdef TestRealtimeDrivingRecording < matlab.unittest.TestCase
    properties
        TemporaryDirectories string = strings(0,1)
    end
    methods(TestClassSetup)
        function setup(~)
            root=fileparts(fileparts(mfilename('fullpath')));
            addpath(fullfile(root,'src'),fullfile(root,'tests'));
        end
    end
    methods(TestMethodTeardown)
        function cleanupDirectories(testCase)
            for directory=testCase.TemporaryDirectories.'
                if isfolder(directory), rmdir(directory,'s'); end
            end
            testCase.TemporaryDirectories=strings(0,1);
        end
    end
    methods(Test)
        function externalRecorderNeverDrainsFifo(testCase)
            directory=testCase.newDirectory(); imu=MockImuBrick2();
            recorder=ImuSessionRecorder(imu,createTestImuCalibration(true), ...
                struct('directory',directory,'AllowSynthetic',true,'chunkSize',2));
            cleanup=onCleanup(@()delete(recorder));
            recorder.startExternal();
            for sequence=1:3
                sensor=MockImuBrick2.makeSample([0 0 -9.81],[0 0 0],[0 0 0]);
                sensor.sequenceNumber=uint64(sequence); sensor.sessionId=uint64(1);
                sensor.callbackAgeMs=0;
                vehicle=applyMountCalibration(sensor,createTestImuCalibration(true),'AllowSynthetic',true);
                recorder.appendSample(sensor,vehicle);
            end
            recorder.stopExternal(testCase.stats(3));
            testCase.verifyEqual(imu.DrainCallCount,0);
        end
        function monitorForwardsEveryProcessedSampleAndWritesV2(testCase)
            directory=testCase.newDirectory(); options=getRealtimeDrivingConfig();
            options.UseTimer=false; options.enableLivePlot=false;
            options.enableRecording=true; options.recordingDirectory=directory;
            options.AllowSyntheticCalibration=true;
            imu=MockImuBrick2(); imu.FreezeCallback=true;
            monitor=RealtimeDrivingMonitor(imu, ...
                createTestImuCalibration(true),options,struct('assertRuntimeReady',@()[]));
            cleanup=onCleanup(@()delete(monitor));
            monitor.startManual();
            samples=MockImuBrick2.createStationarySequence(12,eye(3));
            imu.injectCallbackSamples(samples); monitor.poll(); summary=monitor.stop();
            testCase.verifyEqual(summary.samplesProcessed,12);
            testCase.verifyEqual(summary.recording.samplesWritten,12);
            testCase.verifyGreaterThanOrEqual(imu.DrainCallCount,4);
            metadata=jsondecode(fileread(fullfile(summary.recording.directory,'metadata.json')));
            testCase.verifyEqual(metadata.sessionFormatVersion,2);
            testCase.verifyEqual(string(metadata.status),"complete");
        end
        function autonomousRecorderModeRemainsAvailable(testCase)
            directory=testCase.newDirectory(); imu=MockImuBrick2();
            recorder=ImuSessionRecorder(imu,createTestImuCalibration(true), ...
                struct('directory',directory,'AllowSynthetic',true));
            cleanup=onCleanup(@()delete(recorder));
            recorder.start(); pause(0.03); recorder.poll(); recorder.stop();
            testCase.verifyGreaterThan(imu.DrainCallCount,0);
        end
    end
    methods(Access=private)
        function directory=newDirectory(testCase)
            directory=string(tempname); mkdir(directory);
            testCase.TemporaryDirectories(end+1,1)=directory;
        end
        function value=stats(~,received)
            value=struct('received',uint64(received),'overflowDropped',uint64(0), ...
                'coalesced',uint64(0),'staleSessionDropped',uint64(0));
        end
    end
end
