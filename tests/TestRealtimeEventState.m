classdef TestRealtimeEventState < matlab.unittest.TestCase
    methods(TestClassSetup)
        function setup(~), addpath(fullfile(fileparts(fileparts(mfilename('fullpath'))),'src')); end
    end
    methods(Test)
        function shortEventIsDiscarded(testCase)
            config=getRealtimeDrivingConfig(); state=RealtimeEventState("BRAKING_CANDIDATE",config);
            state.update(testCase.sample(1,-2),true,false);
            for index=2:5, state.update(testCase.sample(index,-2),false,false); end
            [~,event]=state.update(testCase.sample(6,0),false,true);
            testCase.verifyEmpty(event);
        end
        function completedEventContainsCompatibleFields(testCase)
            config=getRealtimeDrivingConfig(); state=RealtimeEventState("BRAKING_CANDIDATE",config);
            state.update(testCase.sample(1,-2),true,false);
            for index=2:20, state.update(testCase.sample(index,-2),false,false); end
            [~,event]=state.update(testCase.sample(21,0),false,true);
            required={'eventId','type','startSequence','endSequence','startTimestamp', ...
                'endTimestamp','durationSeconds','peakAcceleration','meanAcceleration', ...
                'peakAbsoluteAcceleration','peakJerk','peakYawRate', ...
                'integratedAcceleration','sampleCount','missingSamplesInside', ...
                'outlierSamplesInside','dataQuality','thresholds'};
            testCase.verifyNotEmpty(event); testCase.verifyTrue(all(isfield(event,required)));
        end
        function hysteresisKeepsEventActive(testCase)
            config=getRealtimeDrivingConfig(); state=RealtimeEventState("ACCELERATION_CANDIDATE",config);
            state.update(testCase.sample(1,1.5),true,false);
            [changed,event]=state.update(testCase.sample(2,0.9),false,false);
            testCase.verifyFalse(changed); testCase.verifyEmpty(event); testCase.verifyTrue(state.IsActive);
        end
        function verticalShockMayBeShort(testCase)
            config=getRealtimeDrivingConfig(); state=RealtimeEventState("VERTICAL_SHOCK_CANDIDATE",config);
            sample=testCase.sample(1,0); sample.verticalFiltered=3;
            state.update(sample,true,false); event=state.terminate("threshold",0);
            testCase.verifyNotEmpty(event); testCase.verifyEqual(event.sampleCount,1);
        end
        function gapTerminationIsRecorded(testCase)
            config=getRealtimeDrivingConfig(); state=RealtimeEventState("BRAKING_CANDIDATE",config);
            for index=1:20, state.update(testCase.sample(index,-2),index==1,false); end
            event=state.terminate("sequence_gap",4);
            testCase.verifyEqual(event.terminationReason,"sequence_gap");
            testCase.verifyEqual(event.missingSamplesInside,4);
        end
    end
    methods(Access=private)
        function value=sample(~,sequence,acceleration)
            value=struct('sequenceNumber',uint64(sequence), ...
                'hostTimestamp',datetime('now','TimeZone','UTC'), ...
                'elapsedSeconds',(sequence-1)/50,'callbackAgeMs',1, ...
                'longitudinalFiltered',acceleration,'longitudinalJerk',0, ...
                'lateralFiltered',0,'lateralJerk',0,'verticalFiltered',0, ...
                'verticalJerk',0,'yawRateFiltered',0,'outlierReplaced',false);
        end
    end
end
