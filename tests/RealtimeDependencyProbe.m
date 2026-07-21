classdef RealtimeDependencyProbe < handle
    properties
        FailRuntime=false
        FailRecorderCreate=false
        FailRecorderStart=false
        FailRecorderStop=false
        FailDashboardCreate=false
        FailDashboardOpen=false
        FailTimerCreate=false
        FailTimerStart=false
        RuntimeCalls=0
        TimerCreateCount=0
        Recorder=[]
        Dashboard=[]
        Timers=FakeRealtimeTimer.empty
        ClockElapsed=1
        ClockStep=0
    end
    methods
        function value=dependencies(obj)
            value=struct('assertRuntimeReady',@()obj.assertRuntime(), ...
                'createTimer',@(varargin)obj.createTimer(varargin{:}), ...
                'createDashboard',@(monitor)obj.createDashboard(monitor), ...
                'createRecorder',@(imu,calibration,options)obj.createRecorder(imu,calibration,options), ...
                'monotonicClockStart',@()uint64(1), ...
                'monotonicClockElapsed',@(~)obj.elapsed());
        end
        function assertRuntime(obj)
            obj.RuntimeCalls=obj.RuntimeCalls+1;
            if obj.FailRuntime, error('Test:RuntimeFailure','Injected runtime failure.'); end
        end
        function timerObject=createTimer(obj,varargin)
            obj.TimerCreateCount=obj.TimerCreateCount+1;
            if obj.FailTimerCreate, error('Test:TimerCreateFailure','Injected timer creation failure.'); end
            timerObject=FakeRealtimeTimer(obj.FailTimerStart,varargin{:});
            obj.Timers(end+1)=timerObject;
        end
        function dashboard=createDashboard(obj,~)
            if obj.FailDashboardCreate, error('Test:DashboardCreateFailure','Injected dashboard creation failure.'); end
            dashboard=FakeRealtimeDashboard(obj.FailDashboardOpen); obj.Dashboard=dashboard;
        end
        function recorder=createRecorder(obj,imu,~,~)
            if obj.FailRecorderCreate, error('Test:RecorderCreateFailure','Injected recorder creation failure.'); end
            recorder=FakeRealtimeRecorder(imu,obj.FailRecorderStart,obj.FailRecorderStop); obj.Recorder=recorder;
        end
        function value=elapsed(obj)
            value=obj.ClockElapsed; obj.ClockElapsed=obj.ClockElapsed+obj.ClockStep;
        end
    end
end
