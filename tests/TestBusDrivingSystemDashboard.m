classdef TestBusDrivingSystemDashboard < matlab.unittest.TestCase
    methods(TestClassSetup)
        function setup(~), root=fileparts(fileparts(mfilename('fullpath'))); addpath(fullfile(root,'src')); end
    end
    methods(Test)
        function configCapsRefreshRate(testCase)
            config=getBusDrivingSystemDashboardConfig(); testCase.verifyEqual(config.refreshHz,5); testCase.verifyLessThanOrEqual(config.maximumRefreshHz,10);
        end
        function dashboardNeverConsumesOrReprocessesSamples(testCase)
            source=string(fileread(which('BusDrivingSystemDashboard')));
            testCase.verifyFalse(contains(source,'drainCallbackSamples'));
            testCase.verifyFalse(contains(source,'applyMountCalibration'));
            testCase.verifyFalse(contains(source,'RealtimeEventState'));
        end
        function exposesAllTabs(testCase)
            source=SyntheticBusDrivingSystemController(); dashboard=BusDrivingSystemDashboard(source);
            testCase.addTeardown(@()delete(dashboard)); testCase.verifyEqual(numel(dashboard.getTabNames()),8);
        end
        function tabFlagsAreApplied(testCase)
            config=getBusDrivingSystemDashboardConfig(); config.enableCalibrationTab=false;
            config.enableRecordingTab=false; config.enableAcceptanceTab=false;
            source=SyntheticBusDrivingSystemController(config); dashboard=BusDrivingSystemDashboard(source,config);
            testCase.addTeardown(@()delete(dashboard));
            testCase.verifyEqual(dashboard.getTabNames(),["Overview","Signals","Events","Data quality","Log"]);
        end
        function graphicsHandlesPersistAndRenderedSeriesAreDecimated(testCase)
            config=getBusDrivingSystemDashboardConfig(); config.signalHistorySeconds=10;
            config.maximumRenderedPointsPerSeries=50; source=SyntheticBusDrivingSystemController(config);
            sample=struct('elapsedSeconds',0,'longitudinalRaw',0,'longitudinalFiltered',0, ...
                'lateralRaw',0,'lateralFiltered',0,'verticalRaw',0,'verticalFiltered',0, ...
                'yawRateRaw',0,'yawRateFiltered',0,'longitudinalJerk',0,'lateralJerk',0, ...
                'verticalJerk',0,'dataQuality',1,'callbackAgeMs',1,'effectiveFrequencyHz',50);
            for index=1:250, sample.elapsedSeconds=index/50; source.TelemetryHub.ingestSample(sample); end
            dashboard=BusDrivingSystemDashboard(source,config); testCase.addTeardown(@()delete(dashboard));
            dashboard.open(); before=dashboard.getGraphicsDiagnostics(); dashboard.render(); after=dashboard.getGraphicsDiagnostics();
            testCase.verifyTrue(all(isvalid(before.rawLines))); testCase.verifyEqual(before.rawLines,after.rawLines);
            testCase.verifyEqual(before.thresholdLines,after.thresholdLines);
            testCase.verifyLessThanOrEqual(numel(after.filteredLines(1).XData),50);
        end
        function slowRenderWarningIsThrottled(testCase)
            config=getBusDrivingSystemDashboardConfig(); config.maximumRenderMilliseconds=eps;
            source=SyntheticBusDrivingSystemController(config); fixed=datetime(2026,1,1,'TimeZone','UTC');
            dashboard=BusDrivingSystemDashboard(source,config,struct('nowUtc',@()fixed));
            testCase.addTeardown(@()delete(dashboard)); state=warning('off','IMU:SystemDashboardSlowRender');
            cleanup=onCleanup(@()warning(state)); %#ok<NASGU>
            dashboard.open(); dashboard.render(); dashboard.render(); snapshot=source.getTelemetrySnapshot();
            identifiers=strings(0,1);
            for index=1:numel(snapshot.warnings)
                payload=snapshot.warnings(index).payload;
                if isstruct(payload) && isfield(payload,'identifier'), identifiers(end+1,1)=string(payload.identifier); end %#ok<AGROW>
            end
            testCase.verifyEqual(sum(identifiers=="IMU:SystemDashboardSlowRender"),1);
        end
    end
end
