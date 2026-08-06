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
    end
    methods
        function obj=BusDrivingSystemTelemetryHub(config)
            if nargin<1 || isempty(config), config=getBusDrivingSystemDashboardConfig(); end
            obj.Config=validateBusDrivingSystemDashboardConfig(config);
            capacity=max(1,ceil(config.signalHistorySeconds*100));
            obj.Samples=cell(capacity,1); obj.Events=cell(config.maximumEventRows,1);
            obj.Logs=cell(config.maximumLogRows,1); obj.Stages=cell(config.maximumStageHistory,1);
            obj.Snapshot=obj.emptySnapshot();
        end
        function ingestState(obj,status)
            if ~isstruct(status), return; end
            obj.copyField(status,'lifecycleState'); obj.copyField(status,'currentStage');
            obj.copyField(status,'stageProgress'); obj.copyField(status,'message');
            obj.copyField(status,'mode');
            obj.appendLog("info","controller",obj.Snapshot.currentStage,"lifecycle", ...
                obj.Snapshot.lifecycleState+": "+obj.Snapshot.message);
        end
        function ingestStage(obj,event)
            if ~isstruct(event), return; end
            obj.Stages=obj.put(obj.Stages,event,'StageIndex','StageCount');
            if isfield(event,'stage'), obj.Snapshot.currentStage=string(event.stage); end
            if isfield(event,'progress'), obj.Snapshot.stageProgress=double(event.progress); end
            if isfield(event,'message'), obj.Snapshot.message=string(event.message); end
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
            if isfield(status,'message'), obj.Snapshot.message=string(status.message); end
        end
        function ingestMonitorStatus(obj,status)
            if ~isstruct(status), return; end
            obj.Snapshot.realtime=status;
            if isfield(status,'lifecycleState'), obj.Snapshot.lifecycleState=string(status.lifecycleState); end
            if isfield(status,'callbackStats'), obj.Snapshot.callback=obj.callbackModel(status.callbackStats,status); end
            if isfield(status,'recording'), obj.Snapshot.recording=obj.mergeStruct(obj.Snapshot.recording,status.recording); end
            if isfield(status,'dataQuality'), obj.Snapshot.dataQuality=status.dataQuality; end
            if isfield(status,'activeEvents'), obj.Snapshot.activeEvents=status.activeEvents; end
        end
        function ingestSample(obj,sample)
            if ~isstruct(sample) || ~isscalar(sample), return; end
            obj.Samples=obj.put(obj.Samples,sample,'SampleIndex','SampleCount');
            obj.SamplesIngested=obj.SamplesIngested+1;
            obj.Snapshot.latestProcessedSample=sample;
        end
        function ingestEventStarted(obj,event)
            obj.Snapshot.activeEvents=obj.addActive(obj.Snapshot.activeEvents,event);
            obj.appendLog("info","realtime","Realtime","event_started",obj.eventName(event));
        end
        function ingestEventCompleted(obj,event)
            if ~isstruct(event), return; end
            obj.Events=obj.put(obj.Events,event,'EventIndex','EventCount');
            obj.EventsIngested=obj.EventsIngested+1;
            obj.Snapshot.recentEvents=obj.getEvents();
            obj.Snapshot.activeEvents=obj.removeActive(obj.Snapshot.activeEvents,event);
            obj.appendLog("info","realtime","Realtime","event_completed",obj.eventName(event));
        end
        function ingestWarning(obj,warningInfo)
            obj.Snapshot.severity="warning";
            obj.Snapshot.warnings=obj.appendBoundedStruct(obj.Snapshot.warnings,warningInfo,100);
            obj.appendLog("warning","system",obj.Snapshot.currentStage,"warning",obj.messageOf(warningInfo));
        end
        function ingestError(obj,errorInfo)
            obj.Snapshot.severity="error";
            obj.Snapshot.errors=obj.appendBoundedStruct(obj.Snapshot.errors,errorInfo,100);
            obj.appendLog("error","system",obj.Snapshot.currentStage,"error",obj.messageOf(errorInfo));
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
                'errors',struct.empty(0,1));
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
        function appendLog(obj,severity,source,stage,type,message)
            entry=struct('timestamp',datetime('now','TimeZone','UTC'),'severity',string(severity), ...
                'source',string(source),'stage',string(stage),'type',string(type),'message',string(message));
            obj.Logs=obj.put(obj.Logs,entry,'LogIndex','LogCount'); obj.LogsIngested=obj.LogsIngested+1;
        end
        function model=callbackModel(obj,stats,status)
            model=obj.Snapshot.callback;
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
        end
        function out=mergeStruct(~,out,in)
            if ~isstruct(in), return; end
            names=fieldnames(in); for k=1:numel(names), out.(names{k})=in.(names{k}); end
        end
        function out=appendBoundedStruct(~,out,value,limit)
            if isa(value,'MException'), value=struct('identifier',value.identifier,'message',value.message); end
            if isempty(out), out=value; else, out(end+1,1)=value; end
            if numel(out)>limit, out=out(end-limit+1:end); end
        end
        function active=addActive(~,active,event)
            if isempty(active), active=event; else, active(end+1,1)=event; end
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
    end
end
