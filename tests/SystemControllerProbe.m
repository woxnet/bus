classdef SystemControllerProbe < handle
    properties
        HasCalibration=false
        CalibrationStarts=0
        CalibrationController=[]
        Monitor=[]
        CommitCalls=0
        Imus=FakeSystemImu.empty(0,1)
        AcceptanceAction=[]
    end
    methods
        function dependencies=getDependencies(obj)
            dependencies=struct('createImu',@()obj.createImu(), ...
                'createCalibrationController',@(~)obj.createCalibration(), ...
                'createRealtimeMonitor',@(~,~)obj.createMonitor(), ...
                'runPreflight',@(~)struct('success',true,'errors',strings(0,1)), ...
                'runAcceptance',@(options)obj.runAcceptance(options), ...
                'getCommit',@()obj.getCommit(), ...
                'nowUtc',@()datetime('now','TimeZone','UTC'), ...
                'loadCalibration',@()obj.loadCalibration(), ...
                'checkClassApi',@()[], 'createDashboard',@(~)[], ...
                'createTimer',@timer,'sleep',@pause);
        end
        function value=loadCalibration(obj)
            if obj.HasCalibration, value=struct('synthetic',true); else, value=[]; end
        end
        function value=createCalibration(obj)
            obj.CalibrationStarts=obj.CalibrationStarts+1; value=FakeSystemCalibrationController(); obj.CalibrationController=value;
        end
        function value=createMonitor(obj), value=FakeSystemMonitor(); obj.Monitor=value; end
        function value=createImu(obj), value=FakeSystemImu(); obj.Imus(end+1,1)=value; end
        function value=getCommit(obj)
            obj.CommitCalls=obj.CommitCalls+1; value="0123456789012345678901234567890123456789";
        end
        function value=runAcceptance(obj,options)
            if isempty(obj.AcceptanceAction), value=struct('success',true); return; end
            value=obj.AcceptanceAction(options);
        end
    end
end
