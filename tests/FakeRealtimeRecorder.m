classdef FakeRealtimeRecorder < handle
    properties(SetAccess=private)
        IsRecording=false
        AppendedCount=0
        Deleted=false
        FinalizedWhileStreaming=false
        SessionBytes=0
        FinalizedStreamOwner=""
    end
    properties
        FailOnStart=false
        FailOnStop=false
        StopDelaySeconds=0
        AdvanceClock=[]
        FailOnAppendNumber=Inf
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
            attempt=obj.AppendedCount+1;
            if attempt==obj.FailOnAppendNumber
                error('Test:RecorderAppendFailure','Injected recorder append failure.');
            end
            obj.AppendedCount=attempt; obj.SessionBytes=obj.SessionBytes+1; appended=true;
        end
        function summary=stopExternal(obj,stats,status,reason)
            if nargin<3, status="complete"; end
            if nargin<4, reason="operator_stop"; end
            obj.FinalizedWhileStreaming=obj.Imu.IsStreaming;
            obj.FinalizedStreamOwner=string(obj.Imu.StreamOwner);
            if obj.FailOnStop, error('Test:RecorderStopFailure','Injected recorder stop failure.'); end
            if ~isempty(obj.AdvanceClock), obj.AdvanceClock(obj.StopDelaySeconds); end
            obj.IsRecording=false; summary=struct('samplesWritten',obj.AppendedCount, ...
                'received',double(stats.received),'status',string(status), ...
                'stopReason',string(reason));
        end
        function bytes=getSessionBytes(obj), bytes=obj.SessionBytes; end
        function delete(obj), obj.IsRecording=false; obj.Deleted=true; end
    end
end
