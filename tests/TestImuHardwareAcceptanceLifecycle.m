classdef TestImuHardwareAcceptanceLifecycle < matlab.unittest.TestCase
    properties
        TemporaryDirectory
    end
    methods(TestClassSetup)
        function setup(testCase)
            root=fileparts(fileparts(mfilename('fullpath')));
            addpath(fullfile(root,'src'),fullfile(root,'tests'));
            testCase.TemporaryDirectory=tempname; mkdir(testCase.TemporaryDirectory);
            testCase.addTeardown(@()rmdir(testCase.TemporaryDirectory,'s'));
        end
    end
    methods(Test)
        function allOrdinarySamplesAreRead(testCase)
            [report,~]=testCase.runAcceptance();
            testCase.verifyGreaterThan(report.samplesRead,0);
            testCase.verifyEqual(report.samplesRead,report.received);
            testCase.verifyTrue(report.success);
        end
        function delayedCallbackAppearsAfterFirstEmptyDrain(testCase)
            imu=MockImuBrick2(); imu.DelayedTailSamples=testCase.sample();
            imu.InjectTailAfterEmptyDrainCount=1;
            [report,imu]=testCase.runAcceptance(imu);
            testCase.verifyGreaterThanOrEqual(imu.DrainCallCount,4);
            testCase.verifyTrue(report.success);
        end
        function delayedCallbackIsCountedInTail(testCase)
            imu=MockImuBrick2(); imu.DelayedTailSamples=repmat(testCase.sample(),2,1);
            imu.InjectTailAfterEmptyDrainCount=1;
            report=testCase.runAcceptance(imu);
            testCase.verifyEqual(report.tailSamplesDrained,2);
        end
        function callbackThroughTimeoutFailsAcceptance(testCase)
            imu=MockImuBrick2(); imu.TailSampleOnEveryDrain=testCase.sample();
            imu.TailDrainDelaySeconds=0.01;
            report=testCase.runAcceptance(imu);
            testCase.verifyTrue(report.stopDrainTimedOut);
            testCase.verifyFalse(report.success);
            testCase.verifyGreaterThan(report.tailSamplesDrained,0);
        end
        function samplesReadMatchesReceived(testCase)
            report=testCase.runAcceptance();
            testCase.verifyTrue(report.samplesReadMatchesReceived);
            testCase.verifyEqual(report.samplesRead,report.received);
        end
        function finalBufferIsEmpty(testCase)
            report=testCase.runAcceptance();
            testCase.verifyEqual(report.finalBufferedSamples,0);
            testCase.verifyEqual(double(report.finalCallbackStats.buffered),0);
        end
        function ownerIsReleased(testCase)
            [report,imu]=testCase.runAcceptance();
            testCase.verifyTrue(report.streamOwnerReleased);
            testCase.verifyEqual(imu.StreamOwner,"none");
            testCase.verifyFalse(imu.IsStreaming);
        end
        function drainFailureStillCleansLifecycle(testCase)
            imu=MockImuBrick2(); imu.FailDrainAt=2;
            testCase.verifyError(@()runImuHardwareAcceptance(imu,0.08, ...
                testCase.TemporaryDirectory),'MockImu:DrainFailure');
            testCase.verifyFalse(imu.IsStreaming);
            testCase.verifyEqual(imu.StreamOwner,"none");
            testCase.verifyGreaterThanOrEqual(imu.QuiesceCount,1);
            testCase.verifyGreaterThanOrEqual(imu.ClearCount,2);
        end
        function jsonContainsTailMetrics(testCase)
            report=testCase.runAcceptance(); decoded=jsondecode(fileread(report.jsonFile));
            fields={'tailSamplesDrained','stopDrainDurationSeconds','stopDrainTimedOut', ...
                'finalBufferedSamples','samplesReadMatchesReceived'};
            testCase.verifyTrue(all(isfield(decoded,fields)));
            testCase.verifyTrue(decoded.samplesReadMatchesReceived);
        end
    end
    methods(Access=private)
        function [report,imu]=runAcceptance(testCase,imu)
            if nargin<2, imu=MockImuBrick2(); end
            report=runImuHardwareAcceptance(imu,0.08,testCase.TemporaryDirectory);
        end
        function sample=sample(~)
            sample=MockImuBrick2.makeSample([0 0 -9.81],[0 0 0],[0 0 0]);
        end
    end
end
