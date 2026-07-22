classdef FullAcceptanceProbe < handle
    properties
        Commit = "0123456789abcdef0123456789abcdef01234567"
        CalibrationCalls = 0
        RuntimeCalls = 0
        RealtimeCalls = 0
        CleanupCalls = 0
        FailCalibration = false
        CalibrationFile
    end
    methods
        function obj=FullAcceptanceProbe(directory)
            obj.CalibrationFile=fullfile(directory,'verified_calibration.mat');
            calibration=1; %#ok<NASGU>
            save(obj.CalibrationFile,'calibration');
        end
        function dependencies=dependencies(obj)
            dependencies=struct('assertClassApi',@()obj.api(), ...
                'getCommit',@()obj.Commit, ...
                'runCalibration',@()obj.calibration(), ...
                'runRuntime',@()obj.runtime(), ...
                'runRealtime',@()obj.realtime(), ...
                'summarize',@summarizeBusImuAcceptance);
        end
        function value=api(~)
            value=struct('imuBrick2Source',"mock/ImuBrick2.m", ...
                'controllerSource',"mock/Controller.m", ...
                'monitorSource',"mock/Monitor.m", ...
                'imuBrick2MethodsValid',true,'controllerMethodsValid',true, ...
                'monitorMethodsValid',true,'matlabRestartRequired',false);
        end
        function report=calibration(obj)
            obj.CalibrationCalls=obj.CalibrationCalls+1;
            cleanup=onCleanup(@()obj.cleaned()); %#ok<NASGU>
            if obj.FailCalibration
                error('Test:CalibrationInfrastructure','Injected calibration failure.');
            end
            report=obj.common(); report.calibrationFile=string(obj.CalibrationFile);
            report.verification=struct('success',true);
        end
        function report=runtime(obj)
            obj.RuntimeCalls=obj.RuntimeCalls+1;
            cleanup=onCleanup(@()obj.cleaned()); %#ok<NASGU>
            report=obj.common(); report.samplesReadMatchesReceived=true;
            report.stopDrainTimedOut=false; report.finalBufferedSamples=0;
        end
        function report=realtime(obj)
            obj.RealtimeCalls=obj.RealtimeCalls+1;
            cleanup=onCleanup(@()obj.cleaned()); %#ok<NASGU>
            report=obj.common();
        end
        function cleaned(obj), obj.CleanupCalls=obj.CleanupCalls+1; end
        function report=common(obj)
            report=struct('success',true,'commit',obj.Commit,'uid',"imu", ...
                'busId',"bus",'firmwareVersion',[2 0 15],'sensorFusionMode',2);
        end
    end
end
