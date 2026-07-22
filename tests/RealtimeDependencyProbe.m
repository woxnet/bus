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
        SleepCalls=0
        FreeDiskBytes=Inf
        FreeDiskCalls=0
    end
    methods
        function value=dependencies(obj)
            value=struct('assertRuntimeReady',@()obj.assertRuntime(), ...
                'createTimer',@(varargin)obj.createTimer(varargin{:}), ...
                'createDashboard',@(monitor)obj.createDashboard(monitor), ...
                'createRecorder',@(imu,calibration,options)obj.createRecorder(imu,calibration,options), ...
                'monotonicClockStart',@()uint64(1), ...
                'monotonicClockElapsed',@(~)obj.elapsed(), ...
                'sleep',@(seconds)obj.sleep(seconds), ...
                'getFreeDiskBytes',@(~)obj.getFreeDiskBytes());
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
            recorder=FakeRealtimeRecorder(imu,obj.FailRecorderStart,obj.FailRecorderStop, ...
                @(seconds)obj.advanceClock(seconds)); obj.Recorder=recorder;
        end
        function value=elapsed(obj)
            value=obj.ClockElapsed; obj.ClockElapsed=obj.ClockElapsed+obj.ClockStep;
        end
        function sleep(obj,seconds)
            obj.SleepCalls=obj.SleepCalls+1;
            obj.advanceClock(seconds);
        end
        function advanceClock(obj,seconds)
            obj.ClockElapsed=obj.ClockElapsed+double(seconds);
        end
        function value=getFreeDiskBytes(obj)
            obj.FreeDiskCalls=obj.FreeDiskCalls+1; value=obj.FreeDiskBytes;
        end
    end
end
