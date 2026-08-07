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
        AcceptanceRunning=false
        LastRuntimeTelemetryRefresh=-Inf
        RuntimeTelemetryRefreshCount=0
        RunId=""
        RunSequence=0
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
        RuntimeTelemetryClock=[]
        ActiveOperationStages=strings(0,1)
        RealtimeStoppingStarted=false
        RealtimeStopFinalized=false
        RealtimeStoppedEmitted=false
        RealtimeStopSummary=[]
    end
    methods
        function obj=BusDrivingSystemController(options,dependencies)
            if nargin<1 || isempty(options), options=struct(); end
            if nargin<2, dependencies=struct(); end
            obj.Options=obj.mergeOptions(options);
            obj.Dependencies=obj.mergeDependencies(dependencies);
            obj.TelemetryHub=BusDrivingSystemTelemetryHub(obj.Options.dashboardConfig,obj.Dependencies.nowUtc);
            imuConfig=getImuConfig();
            obj.TelemetryHub.updateMetadata(struct('busId',string(obj.Options.busId), ...
                'configuredImuUid',string(imuConfig.uid),'dashboardConfig',obj.Options.dashboardConfig));
            obj.RuntimeTelemetryClock=obj.Dependencies.monotonicClockStart();
        end
        function startSystem(obj)
            obj.requireOpen(); obj.requireState(["IDLE","STOPPED","COMPLETED"]);
            if obj.IsConnected && ~isempty(obj.Imu), obj.disconnectImu(); end
            obj.beginRun("operation"); obj.Calibration=[]; obj.Preflight=[]; obj.AcceptanceResult=[];
            try
                obj.startStage("Bootstrap","Starting system.");
                obj.transition("BOOTSTRAP","Bootstrap",0,"Starting system.");
                obj.CheckoutCommit=string(obj.Dependencies.getCommit());
                obj.TelemetryHub.updateMetadata(struct('checkoutCommit',obj.CheckoutCommit));
                obj.completeStage("Bootstrap","Bootstrap complete.");
                obj.startStage("Class API","Checking MATLAB class API.");
                obj.transition("CHECKING_CLASS_API","Class API",0,"Checking MATLAB class API.");
                if isfield(obj.Dependencies,'checkClassApi'), obj.Dependencies.checkClassApi(); end
                obj.completeStage("Class API","Class API available.");
                obj.startStage("IMU","Connecting IMU.");
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
            obj.requireOpen(); obj.requireState(["CONNECTING_IMU","PREFLIGHT","STOPPED"]);
            try
                obj.startStage("Preflight","Running hardware preflight.");
                obj.transition("PREFLIGHT","Preflight",0,"Running hardware preflight.");
                obj.Preflight=obj.Dependencies.runPreflight(obj.Imu);
                obj.TelemetryHub.updateMetadata(struct('preflight',obj.Preflight));
                physical=struct('connection',struct('connected',obj.IsConnected));
                if isfield(obj.Preflight,'identity') && isstruct(obj.Preflight.identity)
                    physical.imuUid=string(obj.field(obj.Preflight.identity,'uid',""));
                end
                if isfield(obj.Preflight,'firmwareVersion'), physical.firmwareVersion=obj.Preflight.firmwareVersion; end
                if isfield(obj.Preflight,'sensorFusionMode'), physical.sensorFusionMode=obj.Preflight.sensorFusionMode; end
                obj.TelemetryHub.updateMetadata(physical);
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
            obj.requireOpen(); obj.requireState(["CALIBRATION_REQUIRED","READY"]);
            if obj.monitorActive(), error('IMU:SystemBusy','Stop real-time monitoring before calibration.'); end
            try
                obj.startStage("Calibration","Calibration started by operator.");
                obj.transition("CALIBRATING","Calibration",0,"Calibration started by operator.");
                obj.CalibrationController=obj.Dependencies.createCalibrationController(obj.Imu);
                obj.attachCalibrationCallbacks();
                obj.CalibrationController.start();
            catch exception
                obj.fail(exception); rethrow(exception);
            end
        end
        function confirmCurrentStep(obj)
            obj.requireOpen();
            if isempty(obj.CalibrationController), return; end
            obj.logOperator("confirm","Operator confirmed the current calibration step.");
            obj.CalibrationController.confirmCurrentStep();
        end
        function rejectCurrentStep(obj)
            obj.requireOpen();
            if isempty(obj.CalibrationController), return; end
            obj.logOperator("reject","Operator rejected the current calibration step.");
            obj.CalibrationController.rejectCurrentStep();
        end
        function startRealtime(obj)
            obj.requireOpen(); obj.requireState(["READY","STOPPED"]);
            if obj.monitorActive(), error('IMU:RealtimeMonitorAlreadyRunning','A monitor is already active.'); end
            if isempty(obj.Calibration), obj.Calibration=obj.loadCalibration(); end
            try
                obj.RealtimeStoppingStarted=false;
                obj.RealtimeStopFinalized=false;
                obj.RealtimeStoppedEmitted=false;
                obj.RealtimeStopSummary=[];
                obj.startStage("Realtime","Starting real-time monitor.");
                obj.transition("STARTING_REALTIME","Realtime",0,"Starting real-time monitor.");
                obj.RealtimeMonitor=obj.Dependencies.createRealtimeMonitor(obj.Imu,obj.Calibration);
                obj.attachMonitorCallbacks(); startupStarted=obj.monotonicElapsed(); obj.RealtimeMonitor.start();
                obj.TelemetryHub.updateMetadata(struct('realtimeStartupDurationSeconds', ...
                    obj.monotonicElapsed()-startupStarted));
                obj.transition("STREAMING","Realtime",1,"Real-time monitoring active.");
                obj.LastRuntimeTelemetryRefresh=-Inf;
                status=obj.refreshRealtimeTelemetry();
                if isstruct(status) && isfield(status,'recording') && ...
                        isstruct(status.recording) && obj.field(status.recording,'enabled',false)
                    obj.startStage("Recording","Recording active.");
                    obj.TelemetryHub.ingestState(obj.getStatus());
                end
            catch exception
                obj.fail(exception); rethrow(exception);
            end
        end
        function summary=stopRealtime(obj)
            obj.requireOpen();
            if isempty(obj.RealtimeMonitor), summary=[]; return; end
            if obj.RealtimeStopFinalized, summary=obj.RealtimeStopSummary; return; end
            obj.ensureRealtimeStoppingStarted("Stop requested.");
            obj.transition("STOP_REQUESTED","Stopping",0,"Stop requested.");
            summary=obj.RealtimeMonitor.stop("operator_stop");
            if ~obj.RealtimeMonitor.IsRunning, obj.finalizeRealtimeStop(summary); end
        end
        function runFullAcceptance(obj)
            obj.requireOpen();
            if obj.AcceptanceRunning, error('IMU:AcceptanceAlreadyRunning','Hardware acceptance is already running.'); end
            allowed=["IDLE","READY","STOPPED","COMPLETED"];
            if obj.monitorActive() || obj.calibrationActive() || ~any(obj.State==allowed)
                error('IMU:SystemBusy','Controller state %s cannot run hardware acceptance.',obj.State);
            end
            obj.prepareForHardwareAcceptance();
            obj.beginRun("acceptance"); obj.AcceptanceResult=[];
            obj.AcceptanceRunning=true; acceptanceCleanup=onCleanup(@()obj.clearAcceptanceRunning());
            obj.transition("RUNNING_ACCEPTANCE","Hardware acceptance",0,"Hardware acceptance started.");
            try
                options=struct('Observer',@(event)obj.onAcceptanceEvent(event), ...
                    'Confirm',obj.Dependencies.confirmAcceptanceCalibration);
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
            obj.requireOpen();
            if ~isempty(obj.CalibrationController) && obj.CalibrationController.IsRunning
                obj.CalibrationController.cancel("operator_cancelled");
            elseif obj.monitorActive()
                obj.RealtimeMonitor.stop("operator_cancelled");
            end
            obj.transition("CANCELLED",obj.CurrentStage,obj.StageProgress,"Cancelled by operator.");
        end
        function close(obj)
            if obj.IsClosed, return; end
            if obj.AcceptanceRunning
                error('IMU:AcceptanceInProgress','Cannot close controller while hardware acceptance is running.');
            end
            if obj.monitorActive(), obj.stopRealtime(); end
            if obj.calibrationActive()
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
            status.isCalibrationRunning=obj.calibrationActive();
            status.isAcceptanceRunning=obj.AcceptanceRunning;
            status.actions=obj.actionModel();
        end
        function snapshot=getTelemetrySnapshot(obj)
            snapshot=obj.TelemetryHub.getSnapshot();
        end
        function snapshot=getSummarySnapshot(obj)
            snapshot=obj.TelemetryHub.getSummarySnapshot();
            snapshot.actions=obj.actionModel();
        end
        function status=refreshRealtimeTelemetry(obj)
            obj.requireOpen();
            status=[]; if isempty(obj.RealtimeMonitor) || ~isvalid(obj.RealtimeMonitor), return; end
            allowed=["STREAMING","STOP_REQUESTED","STOP_DEFERRED","STOPPING","QUIESCING", ...
                "DRAINING_TAIL","FINAL_STATS","FINALIZING_EVENTS","FINALIZING_RECORDING", ...
                "CLEARING_BUFFER","RELEASING_OWNER"];
            if ~any(obj.State==allowed), return; end
            nowValue=obj.monotonicElapsed(); minimumPeriod=1/obj.Options.dashboardConfig.refreshHz;
            if nowValue-obj.LastRuntimeTelemetryRefresh<minimumPeriod, return; end
            status=obj.RealtimeMonitor.getStatus(); obj.TelemetryHub.ingestMonitorStatus(status);
            obj.LastRuntimeTelemetryRefresh=nowValue;
            obj.RuntimeTelemetryRefreshCount=obj.RuntimeTelemetryRefreshCount+1;
        end
        function delete(obj)
            try, obj.close(); catch, end
        end
    end
    methods(Access=private)
        function clearAcceptanceRunning(obj), obj.AcceptanceRunning=false; end
        function checkCalibration(obj)
            obj.startStage("Calibration","Checking installation calibration.");
            obj.transition("CALIBRATION_CHECK","Calibration",0,"Checking installation calibration.");
            obj.Calibration=obj.loadCalibration();
            if isempty(obj.Calibration)
                obj.TelemetryHub.ingestCalibration(struct('required',true,'state',"REQUIRED",'progress',0));
                obj.transition("CALIBRATION_REQUIRED","Calibration",0,"Installation calibration is required.");
            else
                obj.TelemetryHub.ingestCalibration(struct('required',false,'state',"READY",'progress',1));
                obj.completeStage("Calibration","Installation calibration is available.");
                obj.startStage("Verification","Validating installation calibration.");
                obj.completeStage("Verification","Installation calibration validated.");
                obj.startStage("Result","Finalizing system readiness.");
                obj.transition("READY","Result",1,"System ready.");
                obj.completeStage("Result","System ready.");
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
                obj.completeStage("Calibration","Calibration samples collected.");
                obj.startStage("Verification","Verifying installation calibration.");
                target="CALIBRATION_VERIFYING"; stage="Verification";
            else, target="CALIBRATING"; stage="Calibration"; end
            obj.transition(target,stage,status.progress,string(status.message));
        end
        function onCalibrationCompleted(obj,result)
            if isfield(result,'calibration')
                obj.Calibration=result.calibration;
            end
            calibrationStatus=struct('required',false,'state',"READY",'progress',1);
            if isfield(result,'calibration'), calibrationStatus.calibration=result.calibration; end
            obj.TelemetryHub.ingestCalibration(calibrationStatus);
            obj.TelemetryHub.ingestCalibrationResult(result);
            obj.completeStage("Calibration","Calibration completed.");
            obj.startStage("Verification","Finalizing calibration verification.");
            obj.completeStage("Verification","Calibration verified.");
            obj.startStage("Result","Finalizing system readiness.");
            obj.transition("READY","Result",1,"System ready.");
            obj.completeStage("Result","System ready.");
        end
        function onCalibrationCancelled(obj,result)
            obj.TelemetryHub.ingestCalibrationResult(result);
            reason=string(obj.field(result,'cancelReason',"calibration_cancelled"));
            obj.cancelStage("Calibration",reason); obj.cancelStage("Verification",reason);
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
            if obj.RealtimeStopFinalized, return; end
            known=["STARTING","STREAM_CLAIMED","STREAMING","STOP_DEFERRED","STOPPING", ...
                "QUIESCING","DRAINING_TAIL","FINAL_STATS","FINALIZING_EVENTS", ...
                "FINALIZING_RECORDING","CLEARING_BUFFER","RELEASING_OWNER","STOPPED","FAILED"];
            if ~any(lifecycle==known), return; end
            if any(lifecycle==["STOP_DEFERRED","STOPPING","QUIESCING","DRAINING_TAIL", ...
                    "FINAL_STATS","FINALIZING_EVENTS","FINALIZING_RECORDING", ...
                    "CLEARING_BUFFER","RELEASING_OWNER"])
                obj.ensureRealtimeStoppingStarted(lifecycle);
                obj.transition(lifecycle,"Stopping",obj.StageProgress,lifecycle);
            elseif lifecycle=="STOPPED"
                obj.finalizeRealtimeStop([]);
            elseif lifecycle=="FAILED"
                obj.finalizeRealtimeFailure(status);
            else
                obj.transition(lifecycle,"Realtime",obj.StageProgress,lifecycle);
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
            obj.finalizeRealtimeStop(summary);
        end
        function ensureRealtimeStoppingStarted(obj,message)
            if obj.RealtimeStoppingStarted || obj.RealtimeStopFinalized, return; end
            obj.RealtimeStoppingStarted=true;
            obj.startStage("Stopping",string(message));
        end
        function finalizeRealtimeStop(obj,summary)
            if obj.State=="FAILED", return; end
            if ~isempty(summary), obj.RealtimeStopSummary=summary; end
            if ~obj.RealtimeStopFinalized
                obj.ensureRealtimeStoppingStarted("Real-time monitor is stopping.");
                obj.RealtimeStopFinalized=true;
                obj.completeStage("Recording","Recording finalized.");
                obj.completeStage("Realtime","Real-time monitoring completed.");
                obj.completeStage("Stopping","Real-time monitor stopped safely.");
                obj.startStage("Result","Finalizing operation result.");
                obj.transition("STOPPED","Result",1,"Real-time monitor stopped.");
                obj.completeStage("Result","Operation result finalized.");
                obj.CompletedAt=obj.nowUtc();
            end
            if ~isempty(summary) && ~obj.RealtimeStoppedEmitted
                obj.RealtimeStoppedEmitted=true;
                obj.emit(obj.OnStopped,summary);
            end
        end
        function finalizeRealtimeFailure(obj,status)
            if obj.RealtimeStopFinalized, return; end
            obj.ensureRealtimeStoppingStarted("Real-time monitor failed.");
            obj.RealtimeStopFinalized=true;
            reason=string(obj.field(status,'stopReason',obj.field(status,'message',"Real-time monitor failed.")));
            if strlength(reason)==0, reason="Real-time monitor failed."; end
            exception=MException('IMU:RealtimeMonitorFailed','%s',reason);
            obj.failStage("Recording",exception);
            obj.failStage("Realtime",exception);
            obj.failStage("Stopping",exception);
            obj.fail(exception);
        end
        function prepareForHardwareAcceptance(obj)
            if obj.monitorActive() || obj.calibrationActive()
                error('IMU:SystemBusy','Active operation hardware cannot be transferred to acceptance.');
            end
            obj.clearOwnedCallbacks();
            obj.disconnectImu(true);
            obj.RealtimeMonitor=[];
            obj.CalibrationController=[];
            obj.Imu=[];
            obj.IsConnected=false;
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
            if obj.Mode=="operation" && any(obj.ActiveOperationStages==string(stage))
                event=struct('timestamp',obj.nowUtc(),'type',"stage_progress",'stage',string(stage), ...
                    'state',string(state),'progress',obj.StageProgress,'message',string(message), ...
                    'payload',struct('source',"controller"));
                obj.TelemetryHub.ingestStage(event);
            end
            if changed, obj.emit(obj.OnStateChanged,status); end
            obj.emit(obj.OnStageProgress,status); obj.emitTelemetry();
        end
        function completeStage(obj,stage,message)
            stage=string(stage);
            if ~any(obj.ActiveOperationStages==stage), return; end
            event=struct('timestamp',obj.nowUtc(),'type',"stage_completed",'stage',string(stage), ...
                'state',"PASSED",'progress',1,'message',string(message), ...
                'payload',struct('source',"controller"));
            obj.TelemetryHub.ingestStage(event); obj.emit(obj.OnStageCompleted,event);
            obj.ActiveOperationStages(obj.ActiveOperationStages==stage)=[];
        end
        function cancelStage(obj,stage,reason)
            stage=string(stage); if obj.Mode~="operation" || ~any(obj.ActiveOperationStages==stage), return; end
            event=struct('timestamp',obj.nowUtc(),'type',"stage_cancelled",'stage',stage, ...
                'state',"CANCELLED",'progress',obj.StageProgress,'message',string(reason), ...
                'payload',struct('cancelReason',string(reason),'source',"controller"),'runId',obj.RunId);
            obj.TelemetryHub.ingestStage(event); obj.emit(obj.OnStageCompleted,event);
            obj.ActiveOperationStages(obj.ActiveOperationStages==stage)=[];
        end
        function startStage(obj,stage,message)
            stage=string(stage); if obj.Mode~="operation" || any(obj.ActiveOperationStages==stage), return; end
            event=struct('timestamp',obj.nowUtc(),'type',"stage_started",'stage',stage, ...
                'state',"RUNNING",'progress',0,'message',string(message), ...
                'payload',struct('source',"controller"));
            obj.ActiveOperationStages(end+1,1)=stage;
            obj.TelemetryHub.ingestStage(event); obj.emit(obj.OnStageStarted,event);
        end
        function failStage(obj,stage,exception)
            stage=string(stage); if obj.Mode~="operation" || ~any(obj.ActiveOperationStages==stage), return; end
            event=struct('timestamp',obj.nowUtc(),'type',"stage_failed",'stage',stage, ...
                'state',"FAILED",'progress',obj.StageProgress,'message',string(exception.message), ...
                'payload',struct('identifier',string(exception.identifier),'source',"controller"));
            obj.TelemetryHub.ingestStage(event); obj.ActiveOperationStages(obj.ActiveOperationStages==stage)=[];
        end
        function emitTelemetry(obj), obj.emit(obj.OnTelemetry,obj.TelemetryHub.getSnapshot()); end
        function emit(obj,callback,payload)
            if isempty(callback), return; end
            try, callback(obj,payload); catch exception
                warning('IMU:SystemControllerCallbackFailed','User callback failed: %s',exception.message);
            end
        end
        function fail(obj,exception)
            if obj.State=="FAILED" && ~isempty(obj.LastError) && ...
                    strcmp(obj.LastError.identifier,exception.identifier) && strcmp(obj.LastError.message,exception.message)
                return;
            end
            obj.failStage(obj.CurrentStage,exception);
            obj.State="FAILED"; obj.CompletedAt=obj.nowUtc(); obj.Message=string(exception.message); obj.LastError=exception;
            status=obj.getStatus(); status.severity="error";
            obj.TelemetryHub.ingestError(exception); obj.TelemetryHub.ingestState(status);
            obj.emit(obj.OnError,exception); obj.emit(obj.OnStateChanged,status); obj.emitTelemetry();
        end
        function requireState(obj,allowed)
            if ~any(obj.State==allowed), error('IMU:InvalidSystemState','Action is not valid in state %s.',obj.State); end
        end
        function requireOpen(obj)
            if obj.IsClosed, error('IMU:SystemControllerClosed','Closed controller cannot perform this action.'); end
        end
        function active=monitorActive(obj)
            active=false;
            if isempty(obj.RealtimeMonitor) || ~isvalid(obj.RealtimeMonitor), return; end
            stopping=["STOP_REQUESTED","STOP_DEFERRED","STOPPING","QUIESCING","DRAINING_TAIL", ...
                "FINAL_STATS","FINALIZING_EVENTS","FINALIZING_RECORDING","CLEARING_BUFFER","RELEASING_OWNER"];
            active=obj.RealtimeMonitor.IsRunning || any(obj.State==stopping);
        end
        function active=calibrationActive(obj)
            active=false;
            if isempty(obj.CalibrationController) || ~isvalid(obj.CalibrationController), return; end
            active=logical(obj.CalibrationController.IsRunning);
        end
        function actions=actionModel(obj)
            state=string(obj.State); closed=obj.IsClosed; monitor=obj.monitorActive();
            calibration=obj.calibrationActive(); acceptance=obj.AcceptanceRunning;
            actions=struct();
            actions.canStartSystem=~closed && ~acceptance && any(state==["IDLE","STOPPED","COMPLETED"]);
            actions.canRunPreflight=~closed && ~acceptance && any(state==["CONNECTING_IMU","PREFLIGHT","STOPPED"]);
            actions.canStartCalibration=~closed && ~monitor && ~acceptance && any(state==["CALIBRATION_REQUIRED","READY"]);
            actions.canConfirmCalibration=~closed && calibration && any(state==["CALIBRATING","CALIBRATION_VERIFYING"]);
            actions.canRejectCalibration=actions.canConfirmCalibration;
            actions.canStartRealtime=~closed && ~monitor && ~calibration && ~acceptance && any(state==["READY","STOPPED"]);
            actions.canStopRealtime=~closed && monitor;
            actions.canRunAcceptance=~closed && ~monitor && ~calibration && ~acceptance && any(state==["IDLE","READY","STOPPED","COMPLETED"]);
            actions.canSaveSnapshot=~closed;
            actions.canClose=~closed;
        end
        function logOperator(obj,type,message)
            obj.TelemetryHub.ingestStage(struct('timestamp',obj.nowUtc(),'type',"operator_"+string(type), ...
                'stage',obj.CurrentStage,'state',obj.State,'progress',obj.StageProgress, ...
                'message',string(message),'payload',struct('source',"operator")));
        end
        function beginRun(obj,mode)
            obj.RunSequence=obj.RunSequence+1; obj.Mode=string(mode);
            obj.StartedAt=obj.nowUtc(); obj.CompletedAt=NaT; obj.LastError=[];
            stamp=string(obj.StartedAt,'yyyyMMdd''T''HHmmssSSS''Z''');
            prefix="system"; if obj.Mode=="acceptance", prefix="acceptance"; end
            obj.RunId=prefix+"_"+stamp+"_"+string(obj.RunSequence);
            obj.ActiveOperationStages=strings(0,1);
            obj.TelemetryHub.beginRun(struct('runId',obj.RunId,'runSequence',obj.RunSequence, ...
                'runMode',obj.Mode,'runStartedAt',obj.StartedAt));
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
            defaults.monotonicClockStart=@tic; defaults.monotonicClockElapsed=@toc;
            defaults.confirmAcceptanceCalibration=@confirmAcceptanceCalibration;
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
        function disconnectImu(obj,strict)
            if nargin<2, strict=false; end
            if isempty(obj.Imu), obj.IsConnected=false; return; end
            try
                if ismethod(obj.Imu,'disconnect'), obj.Imu.disconnect(); end
            catch exception
                obj.TelemetryHub.ingestWarning(struct('type',"IMU_DISCONNECT_FAILED",'message',exception.message));
                if strict
                    obj.IsConnected=true;
                    rethrow(exception);
                end
            end
            obj.IsConnected=false;
        end
        function value=monotonicElapsed(obj)
            value=double(obj.Dependencies.monotonicClockElapsed(obj.RuntimeTelemetryClock));
        end
        function value=field(~,s,name,default)
            value=default; if isstruct(s) && isfield(s,name), value=s.(name); end
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

function confirmed=confirmAcceptanceCalibration(prompt)
answer=questdlg(char(prompt),'Hardware acceptance calibration','Confirm','Cancel','Cancel');
confirmed=strcmp(answer,'Confirm');
end

function calibration=loadSystemCalibration(busId,directory,uid)
file=resolveProjectPath(fullfile(directory,busId+"_imu_mount.mat"));
if ~isfile(file), error('IMU:CalibrationNotFound','Installation calibration was not found.'); end
calibration=loadImuCalibration(file,busId,uid);
end
