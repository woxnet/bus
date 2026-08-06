classdef BusDrivingSystemController < handle
%BUSDRIVINGSYSTEMCONTROLLER Orchestrate calibration, monitoring and acceptance.
    properties(SetAccess=private)
        State="IDLE"
        CurrentStage=""
        StageProgress=0
        Message=""
        Mode="operation"
        StartedAt=NaT
        CompletedAt=NaT
        LastError=[]
        Imu=[]
        CalibrationController=[]
        RealtimeMonitor=[]
        AcceptanceResult=[]
        CheckoutCommit=""
        IsClosed=false
        IsConnected=false
    end
    properties
        OnStateChanged=[]
        OnStageStarted=[]
        OnStageProgress=[]
        OnStageCompleted=[]
        OnTelemetry=[]
        OnSample=[]
        OnEventStarted=[]
        OnEventCompleted=[]
        OnWarning=[]
        OnError=[]
        OnStopped=[]
        OnAcceptanceCompleted=[]
    end
    properties(SetAccess=private)
        TelemetryHub
    end
    properties(Access=private)
        Options
        Dependencies
        Calibration=[]
        Preflight=[]
        AcceptanceRunning=false
    end
    methods
        function obj=BusDrivingSystemController(options,dependencies)
            if nargin<1 || isempty(options), options=struct(); end
            if nargin<2, dependencies=struct(); end
            obj.Options=obj.mergeOptions(options);
            obj.Dependencies=obj.mergeDependencies(dependencies);
            obj.TelemetryHub=BusDrivingSystemTelemetryHub(obj.Options.dashboardConfig);
        end
        function startSystem(obj)
            obj.requireState(["IDLE","STOPPED","COMPLETED"]);
            if obj.IsClosed, error('IMU:SystemControllerClosed','Closed controller cannot be restarted.'); end
            if obj.IsConnected && ~isempty(obj.Imu), obj.disconnectImu(); end
            obj.StartedAt=obj.nowUtc(); obj.CompletedAt=NaT; obj.Mode="operation";
            try
                obj.transition("BOOTSTRAP","Bootstrap",0,"Starting system.");
                obj.CheckoutCommit=string(obj.Dependencies.getCommit());
                obj.TelemetryHub.updateMetadata(struct('checkoutCommit',obj.CheckoutCommit));
                obj.completeStage("Bootstrap","Bootstrap complete.");
                obj.transition("CHECKING_CLASS_API","Class API",0,"Checking MATLAB class API.");
                if isfield(obj.Dependencies,'checkClassApi'), obj.Dependencies.checkClassApi(); end
                obj.completeStage("Class API","Class API available.");
                obj.transition("CONNECTING_IMU","IMU",0,"Connecting IMU.");
                obj.Imu=obj.Dependencies.createImu();
                obj.IsConnected=true;
                metadata=struct('busId',string(obj.Options.busId));
                try, metadata.imuUid=string(obj.Imu.UID); catch, end
                obj.TelemetryHub.updateMetadata(metadata);
                obj.completeStage("IMU","IMU connected.");
                obj.runPreflight();
            catch exception
                obj.fail(exception); rethrow(exception);
            end
        end
        function runPreflight(obj)
            obj.requireState(["CONNECTING_IMU","PREFLIGHT","STOPPED"]);
            try
                obj.transition("PREFLIGHT","Preflight",0,"Running hardware preflight.");
                obj.Preflight=obj.Dependencies.runPreflight(obj.Imu);
                obj.TelemetryHub.updateMetadata(struct('preflight',obj.Preflight));
                if isstruct(obj.Preflight) && isfield(obj.Preflight,'success') && ~obj.Preflight.success
                    error('IMU:PreflightFailed','%s',obj.reportErrors(obj.Preflight));
                end
                obj.TelemetryHub.ingestState(struct('currentStage',"Preflight",'stageProgress',1, ...
                    'message',"Preflight passed."));
                obj.completeStage("Preflight","Preflight passed.");
                obj.checkCalibration();
            catch exception
                obj.fail(exception); rethrow(exception);
            end
        end
        function startCalibration(obj)
            obj.requireState(["CALIBRATION_REQUIRED","READY"]);
            if obj.monitorActive(), error('IMU:SystemBusy','Stop real-time monitoring before calibration.'); end
            try
                obj.transition("CALIBRATING","Calibration",0,"Calibration started by operator.");
                obj.CalibrationController=obj.Dependencies.createCalibrationController(obj.Imu);
                obj.attachCalibrationCallbacks();
                obj.CalibrationController.start();
            catch exception
                obj.fail(exception); rethrow(exception);
            end
        end
        function confirmCurrentStep(obj)
            if isempty(obj.CalibrationController), return; end
            obj.logOperator("confirm","Operator confirmed the current calibration step.");
            obj.CalibrationController.confirmCurrentStep();
        end
        function rejectCurrentStep(obj)
            if isempty(obj.CalibrationController), return; end
            obj.logOperator("reject","Operator rejected the current calibration step.");
            obj.CalibrationController.rejectCurrentStep();
        end
        function startRealtime(obj)
            obj.requireState(["READY","STOPPED"]);
            if obj.monitorActive(), error('IMU:RealtimeMonitorAlreadyRunning','A monitor is already active.'); end
            if isempty(obj.Calibration), obj.Calibration=obj.loadCalibration(); end
            try
                obj.transition("STARTING_REALTIME","Realtime",0,"Starting real-time monitor.");
                obj.RealtimeMonitor=obj.Dependencies.createRealtimeMonitor(obj.Imu,obj.Calibration);
                obj.attachMonitorCallbacks(); obj.RealtimeMonitor.start();
                obj.transition("STREAMING","Realtime",1,"Real-time monitoring active.");
            catch exception
                obj.fail(exception); rethrow(exception);
            end
        end
        function summary=stopRealtime(obj)
            if isempty(obj.RealtimeMonitor), summary=[]; return; end
            obj.transition("STOP_REQUESTED","Stopping",0,"Stop requested.");
            summary=obj.RealtimeMonitor.stop("operator_stop");
            if ~obj.RealtimeMonitor.IsRunning
                obj.transition("STOPPED","Result",1,"Real-time monitor stopped.");
            end
        end
        function runFullAcceptance(obj)
            if obj.monitorActive(), error('IMU:SystemBusy','Stop real-time monitoring before acceptance.'); end
            obj.Mode="acceptance";
            obj.transition("RUNNING_ACCEPTANCE","Hardware acceptance",0,"Hardware acceptance started.");
            obj.AcceptanceRunning=true; acceptanceCleanup=onCleanup(@()obj.clearAcceptanceRunning());
            try
                options=struct('Observer',@(event)obj.onAcceptanceEvent(event));
                obj.AcceptanceResult=obj.Dependencies.runAcceptance(options);
                obj.TelemetryHub.ingestAcceptanceResult(obj.AcceptanceResult);
                if isstruct(obj.AcceptanceResult) && isfield(obj.AcceptanceResult,'success') && obj.AcceptanceResult.success
                    obj.transition("COMPLETED","Result",1,"Hardware acceptance completed.");
                else
                    obj.transition("FAILED","Result",1,"Hardware acceptance failed.");
                end
                obj.emit(obj.OnAcceptanceCompleted,obj.AcceptanceResult);
                clear acceptanceCleanup;
                obj.AcceptanceRunning=false;
            catch exception
                obj.fail(exception); rethrow(exception);
            end
        end
        function cancel(obj)
            if ~isempty(obj.CalibrationController) && obj.CalibrationController.IsRunning
                obj.CalibrationController.cancel("operator_cancelled");
            elseif obj.monitorActive()
                obj.RealtimeMonitor.stop("operator_cancelled");
            end
            obj.transition("CANCELLED",obj.CurrentStage,obj.StageProgress,"Cancelled by operator.");
        end
        function close(obj)
            if obj.IsClosed, return; end
            if obj.monitorActive(), obj.stopRealtime(); end
            if ~isempty(obj.CalibrationController) && obj.CalibrationController.IsRunning
                obj.CalibrationController.close();
            end
            obj.clearOwnedCallbacks(); obj.disconnectImu();
            obj.RealtimeMonitor=[]; obj.CalibrationController=[]; obj.Imu=[];
            obj.IsClosed=true;
        end
        function status=getStatus(obj)
            status=struct('lifecycleState',obj.State,'currentStage',obj.CurrentStage, ...
                'stageProgress',obj.StageProgress,'message',obj.Message,'mode',obj.Mode, ...
                'startedAt',obj.StartedAt,'completedAt',obj.CompletedAt,'lastError',obj.LastError, ...
                'isRealtimeRunning',obj.monitorActive());
            status.isClosed=obj.IsClosed; status.isConnected=obj.IsConnected;
            status.isCalibrationRunning=~isempty(obj.CalibrationController) && obj.CalibrationController.IsRunning;
            status.isAcceptanceRunning=obj.AcceptanceRunning;
        end
        function snapshot=getTelemetrySnapshot(obj)
            snapshot=obj.TelemetryHub.getSnapshot();
        end
        function delete(obj), obj.close(); end
    end
    methods(Access=private)
        function clearAcceptanceRunning(obj), obj.AcceptanceRunning=false; end
        function checkCalibration(obj)
            obj.transition("CALIBRATION_CHECK","Calibration",0,"Checking installation calibration.");
            obj.Calibration=obj.loadCalibration();
            if isempty(obj.Calibration)
                obj.TelemetryHub.ingestCalibration(struct('state',"REQUIRED",'progress',0));
                obj.transition("CALIBRATION_REQUIRED","Calibration",0,"Installation calibration is required.");
            else
                obj.completeStage("Calibration","Installation calibration is available.");
                obj.transition("READY","Result",1,"System ready.");
            end
        end
        function calibration=loadCalibration(obj)
            calibration=[];
            try, calibration=obj.Dependencies.loadCalibration(); catch exception
                if ~strcmp(exception.identifier,'IMU:CalibrationNotFound'), rethrow(exception); end
            end
        end
        function attachCalibrationCallbacks(obj)
            c=obj.CalibrationController;
            c.OnStateChanged=@(~,s)obj.onCalibrationStatus(s);
            c.OnProgress=@(~,s)obj.onCalibrationStatus(s);
            c.OnMessage=@(~,s)obj.onCalibrationStatus(s);
            c.OnCompleted=@(~,r)obj.onCalibrationCompleted(r);
            c.OnCancelled=@(~,r)obj.onCalibrationCancelled(r);
            c.OnError=@(~,e)obj.onCalibrationError(e);
        end
        function onCalibrationStatus(obj,status)
            obj.TelemetryHub.ingestCalibration(status);
            state=string(status.state);
            if contains(upper(state),"VERIF") || (isfield(status,'phase') && contains(upper(string(status.phase)),"VERIF"))
                target="CALIBRATION_VERIFYING"; stage="Verification";
            else, target="CALIBRATING"; stage="Calibration"; end
            obj.transition(target,stage,status.progress,string(status.message));
        end
        function onCalibrationCompleted(obj,result)
            if isfield(result,'calibration')
                obj.Calibration=result.calibration;
                obj.TelemetryHub.ingestCalibration(struct('state',"READY",'progress',1, ...
                    'calibration',result.calibration));
            end
            obj.TelemetryHub.ingestCalibrationResult(result);
            obj.completeStage("Verification","Calibration verified.");
            obj.transition("READY","Result",1,"System ready.");
        end
        function onCalibrationCancelled(obj,result)
            obj.TelemetryHub.ingestCalibrationResult(result);
            obj.transition("CANCELLED","Calibration",obj.StageProgress,"Calibration cancelled.");
        end
        function onCalibrationError(obj,exception), obj.fail(exception); end
        function attachMonitorCallbacks(obj)
            m=obj.RealtimeMonitor;
            m.OnLifecycleChanged=@(~,s)obj.onMonitorLifecycle(s);
            m.OnSample=@(~,s)obj.forwardSample(s);
            m.OnEventStarted=@(~,e)obj.forwardEventStarted(e);
            m.OnEventCompleted=@(~,e)obj.forwardEventCompleted(e);
            m.OnWarning=@(~,w)obj.forwardWarning(w);
            m.OnError=@(~,e)obj.forwardError(e);
            m.OnStopped=@(~,s)obj.forwardStopped(s);
        end
        function onMonitorLifecycle(obj,status)
            obj.TelemetryHub.ingestMonitorStatus(status);
            lifecycle=string(status.lifecycleState);
            known=["STARTING","STREAM_CLAIMED","STREAMING","STOP_DEFERRED","STOPPING", ...
                "QUIESCING","DRAINING_TAIL","FINAL_STATS","FINALIZING_EVENTS", ...
                "FINALIZING_RECORDING","CLEARING_BUFFER","RELEASING_OWNER","STOPPED","FAILED"];
            if any(lifecycle==known)
                stage="Stopping"; if any(lifecycle==["STARTING","STREAM_CLAIMED","STREAMING"]), stage="Realtime"; end
                obj.transition(lifecycle,stage,obj.StageProgress,lifecycle);
            end
        end
        function forwardSample(obj,sample)
            obj.TelemetryHub.ingestSample(sample); obj.emit(obj.OnSample,sample);
        end
        function forwardEventStarted(obj,event), obj.TelemetryHub.ingestEventStarted(event); obj.emit(obj.OnEventStarted,event); end
        function forwardEventCompleted(obj,event), obj.TelemetryHub.ingestEventCompleted(event); obj.emit(obj.OnEventCompleted,event); end
        function forwardWarning(obj,value), obj.TelemetryHub.ingestWarning(value); obj.emit(obj.OnWarning,value); end
        function forwardError(obj,value), obj.TelemetryHub.ingestError(value); obj.emit(obj.OnError,value); end
        function forwardStopped(obj,summary)
            obj.TelemetryHub.ingestMonitorStatus(obj.RealtimeMonitor.getStatus());
            obj.emit(obj.OnStopped,summary);
        end
        function onAcceptanceEvent(obj,event)
            obj.TelemetryHub.ingestStage(event);
            if isfield(event,'stage'), obj.CurrentStage=string(event.stage); end
            if isfield(event,'progress'), obj.StageProgress=double(event.progress); end
            if isfield(event,'message'), obj.Message=string(event.message); end
            if isfield(event,'type')
                switch string(event.type)
                    case "stage_started", obj.emit(obj.OnStageStarted,event);
                    case "stage_completed", obj.emit(obj.OnStageCompleted,event);
                    case "stage_progress", obj.emit(obj.OnStageProgress,event);
                    case "warning", obj.forwardWarning(event);
                    case "error", obj.forwardError(event);
                end
            end
            obj.emitTelemetry();
        end
        function transition(obj,state,stage,progress,message)
            changed=obj.State~=string(state); obj.State=string(state); obj.CurrentStage=string(stage);
            obj.StageProgress=max(0,min(1,double(progress))); obj.Message=string(message);
            status=obj.getStatus(); obj.TelemetryHub.ingestState(status);
            if changed, obj.emit(obj.OnStateChanged,status); end
            obj.emit(obj.OnStageProgress,status); obj.emitTelemetry();
        end
        function completeStage(obj,stage,message)
            event=struct('timestamp',obj.nowUtc(),'type',"stage_completed",'stage',string(stage), ...
                'state',"PASSED",'progress',1,'message',string(message),'payload',struct());
            obj.TelemetryHub.ingestStage(event); obj.emit(obj.OnStageCompleted,event);
        end
        function emitTelemetry(obj), obj.emit(obj.OnTelemetry,obj.TelemetryHub.getSnapshot()); end
        function emit(obj,callback,payload)
            if isempty(callback), return; end
            try, callback(obj,payload); catch exception
                warning('IMU:SystemControllerCallbackFailed','User callback failed: %s',exception.message);
            end
        end
        function fail(obj,exception)
            obj.LastError=exception; obj.State="FAILED"; obj.Message=string(exception.message);
            obj.TelemetryHub.ingestError(exception); obj.emit(obj.OnError,exception); obj.emit(obj.OnStateChanged,obj.getStatus());
        end
        function requireState(obj,allowed)
            if ~any(obj.State==allowed), error('IMU:InvalidSystemState','Action is not valid in state %s.',obj.State); end
        end
        function active=monitorActive(obj)
            active=false;
            if isempty(obj.RealtimeMonitor) || ~isvalid(obj.RealtimeMonitor), return; end
            status=obj.RealtimeMonitor.getStatus();
            active=obj.RealtimeMonitor.IsRunning || status.isStopping;
        end
        function logOperator(obj,type,message)
            obj.TelemetryHub.ingestStage(struct('timestamp',obj.nowUtc(),'type',"operator_"+string(type), ...
                'stage',obj.CurrentStage,'state',obj.State,'progress',obj.StageProgress, ...
                'message',string(message),'payload',struct('source',"operator")));
        end
        function value=nowUtc(obj), value=obj.Dependencies.nowUtc(); end
        function text=reportErrors(~,report)
            text="Preflight failed."; if isfield(report,'errors'), text=strjoin(string(report.errors)," "); end
        end
        function options=mergeOptions(~,custom)
            imu=getImuConfig(); defaults=struct('busId',string(imu.busId), ...
                'calibrationDirectory',string(imu.calibrationDirectory), ...
                'realtimeOptions',struct(),'dashboardConfig',getBusDrivingSystemDashboardConfig());
            names=fieldnames(custom); options=defaults;
            for k=1:numel(names), options.(names{k})=custom.(names{k}); end
            options.dashboardConfig=validateBusDrivingSystemDashboardConfig(options.dashboardConfig);
        end
        function dependencies=mergeDependencies(obj,custom)
            imuConfig=getImuConfig();
            defaults=struct();
            defaults.createImu=@()ImuBrick2(imuConfig.uid,imuConfig.host,imuConfig.port);
            defaults.createCalibrationController=@(imu)obj.createDefaultCalibrationController(imu);
            defaults.createRealtimeMonitor=@(imu,calibration)obj.createDefaultRealtimeMonitor(imu,calibration);
            defaults.createDashboard=@(controller)BusDrivingSystemDashboard(controller);
            defaults.createTimer=@timer; defaults.runPreflight=@diagnoseImuBrick2UsingExistingConnection;
            defaults.runAcceptance=@runFullImuHardwareAcceptance; defaults.getCommit=@getImuAcceptanceCommit;
            defaults.nowUtc=@()datetime('now','TimeZone','UTC'); defaults.sleep=@pause;
            defaults.loadCalibration=@()loadSystemCalibration(obj.Options.busId,obj.Options.calibrationDirectory,imuConfig.uid);
            defaults.checkClassApi=@()assertImuAcceptanceClassApi();
            dependencies=defaults; names=fieldnames(custom);
            for k=1:numel(names), dependencies.(names{k})=custom.(names{k}); end
        end
        function monitor=createDefaultRealtimeMonitor(obj,imu,calibration)
            realtimeOptions=obj.Options.realtimeOptions;
            realtimeOptions.enableLivePlot=false;
            monitor=RealtimeDrivingMonitor(imu,calibration,realtimeOptions);
        end
        function controller=createDefaultCalibrationController(obj,imu)
            workflowOptions=getImuInstallationCalibrationWorkflowConfig();
            workflowOptions.enableDashboard=false;
            controller=ImuInstallationCalibrationController(imu,obj.Options.busId, ...
                obj.Options.calibrationDirectory,workflowOptions);
        end
        function disconnectImu(obj)
            if isempty(obj.Imu), obj.IsConnected=false; return; end
            try
                if ismethod(obj.Imu,'disconnect'), obj.Imu.disconnect(); end
            catch exception
                obj.TelemetryHub.ingestWarning(struct('type',"IMU_DISCONNECT_FAILED",'message',exception.message));
            end
            obj.IsConnected=false;
        end
        function clearOwnedCallbacks(obj)
            if ~isempty(obj.RealtimeMonitor) && isvalid(obj.RealtimeMonitor)
                names={'OnLifecycleChanged','OnSample','OnEventStarted','OnEventCompleted','OnWarning','OnError','OnStopped'};
                for k=1:numel(names), if isprop(obj.RealtimeMonitor,names{k}), obj.RealtimeMonitor.(names{k})=[]; end, end
            end
            if ~isempty(obj.CalibrationController) && isvalid(obj.CalibrationController)
                names={'OnStateChanged','OnProgress','OnMessage','OnCompleted','OnCancelled','OnError'};
                for k=1:numel(names), if isprop(obj.CalibrationController,names{k}), obj.CalibrationController.(names{k})=[]; end, end
            end
        end
    end
end

function calibration=loadSystemCalibration(busId,directory,uid)
file=resolveProjectPath(fullfile(directory,busId+"_imu_mount.mat"));
if ~isfile(file), error('IMU:CalibrationNotFound','Installation calibration was not found.'); end
calibration=loadImuCalibration(file,busId,uid);
end
