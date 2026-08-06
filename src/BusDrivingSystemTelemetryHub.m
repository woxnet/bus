classdef BusDrivingSystemTelemetryHub < handle
%BUSDRIVINGSYSTEMTELEMETRYHUB Bounded, acquisition-independent UI model.
    properties(SetAccess=private)
        Config
        SamplesIngested=0
        EventsIngested=0
        LogsIngested=0
    end
    properties(Access=private)
        Snapshot
        Samples
        SampleIndex=0
        SampleCount=0
        Events
        EventIndex=0
        EventCount=0
        Logs
        LogIndex=0
        LogCount=0
        Stages
        StageIndex=0
        StageCount=0
        LastLoggedLifecycleState=""
        LastLoggedStage=""
        LastLoggedMessage=""
        LastLoggedSeverity=""
    end
    methods
        function obj=BusDrivingSystemTelemetryHub(config)
            if nargin<1 || isempty(config), config=getBusDrivingSystemDashboardConfig(); end
            obj.Config=validateBusDrivingSystemDashboardConfig(config);
            capacity=max(1,ceil(config.signalHistorySeconds*config.sampleRateHz));
            obj.Samples=cell(capacity,1); obj.Events=cell(config.maximumEventRows,1);
            obj.Logs=cell(config.maximumLogRows,1); obj.Stages=cell(config.maximumStageHistory,1);
            obj.Snapshot=obj.emptySnapshot();
        end
        function ingestState(obj,status)
            if ~isstruct(status), return; end
            obj.copyField(status,'lifecycleState'); obj.copyField(status,'currentStage');
            obj.copyField(status,'stageProgress'); obj.copyField(status,'message');
            obj.copyField(status,'mode');
            severity=obj.value(status,'severity',obj.Snapshot.severity);
            changed=obj.LastLoggedLifecycleState~=string(obj.Snapshot.lifecycleState) || ...
                obj.LastLoggedStage~=string(obj.Snapshot.currentStage) || ...
                obj.LastLoggedMessage~=string(obj.Snapshot.message) || ...
                obj.LastLoggedSeverity~=string(severity);
            if changed
                obj.appendLog(severity,"controller",obj.Snapshot.currentStage,"lifecycle", ...
                    obj.Snapshot.lifecycleState+": "+obj.Snapshot.message,status);
                obj.LastLoggedLifecycleState=string(obj.Snapshot.lifecycleState);
                obj.LastLoggedStage=string(obj.Snapshot.currentStage);
                obj.LastLoggedMessage=string(obj.Snapshot.message);
                obj.LastLoggedSeverity=string(severity);
            end
        end
        function ingestStage(obj,event)
            if ~isstruct(event), return; end
            if ~isfield(event,'startedAt'), event.startedAt=obj.value(event,'timestamp',datetime('now','TimeZone','UTC')); end
            if ~isfield(event,'completedAt'), event.completedAt=NaT; end
            if ~isfield(event,'elapsedSeconds'), event.elapsedSeconds=0; end
            obj.Stages=obj.put(obj.Stages,event,'StageIndex','StageCount');
            if isfield(event,'stage'), obj.Snapshot.currentStage=string(event.stage); end
            if isfield(event,'progress'), obj.Snapshot.stageProgress=double(event.progress); end
            if isfield(event,'message'), obj.Snapshot.message=string(event.message); end
            source="acceptance";
            if isfield(event,'payload') && isstruct(event.payload), source=obj.value(event.payload,'source',source); end
            obj.appendLog("info",source,obj.value(event,'stage',""), ...
                obj.value(event,'type',"acceptance"),obj.value(event,'message',""),event);
        end
        function ingestCalibration(obj,status)
            if ~isstruct(status), return; end
            map={'state','state';'phase','phase';'progress','progress'; ...
                'samplesRequired','samplesRequired';'samplesCollected','samplesCollected'; ...
                'samplesRemaining','samplesRemaining';'quality','qualityScore'; ...
                'verification','verificationScore';'finalFile','finalFile'; ...
                'workingFile','workingFile';'backupFile','backupFile'};
            for k=1:size(map,1)
                if isfield(status,map{k,1}), obj.Snapshot.calibration.(map{k,2})=status.(map{k,1}); end
            end
            if isfield(status,'calibration') && isstruct(status.calibration) && ...
                    isfield(status.calibration,'rotationVehicleFromSensor')
                obj.Snapshot.calibration.rotationVehicleFromSensor= ...
                    status.calibration.rotationVehicleFromSensor;
            end
            if isfield(status,'message'), obj.Snapshot.message=string(status.message); end
        end
        function ingestCalibrationResult(obj,result)
            if ~isstruct(result), return; end
            c=obj.Snapshot.calibration;
            names={'verificationPerformed','activationAttempted','activationVerified', ...
                'verificationPassed','verificationScore','rollbackAttempted','rollbackSucceeded', ...
                'finalFile','workingFile','backupFile','cancelReason','rotationVehicleFromSensor','bias','qualityScore'};
            for k=1:numel(names), if isfield(result,names{k}), c.(names{k})=result.(names{k}); end, end
            if isfield(result,'verification') && isstruct(result.verification)
                c.verificationPassed=logical(obj.value(result.verification,'success',false));
                c.verificationScore=obj.value(result.verification,'score',obj.value(result,'verificationScore',NaN));
            elseif isfield(result,'verificationScore'), c.verificationScore=result.verificationScore; end
            if isfield(result,'qualityScore'), c.qualityScore=result.qualityScore; end
            if isfield(result,'calibration') && isstruct(result.calibration)
                if isfield(result.calibration,'rotationVehicleFromSensor'), c.rotationVehicleFromSensor=result.calibration.rotationVehicleFromSensor; end
                if isfield(result.calibration,'bias'), c.bias=result.calibration.bias; end
                if isfield(result.calibration,'quality') && isstruct(result.calibration.quality)
                    c.qualityScore=obj.value(result.calibration.quality,'score',c.qualityScore);
                end
            end
            c.errors=string(obj.value(result,'errors',strings(0,1))); c.warnings=string(obj.value(result,'warnings',strings(0,1)));
            obj.Snapshot.calibration=c;
        end
        function ingestAcceptanceResult(obj,result)
            if ~isstruct(result), result=struct(); end
            fields={'success','failurePhase','infrastructureFailure','matlabRestartRequired', ...
                'commitMatch','uidMatch','busIdMatch','sensorFusionModeMatch','calibrationVerified', ...
                'runtimeTailComplete','runtimeBufferEmpty','runtimeSuccess','realtimeSuccess', ...
                'matFile','jsonFile','errors','warnings','observerWarnings'};
            acceptance=struct();
            for k=1:numel(fields), acceptance.(fields{k})=obj.value(result,fields{k},[]); end
            obj.Snapshot.acceptance=acceptance;
        end
        function updateMetadata(obj,metadata)
            if ~isstruct(metadata), return; end
            names=fieldnames(metadata); for k=1:numel(names), obj.Snapshot.(names{k})=metadata.(names{k}); end
        end
        function ingestMonitorStatus(obj,status)
            if ~isstruct(status), return; end
            obj.Snapshot.realtime=status;
            if isfield(status,'lifecycleState'), obj.Snapshot.lifecycleState=string(status.lifecycleState); end
            if isfield(status,'callbackStats'), obj.Snapshot.callback=obj.callbackModel(status.callbackStats,status); end
            if isfield(status,'recording'), obj.Snapshot.recording=obj.mergeStruct(obj.Snapshot.recording,status.recording); end
            if isfield(status,'dataQuality'), obj.Snapshot.dataQuality=status.dataQuality; end
            if isfield(status,'activeEvents'), obj.Snapshot.activeEvents=status.activeEvents; end
            if isfield(status,'latestSensorSample'), obj.Snapshot.latestSensorSample=status.latestSensorSample; end
            if isfield(status,'latestVehicleSample'), obj.Snapshot.latestVehicleSample=status.latestVehicleSample; end
            if isfield(status,'latestProcessedSample'), obj.Snapshot.latestProcessedSample=status.latestProcessedSample; end
        end
        function ingestSample(obj,sample)
            if ~isstruct(sample) || ~isscalar(sample), return; end
            obj.Samples=obj.put(obj.Samples,sample,'SampleIndex','SampleCount');
            obj.SamplesIngested=obj.SamplesIngested+1;
            obj.Snapshot.latestProcessedSample=sample;
        end
        function ingestEventStarted(obj,event)
            obj.Snapshot.activeEvents=obj.addActive(obj.Snapshot.activeEvents,event);
            obj.appendLog("info","realtime","Realtime","event_started",obj.eventName(event),event);
        end
        function ingestEventCompleted(obj,event)
            if ~isstruct(event), return; end
            obj.Events=obj.put(obj.Events,event,'EventIndex','EventCount');
            obj.EventsIngested=obj.EventsIngested+1;
            obj.Snapshot.recentEvents=obj.getEvents();
            obj.Snapshot.activeEvents=obj.removeActive(obj.Snapshot.activeEvents,event);
            obj.appendLog("info","realtime","Realtime","event_completed",obj.eventName(event),event);
        end
        function ingestWarning(obj,warningInfo)
            obj.Snapshot.severity="warning";
            entry=obj.makeLog("warning","system",obj.Snapshot.currentStage,"warning",obj.messageOf(warningInfo),warningInfo);
            obj.Snapshot.warnings=obj.appendNormalized(obj.Snapshot.warnings,entry,100);
            obj.appendLogEntry(entry);
        end
        function ingestError(obj,errorInfo)
            obj.Snapshot.severity="error";
            entry=obj.makeLog("error","system",obj.Snapshot.currentStage,"error",obj.messageOf(errorInfo),errorInfo);
            obj.Snapshot.errors=obj.appendNormalized(obj.Snapshot.errors,entry,100);
            obj.appendLogEntry(entry);
        end
        function value=getSnapshot(obj)
            value=obj.Snapshot; value.generatedAt=datetime('now','TimeZone','UTC');
            value.recentEvents=obj.getEvents(); value.stageHistory=obj.getStages();
            value.log=obj.getLog(); value.signalHistory=obj.getSignalHistory();
        end
        function value=getSignalHistory(obj), value=obj.ordered(obj.Samples,obj.SampleCount,obj.SampleIndex); end
        function value=getEvents(obj), value=obj.ordered(obj.Events,obj.EventCount,obj.EventIndex); end
        function value=getLog(obj), value=obj.ordered(obj.Logs,obj.LogCount,obj.LogIndex); end
        function value=getStages(obj), value=obj.ordered(obj.Stages,obj.StageCount,obj.StageIndex); end
        function value=getCounters(obj)
            value=struct('samplesIngested',obj.SamplesIngested,'eventsIngested',obj.EventsIngested, ...
                'logsIngested',obj.LogsIngested,'sampleCount',obj.SampleCount,'eventCount',obj.EventCount, ...
                'logCount',obj.LogCount,'stageCount',obj.StageCount);
        end
    end
    methods(Access=private)
        function s=emptySnapshot(~)
            callback=struct('sessionId',0,'received',0,'buffered',0,'bufferCapacity',0, ...
                'bufferUtilization',0,'averageFrequencyHz',0,'currentCallbackAgeMs',0, ...
                'maximumCallbackAgeMs',0,'missingSamples',0,'duplicateSamples',0, ...
                'invalidSamples',0,'lateSamples',0,'overflowDropped',0,'coalesced',0, ...
                'staleSessionDropped',0,'lastSequence',0);
            recording=struct('enabled',false,'status',"disabled",'sessionId',"", ...
                'directory',"",'samplesWritten',0,'bytesWritten',0, ...
                'estimatedBufferedBytes',0,'maximumSessionBytes',0,'freeDiskBytes',NaN, ...
                'minimumFreeDiskBytes',0,'durationSeconds',0,'maximumDurationSeconds',0,'stopReason',"");
            calibration=struct('required',false,'state',"IDLE",'phase',"idle",'progress',0, ...
                'samplesRequired',0,'samplesCollected',0,'samplesRemaining',0, ...
                'qualityScore',NaN,'verificationPerformed',false,'verificationPassed',false, ...
                'verificationScore',NaN,'activationAttempted',false,'activationVerified',false, ...
                'rollbackAttempted',false,'rollbackSucceeded',false,'finalFile',"", ...
                'workingFile',"",'backupFile',"");
            s=struct('generatedAt',NaT,'mode',"operation",'lifecycleState',"IDLE", ...
                'currentStage',"",'stageProgress',0,'message',"",'severity',"info", ...
                'checkoutCommit',"",'busId',"",'imuUid',"",'firmwareVersion',[], ...
                'sensorFusionMode',[],'connection',struct(),'preflight',struct(), ...
                'calibration',calibration,'verification',struct(),'realtime',struct(), ...
                'callback',callback,'recording',recording,'dataQuality',struct(), ...
                'latestSensorSample',[],'latestVehicleSample',[], ...
                'latestProcessedSample',[],'activeEvents',struct.empty(0,1), ...
                'recentEvents',struct.empty(0,1),'warnings',struct.empty(0,1), ...
                'errors',struct.empty(0,1),'acceptance',struct());
        end
        function copyField(obj,status,name)
            if isfield(status,name), obj.Snapshot.(name)=status.(name); end
        end
        function buffer=put(obj,buffer,value,indexName,countName)
            index=mod(obj.(indexName),numel(buffer))+1; buffer{index}=value;
            obj.(indexName)=index; obj.(countName)=min(numel(buffer),obj.(countName)+1);
        end
        function values=ordered(~,buffer,count,last)
            if count==0, values=struct.empty(0,1); return; end
            first=mod(last-count,numel(buffer))+1; indices=mod((first-1)+(0:count-1),numel(buffer))+1;
            cells=buffer(indices); values=vertcat(cells{:});
        end
        function appendLog(obj,severity,source,stage,type,message,payload)
            if nargin<7, payload=struct(); end
            entry=obj.makeLog(severity,source,stage,type,message,payload);
            obj.appendLogEntry(entry);
        end
        function appendLogEntry(obj,entry)
            obj.Logs=obj.put(obj.Logs,entry,'LogIndex','LogCount'); obj.LogsIngested=obj.LogsIngested+1;
        end
        function model=callbackModel(obj,stats,status)
            model=obj.Snapshot.callback;
            if ~isstruct(stats), stats=struct(); end
            pairs={'sessionId','sessionId';'received','received';'buffered','buffered'; ...
                'capacity','bufferCapacity';'overflowDropped','overflowDropped'; ...
                'coalesced','coalesced';'staleSessionDropped','staleSessionDropped';'lastSequence','lastSequence'};
            for k=1:size(pairs,1), if isfield(stats,pairs{k,1}), model.(pairs{k,2})=stats.(pairs{k,1}); end, end
            if model.bufferCapacity>0, model.bufferUtilization=double(model.buffered)/double(model.bufferCapacity); end
            if isfield(status,'acquisitionDurationSeconds') && status.acquisitionDurationSeconds>0
                model.averageFrequencyHz=double(status.samplesProcessed)/double(status.acquisitionDurationSeconds);
            end
            if isfield(status,'dataQuality')
                names=fieldnames(status.dataQuality);
                for k=1:numel(names), if isfield(model,names{k}), model.(names{k})=status.dataQuality.(names{k}); end, end
            end
            if isfield(status,'currentCallbackAgeMs'), model.currentCallbackAgeMs=status.currentCallbackAgeMs; end
            if isfield(status,'maximumCallbackAgeMs'), model.maximumCallbackAgeMs=status.maximumCallbackAgeMs; end
        end
        function out=mergeStruct(~,out,in)
            if ~isstruct(in), return; end
            names=fieldnames(in); for k=1:numel(names), out.(names{k})=in.(names{k}); end
        end
        function out=appendNormalized(~,out,value,limit)
            if isempty(out), out=value; else, out(end+1,1)=value; end
            if numel(out)>limit, out=out(end-limit+1:end); end
        end
        function active=addActive(~,active,event)
            if isempty(active), active=event; return; end
            if isfield(event,'type')
                for k=1:numel(active)
                    if isfield(active(k),'type') && string(active(k).type)==string(event.type), active(k)=event; return; end
                end
            end
            active(end+1,1)=event;
        end
        function active=removeActive(~,active,event)
            if isempty(active) || ~isfield(event,'type'), return; end
            keep=true(numel(active),1);
            for k=1:numel(active), if isfield(active(k),'type'), keep(k)=string(active(k).type)~=string(event.type); end, end
            active=active(keep);
        end
        function name=eventName(~,event)
            name="event"; if isstruct(event) && isfield(event,'type'), name=string(event.type); end
        end
        function message=messageOf(~,value)
            if isa(value,'MException'), message=string(value.identifier)+": "+string(value.message);
            elseif isstruct(value) && isfield(value,'message'), message=string(value.message);
            elseif isstruct(value) && isfield(value,'type'), message=string(value.type);
            else, message=string(value); end
        end
        function entry=makeLog(~,severity,source,stage,type,message,payload)
            if isa(payload,'MException'), payload=struct('identifier',payload.identifier,'message',payload.message); end
            entry=struct('timestamp',datetime('now','TimeZone','UTC'),'severity',string(severity), ...
                'source',string(source),'stage',string(stage),'type',string(type), ...
                'message',string(message),'payload',payload);
        end
        function value=value(~,s,name,default)
            value=default; if isstruct(s) && isfield(s,name), value=s.(name); end
        end
    end
end
