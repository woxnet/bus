classdef FakeInstallationCalibrator < handle
    properties
        OnStatusChanged=[]
        OnProgress=[]
        OnMessage=[]
        CancelRequested=false
        QualityScore=1
    end
    methods
        function calibration=run(obj,saveFile,metadata,varargin) %#ok<INUSD>
            obj.emit("WAIT_STILL",.05,"Wait still");
            obj.emit("WAIT_STILL",.3,"Stationary sampling");
            obj.emit("WAIT_FORWARD_ACCELERATION",.5,"Accelerate forward");
            if obj.CancelRequested, error('IMU:CalibrationCancelled','Cancelled.'); end
            obj.emit("WAIT_FORWARD_ACCELERATION",.8,"Forward sampling");
            calibration=createTestImuCalibration(false);
            calibration.metadata=metadata;
            calibration.quality.score=obj.QualityScore;
            calibration.quality.valid=obj.QualityScore>=.75;
            save(saveFile,'calibration');
            if ~calibration.quality.valid
                error('IMU:CalibrationRejected','Injected low quality.');
            end
        end
        function cancel(obj), obj.CancelRequested=true; end
    end
    methods (Access=private)
        function emit(obj,state,progress,message)
            status=struct('state',state,'progress',progress,'message',message);
            callbacks={obj.OnStatusChanged,obj.OnProgress,obj.OnMessage};
            for index=1:numel(callbacks)
                if ~isempty(callbacks{index}), callbacks{index}(obj,status); end
            end
        end
    end
end
