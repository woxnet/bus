classdef FakeSystemCalibrationController < handle
    properties
        IsRunning=false
        OnStateChanged=[]
        OnProgress=[]
        OnMessage=[]
        OnCompleted=[]
        OnCancelled=[]
        OnError=[]
        Confirmed=false
        Rejected=false
    end
    methods
        function start(obj)
            obj.IsRunning=true;
            s=struct('state',"SAMPLING",'phase',"stationary",'progress',.25, ...
                'message',"Collecting",'samplesRequired',100,'samplesCollected',25,'samplesRemaining',75);
            if ~isempty(obj.OnStateChanged), obj.OnStateChanged(obj,s); end
        end
        function complete(obj)
            obj.IsRunning=false; result=struct('success',true,'calibration',struct('synthetic',true));
            if ~isempty(obj.OnCompleted), obj.OnCompleted(obj,result); end
        end
        function confirmCurrentStep(obj), obj.Confirmed=true; end
        function rejectCurrentStep(obj), obj.Rejected=true; end
        function cancel(obj,varargin), obj.IsRunning=false; if ~isempty(obj.OnCancelled), obj.OnCancelled(obj,struct()); end, end
        function close(obj), obj.IsRunning=false; end
    end
end
