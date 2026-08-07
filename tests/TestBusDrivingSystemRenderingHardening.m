classdef TestBusDrivingSystemRenderingHardening < matlab.unittest.TestCase
    methods(TestClassSetup)
        function setup(~)
            root=fileparts(fileparts(mfilename('fullpath')));
            addpath(fullfile(root,'src'),fullfile(root,'tests'));
        end
    end
    methods(Test)
        function overviewUsesSummaryAndInvisibleTabsDoNotRender(testCase)
            config=getBusDrivingSystemDashboardConfig(); config.maximumRenderMilliseconds=1e6;
            source=DashboardSnapshotProbe(config); timerObject=[];
            dashboard=BusDrivingSystemDashboard(source,config,struct('createTimer',@createTimer));
            testCase.addTeardown(@()delete(dashboard)); dashboard.open();
            testCase.verifyEqual(source.FullSnapshotCalls,0); testCase.verifyTrue(isfinite(dashboard.InitialRenderMilliseconds));
            testCase.verifyEmpty(dashboard.RenderDurationHistory);
            handles=dashboard.getGraphicsDiagnostics(); handles.rawLines(1).XData=123;
            source.TelemetryHub.ingestSample(testCase.sample(1)); dashboard.render();
            testCase.verifyEqual(source.FullSnapshotCalls,0); testCase.verifyEqual(handles.rawLines(1).XData,123);
            dashboard.selectTab("Signals"); dashboard.render(); calls=source.FullSnapshotCalls;
            testCase.verifyGreaterThanOrEqual(calls,1); handles.rawLines(1).XData=999;
            dashboard.render(); testCase.verifyEqual(source.FullSnapshotCalls,calls);
            testCase.verifyEqual(handles.rawLines(1).XData,999);
            dashboard.selectTab("Events"); dashboard.render(); handles=dashboard.getGraphicsDiagnostics();
            eventCalls=source.FullSnapshotCalls; handles.eventTable.Data={'sentinel'};
            dashboard.render(); testCase.verifyEqual(source.FullSnapshotCalls,eventCalls);
            testCase.verifyEqual(handles.eventTable.Data,{'sentinel'});
            dashboard.selectTab("Data quality"); dashboard.render(); qualityCalls=source.FullSnapshotCalls;
            testCase.verifyGreaterThan(qualityCalls,eventCalls);
            dashboard.selectTab("Hardware acceptance"); dashboard.render();
            testCase.verifyEqual(source.FullSnapshotCalls,qualityCalls);
            testCase.verifyNotEmpty(dashboard.RenderDurationHistory);
            function value=createTimer(varargin), value=FakeRealtimeTimer(false,varargin{:}); timerObject=value; end %#ok<NASGU>
        end
        function droppedTicksAreReported(testCase)
            config=getBusDrivingSystemDashboardConfig(); config.maximumRenderMilliseconds=1e6;
            clock=MutableUtcClock(datetime(2026,1,1,'TimeZone','UTC')); timerObject=[];
            source=DashboardSnapshotProbe(config);
            dependencies=struct('createTimer',@createTimer,'nowUtc',@()clock.now());
            dashboard=BusDrivingSystemDashboard(source,config,dependencies); testCase.addTeardown(@()delete(dashboard));
            dashboard.open(); timerObject.fire(); clock.advance(seconds(.65)); timerObject.fire();
            testCase.verifyGreaterThanOrEqual(dashboard.DroppedRenderTicks,2);
            function value=createTimer(varargin), value=FakeRealtimeTimer(false,varargin{:}); timerObject=value; end
        end
        function dataQualityGraphsReceiveAndAdvanceHistory(testCase)
            config=getBusDrivingSystemDashboardConfig(); config.maximumRenderMilliseconds=1e6;
            source=DashboardSnapshotProbe(config); dashboard=BusDrivingSystemDashboard(source,config,struct('createTimer',@createTimer));
            testCase.addTeardown(@()delete(dashboard));
            for index=1:3, source.TelemetryHub.ingestSample(testCase.sample(index)); end
            dashboard.open(); dashboard.selectTab("Data quality"); dashboard.render();
            handles=dashboard.getGraphicsDiagnostics();
            testCase.verifyGreaterThan(numel(handles.qualityLines(1).XData),0);
            testCase.verifyGreaterThan(numel(handles.qualityLines(2).XData),0);
            testCase.verifyGreaterThan(numel(handles.qualityLines(4).XData),0);
            before=handles.qualityLines(1).XData; source.TelemetryHub.ingestSample(testCase.sample(4)); dashboard.render();
            testCase.verifyGreaterThan(numel(handles.qualityLines(1).XData),numel(before));
            function value=createTimer(varargin), value=FakeRealtimeTimer(false,varargin{:}); end
        end
        function failedRenderLeavesRevisionPendingForRetry(testCase)
            config=getBusDrivingSystemDashboardConfig(); config.maximumRenderMilliseconds=1e6;
            source=DashboardSnapshotProbe(config); source.TelemetryHub.ingestSample(testCase.sample(1));
            timerObject=[]; dashboard=BusDrivingSystemDashboard(source,config,struct('createTimer',@createTimer));
            testCase.addTeardown(@()delete(dashboard)); dashboard.open(); source.FailNextFullSnapshots=1;
            warningState=warning('off','IMU:SystemDashboardRenderFailed'); cleanup=onCleanup(@()warning(warningState)); %#ok<NASGU>
            dashboard.selectTab("Signals"); timerObject.fire(); diagnostics=dashboard.getGraphicsDiagnostics();
            testCase.verifyFalse(isfield(diagnostics.lastRenderedRevisions,'Signals_signalRevision'));
            timerObject.fire(); diagnostics=dashboard.getGraphicsDiagnostics();
            testCase.verifyTrue(isfield(diagnostics.lastRenderedRevisions,'Signals_signalRevision'));
            testCase.verifyGreaterThan(numel(diagnostics.rawLines(1).XData),0);
            function value=createTimer(varargin), value=FakeRealtimeTimer(false,varargin{:}); timerObject=value; end
        end
    end
    methods(Static,Access=private)
        function value=sample(index)
            value=struct('elapsedSeconds',index/50,'longitudinalRaw',1,'longitudinalFiltered',1, ...
                'lateralRaw',0,'lateralFiltered',0,'verticalRaw',0,'verticalFiltered',0, ...
                'yawRateRaw',0,'yawRateFiltered',0,'longitudinalJerk',0,'lateralJerk',0, ...
                'verticalJerk',0,'dataQuality',1,'callbackAgeMs',1,'effectiveFrequencyHz',50);
        end
    end
end
