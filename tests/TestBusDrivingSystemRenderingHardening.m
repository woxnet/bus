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
            dashboard.selectTab("Data quality"); dashboard.render();
            dashboard.selectTab("Hardware acceptance"); dashboard.render();
            testCase.verifyEqual(source.FullSnapshotCalls,eventCalls);
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
