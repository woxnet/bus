classdef BusDrivingSystemDashboard < handle
%BUSDRIVINGSYSTEMDASHBOARD Unified bounded operator visualization.
% The dashboard renders controller telemetry only. It never reads the IMU FIFO.
    properties(SetAccess=private)
        Controller
        Config
        Figure=[]
        RenderCount=0
        LastRenderMilliseconds=0
        LastSnapshot=[]
    end
    properties(Access=private)
        RenderTimer=[]
        StageLabels
        StageLamps
        StatusLabel
        OverviewTable
        SignalAxes
        EventTable
        DetectorTable
        QualityTable
        CalibrationTable
        CalibrationAxes
        RecordingTable
        RecordingGauges
        AcceptanceTable
        LogTable
        Controls
        Closing=false
        ThresholdConfig
    end
    methods
        function obj=BusDrivingSystemDashboard(controller,config)
            if nargin<1 || isempty(controller), error('IMU:InvalidDashboardController','Controller is required.'); end
            if nargin<2 || isempty(config), config=getBusDrivingSystemDashboardConfig(); end
            obj.Controller=controller; obj.Config=validateBusDrivingSystemDashboardConfig(config);
            obj.ThresholdConfig=getRealtimeDrivingConfig();
        end
        function open(obj)
            if ~isempty(obj.Figure) && isvalid(obj.Figure), return; end
            obj.buildUi();
            obj.RenderTimer=timer('ExecutionMode','fixedSpacing','BusyMode','drop', ...
                'Period',1/obj.Config.refreshHz,'TimerFcn',@(~,~)obj.renderSafely());
            obj.render(); start(obj.RenderTimer);
        end
        function render(obj)
            if isempty(obj.Figure) || ~isvalid(obj.Figure), return; end
            started=tic; snapshot=obj.Controller.getTelemetrySnapshot(); obj.LastSnapshot=snapshot;
            obj.renderPipeline(snapshot); obj.renderOverview(snapshot); obj.renderSignals(snapshot);
            obj.renderEvents(snapshot); obj.renderQuality(snapshot); obj.renderCalibration(snapshot);
            obj.renderRecording(snapshot); obj.renderAcceptance(snapshot); obj.renderLog(snapshot);
            obj.updateControls(snapshot.lifecycleState);
            obj.RenderCount=obj.RenderCount+1; obj.LastRenderMilliseconds=1000*toc(started);
            drawnow limitrate;
        end
        function result=saveSnapshot(obj,directory)
            if nargin<2 || isempty(directory), directory=resolveProjectPath('artifacts'); end
            if ~isfolder(directory), mkdir(directory); end
            snapshot=obj.Controller.getTelemetrySnapshot(); config=obj.Config;
            stamp=char(datetime('now','Format','yyyyMMdd_HHmmss_SSS'));
            stem=fullfile(char(directory),['system_snapshot_' stamp]);
            matFile=[stem '.mat']; jsonFile=[stem '.json'];
            save(matFile,'snapshot','config','-v7');
            fileId=fopen(jsonFile,'w');
            if fileId<0, error('IMU:SystemSnapshotSaveFailed','Cannot write snapshot JSON.'); end
            cleanup=onCleanup(@()fclose(fileId)); fprintf(fileId,'%s',jsonencode(snapshot,'PrettyPrint',true)); clear cleanup;
            pngFile=fullfile(char(directory),['system_dashboard_' stamp '.png']);
            if ~isempty(obj.Figure) && isvalid(obj.Figure)
                resumeRender=false;
                if ~isempty(obj.RenderTimer) && isvalid(obj.RenderTimer) && strcmp(obj.RenderTimer.Running,'on')
                    stop(obj.RenderTimer); resumeRender=true;
                end
                renderCleanup=onCleanup(@()obj.resumeRenderTimer(resumeRender));
                if exist('exportapp','file')~=0
                    exportapp(obj.Figure,pngFile);
                else
                    exportgraphics(obj.Figure,pngFile);
                end
                clear renderCleanup;
            else, pngFile=""; end
            result=struct('matFile',string(matFile),'jsonFile',string(jsonFile),'pngFile',string(pngFile));
        end
        function names=getTabNames(~)
            names=["Overview","Signals","Events","Data quality","Calibration","Recording","Hardware acceptance","Log"];
        end
        function close(obj)
            if obj.Closing, return; end
            obj.Closing=true; cleanup=onCleanup(@()obj.resetClosing());
            obj.stopTimer();
            if obj.Config.closeStopsSystem
                status=obj.Controller.getStatus();
                if status.isRealtimeRunning, obj.Controller.stopRealtime(); end
            end
            if ~isempty(obj.Figure) && isvalid(obj.Figure)
                obj.Figure.CloseRequestFcn=[]; delete(obj.Figure);
            end
            obj.Figure=[]; clear cleanup; obj.Closing=false;
        end
        function delete(obj), obj.close(); end
    end
    methods(Access=private)
        function buildUi(obj)
            obj.Figure=uifigure('Name','Bus driving system','Position',[50 50 1500 900], ...
                'CloseRequestFcn',@(~,~)obj.handleCloseRequest());
            root=uigridlayout(obj.Figure,[3 1]); root.RowHeight={95,'1x',80}; root.Padding=[8 8 8 8];
            pipeline=uigridlayout(root,[3 10]); pipeline.RowHeight={22,18,'1x'}; pipeline.ColumnWidth=repmat({'1x'},1,10);
            stages=["Bootstrap","Class API","IMU","Preflight","Calibration","Verification","Realtime","Recording","Stopping","Result"];
            obj.StageLabels=gobjects(10,1);
            obj.StageLamps=gobjects(10,1);
            for k=1:10
                nameLabel=uilabel(pipeline,'Text',char(stages(k)),'HorizontalAlignment','center','FontWeight','bold');
                nameLabel.Layout.Row=1; nameLabel.Layout.Column=k;
                lampGrid=uigridlayout(pipeline,[1 3]); lampGrid.ColumnWidth={'1x',20,'1x'}; lampGrid.Padding=[0 0 0 0];
                lampGrid.Layout.Row=2; lampGrid.Layout.Column=k;
                obj.StageLamps(k)=uilamp(lampGrid,'Color',[.7 .7 .7]); obj.StageLamps(k).Layout.Column=2;
                obj.StageLabels(k)=uilabel(pipeline,'Text','— NOT_STARTED 0%','HorizontalAlignment','center', ...
                    'BackgroundColor',[.94 .94 .94]);
                obj.StageLabels(k).Layout.Row=3; obj.StageLabels(k).Layout.Column=k;
            end
            tabs=uitabgroup(root); overview=uitab(tabs,'Title','Overview'); signals=uitab(tabs,'Title','Signals');
            events=uitab(tabs,'Title','Events'); quality=uitab(tabs,'Title','Data quality');
            calibration=uitab(tabs,'Title','Calibration'); recording=uitab(tabs,'Title','Recording');
            acceptance=uitab(tabs,'Title','Hardware acceptance'); logTab=uitab(tabs,'Title','Log');
            og=uigridlayout(overview,[2 1]); og.RowHeight={55,'1x'};
            obj.StatusLabel=uilabel(og,'Text','SYSTEM IDLE','FontSize',24,'FontWeight','bold','HorizontalAlignment','center');
            obj.OverviewTable=uitable(og,'ColumnName',{'Field','Value'},'ColumnEditable',[false false]);
            sg=uigridlayout(signals,[3 3]); obj.SignalAxes=gobjects(9,1);
            titles=["Longitudinal acceleration","Lateral acceleration","Vertical acceleration", ...
                "Yaw rate","Longitudinal jerk","Lateral jerk","Vertical jerk","Data quality","Callback age"];
            for k=1:9, obj.SignalAxes(k)=uiaxes(sg); title(obj.SignalAxes(k),titles(k)); grid(obj.SignalAxes(k),'on'); end
            eg=uigridlayout(events,[2 1]); eg.RowHeight={100,'1x'};
            obj.DetectorTable=uitable(eg,'ColumnName',{'Detector','State'});
            obj.EventTable=uitable(eg,'ColumnName',{'ID','Type','Start','Duration','Peak acceleration','Peak jerk','Peak yaw','Samples','Quality','Reason'});
            qg=uigridlayout(quality,[2 1]); obj.QualityTable=uitable(qg,'ColumnName',{'Metric','Value'});
            qaxes=uiaxes(qg); title(qaxes,'Callback age / buffer utilization / data quality'); grid(qaxes,'on');
            cg=uigridlayout(calibration,[1 2]); obj.CalibrationTable=uitable(cg,'ColumnName',{'Field','Value'});
            obj.CalibrationAxes=uiaxes(cg); title(obj.CalibrationAxes,'Sensor and vehicle coordinates'); view(obj.CalibrationAxes,3); grid(obj.CalibrationAxes,'on');
            rg=uigridlayout(recording,[2 1]); rg.RowHeight={'1x',130};
            obj.RecordingTable=uitable(rg,'ColumnName',{'Field','Value'});
            gaugeGrid=uigridlayout(rg,[1 3]); obj.RecordingGauges=gobjects(3,1);
            gaugeTitles={'Session size %','Duration %','Free disk reserve %'};
            for k=1:3, obj.RecordingGauges(k)=uigauge(gaugeGrid,'Limits',[0 100]); obj.RecordingGauges(k).Tooltip=gaugeTitles{k}; end
            obj.AcceptanceTable=uitable(acceptance,'ColumnName',{'Stage','State','Progress','Message'});
            obj.LogTable=uitable(logTab,'ColumnName',{'Timestamp','Severity','Source','Stage','Type','Message'});
            controls=uigridlayout(root,[2 5]); controls.RowHeight={'1x','1x'}; controls.ColumnWidth=repmat({'1x'},1,5);
            labels={"Start system","Preflight","Start calibration","Confirm","Reject", ...
                "Start real-time","Stop","Full acceptance","Save snapshot","Close"};
            callbacks={@(~,~)obj.Controller.startSystem(),@(~,~)obj.Controller.runPreflight(), ...
                @(~,~)obj.Controller.startCalibration(),@(~,~)obj.Controller.confirmCurrentStep(), ...
                @(~,~)obj.Controller.rejectCurrentStep(),@(~,~)obj.Controller.startRealtime(), ...
                @(~,~)obj.Controller.stopRealtime(),@(~,~)obj.Controller.runFullAcceptance(), ...
                @(~,~)obj.saveSnapshot(),@(~,~)obj.close()};
            obj.Controls=gobjects(10,1);
            for k=1:10, obj.Controls(k)=uibutton(controls,'Text',labels{k},'ButtonPushedFcn',callbacks{k}); end
        end
        function renderPipeline(obj,s)
            names=["Bootstrap","Class API","IMU","Preflight","Calibration","Verification","Realtime","Recording","Stopping","Result"];
            completed=obj.completedStages(s); current=string(s.currentStage);
            for k=1:numel(names)
                state="NOT_STARTED"; symbol="—"; color=[.94 .94 .94]; progress=0;
                if any(completed==names(k)), state="PASSED"; symbol="✓"; color=[.82 .94 .82]; progress=100; end
                if current==names(k)
                    state="RUNNING"; symbol="…"; color=[.78 .88 1]; progress=round(100*s.stageProgress);
                    if string(s.lifecycleState)=="CALIBRATION_REQUIRED", state="WAITING_OPERATOR"; symbol="!"; color=[1 .93 .72]; end
                    if string(s.lifecycleState)=="FAILED", state="FAILED"; symbol="✕"; color=[1 .78 .78]; end
                end
                obj.StageLabels(k).Text=sprintf('%s %s %d%%',char(symbol),char(state),progress);
                obj.StageLabels(k).BackgroundColor=color;
                obj.StageLamps(k).Color=color;
            end
        end
        function renderOverview(obj,s)
            indicator=obj.indicator(s); obj.StatusLabel.Text=char(indicator);
            obj.OverviewTable.Data={'Lifecycle',obj.displayValue(s.lifecycleState);'Current stage',obj.displayValue(s.currentStage); ...
                'Mode',obj.displayValue(s.mode);'Bus ID',obj.displayValue(s.busId);'IMU UID',obj.displayValue(s.imuUid); ...
                'Firmware',mat2str(s.firmwareVersion);'Sensor fusion',mat2str(s.sensorFusionMode); ...
                'Commit',obj.displayValue(s.checkoutCommit);'Stream owner',obj.displayValue(obj.field(s.realtime,'streamOwner',"none")); ...
                'Recorder',obj.displayValue(obj.field(s.recording,'status',"disabled"));'Last error',obj.displayValue(obj.lastError(s))};
        end
        function renderSignals(obj,s)
            history=s.signalHistory; if isempty(history), return; end
            x=obj.vector(history,'elapsedSeconds'); fields={{'longitudinalRaw','longitudinalFiltered'}, ...
                {'lateralRaw','lateralFiltered'},{'verticalRaw','verticalFiltered'}, ...
                {'yawRateRaw','yawRateFiltered'},{'longitudinalJerk'},{'lateralJerk'}, ...
                {'verticalJerk'},{'dataQuality'},{'callbackAgeMs'}};
            for k=1:9
                cla(obj.SignalAxes(k)); hold(obj.SignalAxes(k),'on');
                for n=1:numel(fields{k})
                    if n==1 && ~obj.Config.showRawSignals && numel(fields{k})>1, continue; end
                    if n==2 && ~obj.Config.showFilteredSignals, continue; end
                    plot(obj.SignalAxes(k),x,obj.vector(history,fields{k}{n}),'DisplayName',fields{k}{n});
                end
                obj.renderThresholds(k);
                if obj.Config.showEventMarkers, obj.renderEventMarkers(obj.SignalAxes(k),s,x,history,fields{k}{end}); end
                hold(obj.SignalAxes(k),'off');
            end
        end
        function renderEvents(obj,s)
            types=["BRAKING_CANDIDATE","ACCELERATION_CANDIDATE","TURN_LEFT_CANDIDATE","TURN_RIGHT_CANDIDATE","VERTICAL_SHOCK_CANDIDATE"];
            states=repmat("IDLE",5,1);
            for k=1:numel(s.activeEvents), if isfield(s.activeEvents(k),'type'), states(types==string(s.activeEvents(k).type))="ACTIVE"; end, end
            obj.DetectorTable.Data=[cellstr(types(:)),cellstr(states(:))];
            e=s.recentEvents; data=cell(numel(e),10);
            for k=1:numel(e), data(k,:)={obj.displayValue(obj.field(e(k),'eventId',"")),obj.displayValue(obj.field(e(k),'type',"")), ...
                    obj.displayValue(obj.field(e(k),'startTimestamp',"")),obj.field(e(k),'durationSeconds',NaN), ...
                    obj.field(e(k),'peakAcceleration',NaN),obj.field(e(k),'peakJerk',NaN), ...
                    obj.field(e(k),'peakYawRate',NaN),obj.field(e(k),'sampleCount',0), ...
                    obj.field(e(k),'dataQuality',NaN),obj.displayValue(obj.field(e(k),'terminationReason',""))}; end
            obj.EventTable.Data=data;
        end
        function renderQuality(obj,s)
            c=s.callback; fields={'averageFrequencyHz','currentCallbackAgeMs','maximumCallbackAgeMs','bufferUtilization', ...
                'received','buffered','missingSamples','duplicateSamples','invalidSamples','lateSamples', ...
                'overflowDropped','coalesced','staleSessionDropped'};
            data=cell(numel(fields)+1,2); data(1,:)={'status',obj.displayValue(obj.qualityStatus(c))};
            for k=1:numel(fields), data(k+1,:)={fields{k},obj.field(c,fields{k},0)}; end
            obj.QualityTable.Data=data;
        end
        function renderCalibration(obj,s)
            c=s.calibration; names=fieldnames(c); data=cell(numel(names),2);
            for k=1:numel(names), data(k,:)={names{k},obj.displayValue(c.(names{k}))}; end
            obj.CalibrationTable.Data=data;
            cla(obj.CalibrationAxes); hold(obj.CalibrationAxes,'on');
            quiver3(obj.CalibrationAxes,0,0,0,1,0,0,'r'); quiver3(obj.CalibrationAxes,0,0,0,0,1,0,'g'); quiver3(obj.CalibrationAxes,0,0,0,0,0,1,'b');
            hold(obj.CalibrationAxes,'off'); axis(obj.CalibrationAxes,'equal');
        end
        function renderRecording(obj,s)
            r=s.recording; names=fieldnames(r); data=cell(numel(names),2);
            for k=1:numel(names), data(k,:)={names{k},obj.displayValue(r.(names{k}))}; end
            obj.RecordingTable.Data=data;
            sizeRatio=obj.ratio(obj.field(r,'bytesWritten',0)+obj.field(r,'estimatedBufferedBytes',0),obj.field(r,'maximumSessionBytes',0));
            durationRatio=obj.ratio(obj.field(r,'durationSeconds',0),obj.field(r,'maximumDurationSeconds',0));
            freeRatio=obj.ratio(obj.field(r,'freeDiskBytes',0),obj.field(r,'minimumFreeDiskBytes',0));
            obj.RecordingGauges(1).Value=sizeRatio; obj.RecordingGauges(2).Value=durationRatio; obj.RecordingGauges(3).Value=freeRatio;
        end
        function renderAcceptance(obj,s)
            stages=s.stageHistory; data=cell(numel(stages),4);
            for k=1:numel(stages), data(k,:)={obj.displayValue(obj.field(stages(k),'stage',"")),obj.displayValue(obj.field(stages(k),'state',"")), ...
                    obj.field(stages(k),'progress',0),obj.displayValue(obj.field(stages(k),'message',""))}; end
            obj.AcceptanceTable.Data=data;
        end
        function renderLog(obj,s)
            log=s.log; data=cell(numel(log),6);
            for k=1:numel(log), data(k,:)={obj.displayValue(obj.field(log(k),'timestamp',"")),obj.displayValue(obj.field(log(k),'severity',"")), ...
                    obj.displayValue(obj.field(log(k),'source',"")),obj.displayValue(obj.field(log(k),'stage',"")), ...
                    obj.displayValue(obj.field(log(k),'type',"")),obj.displayValue(obj.field(log(k),'message',""))}; end
            obj.LogTable.Data=data;
        end
        function updateControls(obj,state)
            state=string(state); enabled=false(10,1);
            enabled(1)=any(state==["IDLE","STOPPED","COMPLETED"]); enabled(2)=state=="CONNECTING_IMU";
            enabled(3)=any(state==["CALIBRATION_REQUIRED","READY"]); enabled(4:5)=any(state==["CALIBRATING","CALIBRATION_VERIFYING"]);
            enabled(6)=any(state==["READY","STOPPED"]); enabled(7)=state=="STREAMING";
            enabled(8)=state~="STREAMING"; enabled(9)=true; enabled(10)=true;
            for k=1:10
                if enabled(k), obj.Controls(k).Enable='on'; else, obj.Controls(k).Enable='off'; end
            end
        end
        function renderSafely(obj)
            try, obj.render(); catch exception
                warning('IMU:SystemDashboardRenderFailed','Dashboard render failed: %s',exception.message);
            end
        end
        function stopTimer(obj)
            if isempty(obj.RenderTimer), return; end
            value=obj.RenderTimer; obj.RenderTimer=[];
            if isvalid(value), stop(value); delete(value); end
        end
        function resetClosing(obj), obj.Closing=false; end
        function handleCloseRequest(obj)
            status=obj.Controller.getStatus();
            if status.isRealtimeRunning
                choice=uiconfirm(obj.Figure,'Real-time monitoring is active.', ...
                    'Close dashboard','Options',{'Stop system and close','Leave system running','Cancel'}, ...
                    'DefaultOption',1,'CancelOption',3);
                if strcmp(choice,'Cancel'), return; end
                if strcmp(choice,'Leave system running')
                    previous=obj.Config.closeStopsSystem; obj.Config.closeStopsSystem=false;
                    cleanup=onCleanup(@()obj.restoreCloseOption(previous)); obj.close(); clear cleanup;
                    return;
                end
            end
            obj.close();
        end
        function restoreCloseOption(obj,value), obj.Config.closeStopsSystem=value; end
        function resumeRenderTimer(obj,shouldResume)
            if shouldResume && ~isempty(obj.RenderTimer) && isvalid(obj.RenderTimer)
                start(obj.RenderTimer);
            end
        end
        function value=field(~,s,name,default)
            value=default; if isstruct(s) && isfield(s,name), value=s.(name); end
        end
        function values=vector(obj,items,name)
            values=nan(numel(items),1); for k=1:numel(items), values(k)=double(obj.field(items(k),name,NaN)); end
        end
        function value=displayValue(~,value)
            if isstring(value) || ischar(value), value=char(string(value));
            elseif isdatetime(value), value=char(string(value));
            elseif isnumeric(value) || islogical(value), value=mat2str(value);
            else, value=class(value); end
        end
        function value=lastError(~,s)
            value=""; if ~isempty(s.errors), value="See error log"; end
        end
        function result=qualityStatus(~,c)
            if c.overflowDropped>0, result="FAILED";
            elseif c.invalidSamples>0 || c.missingSamples>0, result="UNRELIABLE";
            elseif c.lateSamples>0 || c.bufferUtilization>.75, result="DEGRADED";
            else, result="GOOD"; end
        end
        function renderThresholds(obj,index)
            if ~obj.Config.showThresholds, return; end
            t=obj.ThresholdConfig; ax=obj.SignalAxes(index);
            switch index
                case 1, values=[t.brakingStartThreshold,t.brakingStopThreshold,t.accelerationStartThreshold,t.accelerationStopThreshold];
                case 2, values=[-t.lateralStartThreshold,-t.lateralStopThreshold,t.lateralStopThreshold,t.lateralStartThreshold];
                case 3, values=[-t.verticalShockThreshold,t.verticalShockThreshold];
                case 4, values=[-t.yawRateStartThresholdDegPerSecond,-t.yawRateStopThresholdDegPerSecond,t.yawRateStopThresholdDegPerSecond,t.yawRateStartThresholdDegPerSecond];
                case {5,6,7}, values=[-t.jerkCandidateThreshold,t.jerkCandidateThreshold];
                otherwise, values=[];
            end
            for value=values, yline(ax,value,':','Color',[.45 .45 .45],'HandleVisibility','off'); end
        end
        function renderEventMarkers(obj,ax,s,x,history,fieldName)
            if isempty(x) || isempty(s.recentEvents), return; end
            markerX=[];
            for k=1:numel(s.recentEvents)
                value=obj.field(s.recentEvents(k),'startElapsedSeconds',NaN);
                if isfinite(value) && value>=x(1) && value<=x(end), markerX(end+1)=value; end %#ok<AGROW>
            end
            if isempty(markerX), return; end
            y=obj.vector(history,fieldName); markerY=interp1(x,y,markerX,'nearest','extrap');
            scatter(ax,markerX,markerY,28,'filled','MarkerFaceColor',[.85 .2 .2],'HandleVisibility','off');
        end
        function value=ratio(~,numerator,denominator)
            if isempty(denominator) || ~isfinite(double(denominator)) || denominator<=0, value=0;
            else, value=max(0,min(100,100*double(numerator)/double(denominator))); end
        end
        function value=indicator(obj,s)
            state=string(s.lifecycleState);
            if state=="FAILED", value="FAILED"; elseif state=="CALIBRATION_REQUIRED", value="CALIBRATION REQUIRED";
            elseif any(state==["STOP_REQUESTED","QUIESCING","DRAINING_TAIL","FINALIZING_RECORDING","RELEASING_STREAM"]), value="STOPPING";
            elseif state=="STREAMING" && obj.qualityStatus(s.callback)~="GOOD", value="DEGRADED DATA";
            elseif state=="STREAMING", value="STREAMING"; elseif state=="READY", value="SYSTEM READY"; else, value="SYSTEM "+state; end
        end
        function completed=completedStages(~,s)
            completed=strings(0,1); stages=s.stageHistory;
            for k=1:numel(stages), if isfield(stages(k),'state') && string(stages(k).state)=="PASSED", completed(end+1,1)=string(stages(k).stage); end, end
        end
    end
end
