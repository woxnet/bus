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
    end
    properties(Access=private)
        Imu
    end
    methods
        function obj=FakeRealtimeRecorder(imu,failOnStart,failOnStop)
            obj.Imu=imu; obj.FailOnStart=failOnStart; obj.FailOnStop=failOnStop;
        end
        function startExternal(obj)
            if obj.FailOnStart, error('Test:RecorderStartFailure','Injected recorder start failure.'); end
            obj.IsRecording=true;
        end
        function appended=appendSample(obj,~,~)
            obj.AppendedCount=obj.AppendedCount+1; appended=true;
        end
        function summary=stopExternal(obj,~)
            obj.FinalizedWhileStreaming=obj.Imu.IsStreaming;
            if obj.FailOnStop, error('Test:RecorderStopFailure','Injected recorder stop failure.'); end
            obj.IsRecording=false; summary=struct('samplesWritten',obj.AppendedCount);
        end
        function delete(obj), obj.IsRecording=false; obj.Deleted=true; end
    end
end
