classdef TestBusDrivingSystemTelemetryHub < matlab.unittest.TestCase
    methods(TestClassSetup)
        function setup(~), root=fileparts(fileparts(mfilename('fullpath'))); addpath(fullfile(root,'src')); end
    end
    methods(Test)
        function sampleHistoryIsBoundedAfterHalfMillionSamples(testCase)
            config=getBusDrivingSystemDashboardConfig(); config.signalHistorySeconds=1;
            hub=BusDrivingSystemTelemetryHub(config); sample=struct('elapsedSeconds',0,'dataQuality',1);
            for k=1:500000, sample.elapsedSeconds=k/100; hub.ingestSample(sample); end
            testCase.verifyEqual(numel(hub.getSignalHistory()),50); testCase.verifyEqual(hub.SamplesIngested,500000);
        end
        function eventAndLogBuffersAreBounded(testCase)
            config=getBusDrivingSystemDashboardConfig(); config.maximumEventRows=3; config.maximumLogRows=4;
            hub=BusDrivingSystemTelemetryHub(config);
            for k=1:20
                event=struct('eventId',string(k),'type',"BRAKING_CANDIDATE"); hub.ingestEventCompleted(event);
                hub.ingestWarning(struct('type',"warning",'message',string(k)));
            end
            testCase.verifyEqual(numel(hub.getEvents()),3); testCase.verifyEqual(numel(hub.getLog()),4);
        end
        function ingestDoesNotRender(testCase)
            source=fileread(which('BusDrivingSystemTelemetryHub'));
            testCase.verifyFalse(contains(source,'drawnow')); testCase.verifyFalse(contains(source,'drainCallbackSamples'));
        end
    end
end
