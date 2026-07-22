classdef TestRealtimeSignalFilter < matlab.unittest.TestCase
    methods(TestClassSetup)
        function setup(~), addpath(fullfile(fileparts(fileparts(mfilename('fullpath'))),'src')); end
    end
    methods(Test)
        function firstDerivativeIsNaNAndResetClearsState(testCase)
            filter=RealtimeSignalFilter(50,2.5,struct());
            first=filter.update(1); second=filter.update(2);
            testCase.verifyTrue(isnan(first.derivative)); testCase.verifyTrue(isfinite(second.derivative));
            filter.reset(); resetFirst=filter.update(3); testCase.verifyTrue(isnan(resetFirst.derivative));
        end
        function causalEmaUsesOnlyPastAndCurrentSamples(testCase)
            filter=RealtimeSignalFilter(50,2.5,struct()); filter.update(0);
            output=filter.update(1); expected=filter.Alpha;
            testCase.verifyEqual(output.filtered,expected,'AbsTol',1e-12);
        end
        function isolatedSpikeIsSuppressed(testCase)
            filter=RealtimeSignalFilter(50,2.5,struct());
            for index=1:4, filter.update(0); end
            output=filter.update(20); testCase.verifyTrue(output.outlierReplaced);
            testCase.verifyEqual(output.despiked,0);
        end
        function invalidValueDoesNotPoisonFilter(testCase)
            filter=RealtimeSignalFilter(50,2.5,struct()); filter.update(0);
            invalid=filter.update(NaN); next=filter.update(0);
            testCase.verifyFalse(invalid.valid); testCase.verifyTrue(next.valid);
        end
        function noSignalProcessingToolboxDependency(testCase)
            root=fileparts(fileparts(mfilename('fullpath')));
            source=string(fileread(fullfile(root,'src','RealtimeSignalFilter.m')));
            forbidden=["butter(","filtfilt(","lowpass(","designfilt(","sgolayfilt("];
            for value=forbidden, testCase.verifyFalse(contains(source,value,'IgnoreCase',true)); end
        end
    end
end
