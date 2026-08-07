classdef FakeAcceptanceCalibrationController < handle
    properties
        OnStateChanged=[]
        OnProgress=[]
        OnMessage=[]
        WorkflowOptions
        WorkflowDependencies
    end
    methods
        function obj=FakeAcceptanceCalibrationController(options,dependencies)
            obj.WorkflowOptions=options; obj.WorkflowDependencies=dependencies;
        end
        function result=runBlocking(obj)
            if isfield(obj.WorkflowDependencies,'confirm')
                assert(obj.WorkflowDependencies.confirm("Confirm calibration"));
            end
            obj.emit(struct('state',"SAMPLING",'phase',"stationary",'progress',.2, ...
                'message',"Stationary samples",'samplesCollected',10,'samplesRequired',50, ...
                'samplesRemaining',40,'quality',.7,'verification',NaN));
            obj.emit(struct('state',"SAMPLING",'phase',"forward",'progress',.6, ...
                'message',"Forward samples",'samplesCollected',40,'samplesRequired',50, ...
                'samplesRemaining',10,'quality',.8,'verification',NaN));
            obj.emit(struct('state',"VERIFYING",'phase',"verification_forward",'progress',.95, ...
                'message',"Verification samples",'samplesCollected',20,'samplesRequired',20, ...
                'samplesRemaining',0,'quality',.9,'verification',.95));
            calibration=struct('rotationVehicleFromSensor',eye(3),'bias',[0 0 0], ...
                'quality',struct('score',.9));
            result=struct('success',true,'errors',strings(0,1),'warnings',strings(0,1), ...
                'finalFile',"fake.mat",'backupFile',"",'verification',struct('success',true,'score',.95), ...
                'calibration',calibration);
        end
        function delete(~), end
    end
    methods(Access=private)
        function emit(obj,status)
            callbacks={obj.OnStateChanged,obj.OnProgress,obj.OnMessage};
            for index=1:numel(callbacks)
                if ~isempty(callbacks{index}), callbacks{index}(obj,status); end
            end
        end
    end
end
