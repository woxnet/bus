classdef CalibrationPersistenceProbe < handle
    properties
        Mutation = "none"
        FailRollbackCopy = false
        CopyCount = 0
        MoveCount = 0
        FinalLoadCount = 0
    end
    methods
        function copyFile(obj,source,destination)
            obj.CopyCount=obj.CopyCount+1;
            if obj.FailRollbackCopy && obj.CopyCount>=2
                error('Test:RollbackCopyFailure','Injected rollback copy failure.');
            end
            [ok,message]=copyfile(source,destination,'f');
            if ~ok, error('Test:CopyFailure','%s',message); end
        end
        function moveFile(obj,source,destination)
            obj.MoveCount=obj.MoveCount+1;
            [ok,message]=movefile(source,destination,'f');
            if ~ok, error('Test:MoveFailure','%s',message); end
            if obj.Mutation=="none", return; end
            contents=load(destination,'calibration'); calibration=contents.calibration; %#ok<NASGU>
            if obj.Mutation=="corrupt"
                calibration.rotationVehicleFromSensor(1,1)=NaN;
            elseif obj.Mutation=="uid"
                calibration.metadata.imuUid="wrong_uid";
            elseif obj.Mutation=="bus"
                calibration.metadata.busId="wrong_bus";
            end
            save(destination,'calibration');
        end
        function calibration=loadCalibration(obj,filename,busId,uid,varargin)
            if endsWith(string(filename),"_imu_mount.mat") && ...
                    ~endsWith(string(filename),".inprogress.mat")
                obj.FinalLoadCount=obj.FinalLoadCount+1;
            end
            calibration=loadImuCalibration(filename,busId,uid,varargin{:});
        end
    end
end
