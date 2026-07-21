classdef FakeRealtimeRecorder < handle
    properties(SetAccess=private)
        IsRecording=false
        AppendedCount=0
        Deleted=false
        FinalizedWhileStreaming=false
    end
    properties
        FailOnStart=false
        FailOnStop=false
        StopDelaySeconds=0
        AdvanceClock=[]
    end
    properties(Access=private)
        Imu
    end
    methods
        function obj=FakeRealtimeRecorder(imu,failOnStart,failOnStop,advanceClock)
            obj.Imu=imu; obj.FailOnStart=failOnStart; obj.FailOnStop=failOnStop;
            if nargin>=4, obj.AdvanceClock=advanceClock; end
        end
        function startExternal(obj)
            if obj.FailOnStart, error('Test:RecorderStartFailure','Injected recorder start failure.'); end
            obj.IsRecording=true;
        end
        function appended=appendSample(obj,~,~)
            obj.AppendedCount=obj.AppendedCount+1; appended=true;
        end
        function summary=stopExternal(obj,stats)
            obj.FinalizedWhileStreaming=obj.Imu.IsStreaming;
            if obj.FailOnStop, error('Test:RecorderStopFailure','Injected recorder stop failure.'); end
            if ~isempty(obj.AdvanceClock), obj.AdvanceClock(obj.StopDelaySeconds); end
            obj.IsRecording=false; summary=struct('samplesWritten',obj.AppendedCount, ...
                'received',double(stats.received));
        end
        function delete(obj), obj.IsRecording=false; obj.Deleted=true; end
    end
end
