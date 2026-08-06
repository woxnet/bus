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
        MaximumObservedRenderMilliseconds=0
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
        QualityAxes
        CalibrationTable
        CalibrationAxes
        RecordingTable
        RecordingGauges
        AcceptanceTable
        LogTable
        LogFilter
        Controls
        Closing=false
        ThresholdConfig
        Dependencies
        RawLines
        FilteredLines
        MarkerScatters
        ThresholdLines
        QualityLines
        CalibrationQuivers
        LastRenderWarningAt=NaT
    end
    methods
        function obj=BusDrivingSystemDashboard(controller,config,dependencies)
            if nargin<1 || isempty(controller), error('IMU:InvalidDashboardController','Controller is required.'); end
            if nargin<2 || isempty(config), config=getBusDrivingSystemDashboardConfig(); end
            if nargin<3, dependencies=struct(); end
            obj.Controller=controller; obj.Config=validateBusDrivingSystemDashboardConfig(config);
            obj.ThresholdConfig=getRealtimeDrivingConfig();
            obj.Dependencies=obj.mergeDependencies(dependencies);
        end
        function open(obj)
            if ~isempty(obj.Figure) && isvalid(obj.Figure), return; end
            obj.buildUi();
            obj.RenderTimer=obj.Dependencies.createTimer('ExecutionMode','fixedSpacing','BusyMode','drop', ...
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
            obj.MaximumObservedRenderMilliseconds=max(obj.MaximumObservedRenderMilliseconds,obj.LastRenderMilliseconds);
            obj.checkRenderDuration();
            drawnow limitrate;
        end
        function result=saveSnapshot(obj,directory)
            if nargin<2 || isempty(directory), directory=resolveProjectPath('artifacts'); end
            if ~isfolder(directory), mkdir(directory); end
            snapshot=obj.Controller.getTelemetrySnapshot(); config=obj.Config;
            stamp=char(datetime('now','Format','yyyyMMdd_HHmmss_SSS'));
            stem=fullfile(char(directory),['system_snapshot_' stamp]);
            matFile=[stem '.mat']; jsonFile=[stem '.json'];
            obj.Dependencies.saveMat(matFile,snapshot,config);
            obj.Dependencies.writeJson(jsonFile,snapshot);
            pngFile=fullfile(char(directory),['system_dashboard_' stamp '.png']);
            if ~isempty(obj.Figure) && isvalid(obj.Figure)
                resumeRender=false;
                if ~isempty(obj.RenderTimer) && isvalid(obj.RenderTimer) && strcmp(obj.RenderTimer.Running,'on')
                    stop(obj.RenderTimer); resumeRender=true;
                end
                renderCleanup=onCleanup(@()obj.resumeRenderTimer(resumeRender));
                obj.Dependencies.exportPng(obj.Figure,pngFile);
                clear renderCleanup;
            else, pngFile=""; end
            result=struct('matFile',string(matFile),'jsonFile',string(jsonFile),'pngFile',string(pngFile));
        end
        function names=getTabNames(obj)
            names=["Overview","Signals","Events","Data quality","Log"];
            if obj.Config.enableCalibrationTab, names=[names(1:4),"Calibration",names(5)]; end
            insertion=numel(names);
            if obj.Config.enableRecordingTab, names=[names(1:insertion-1),"Recording",names(insertion)]; end
            insertion=numel(names);
            if obj.Config.enableAcceptanceTab, names=[names(1:insertion-1),"Hardware acceptance",names(insertion)]; end
        end
        function value=getGraphicsDiagnostics(obj)
            value=struct('rawLines',obj.RawLines,'filteredLines',obj.FilteredLines, ...
                'markerScatters',obj.MarkerScatters,'thresholdLines',obj.ThresholdLines, ...
                'qualityLines',obj.QualityLines,'maximumRenderedPointsPerSeries',obj.Config.maximumRenderedPointsPerSeries);
        end
        function close(obj)
            if obj.Closing, return; end
            obj.Closing=true; cleanup=onCleanup(@()obj.resetClosing());
            obj.stopTimer();
            if obj.Config.closeStopsSystem
                obj.Controller.close();
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
            if obj.Config.enableCalibrationTab, calibration=uitab(tabs,'Title','Calibration'); else, calibration=[]; end
            if obj.Config.enableRecordingTab, recording=uitab(tabs,'Title','Recording'); else, recording=[]; end
            if obj.Config.enableAcceptanceTab, acceptance=uitab(tabs,'Title','Hardware acceptance'); else, acceptance=[]; end
            logTab=uitab(tabs,'Title','Log');
            og=uigridlayout(overview,[2 1]); og.RowHeight={55,'1x'};
            obj.StatusLabel=uilabel(og,'Text','SYSTEM IDLE','FontSize',24,'FontWeight','bold','HorizontalAlignment','center');
            obj.OverviewTable=uitable(og,'ColumnName',{'Field','Value'},'ColumnEditable',[false false]);
            signalRoot=uigridlayout(signals,[2 1]); signalRoot.RowHeight={30,'1x'};
            toggles=uigridlayout(signalRoot,[1 4]); toggles.ColumnWidth={'1x','1x','1x','1x'};
            uicheckbox(toggles,'Text','Raw','Value',obj.Config.showRawSignals, ...
                'ValueChangedFcn',@(source,~)obj.setDisplayOption('showRawSignals',source.Value));
            uicheckbox(toggles,'Text','Filtered','Value',obj.Config.showFilteredSignals, ...
                'ValueChangedFcn',@(source,~)obj.setDisplayOption('showFilteredSignals',source.Value));
            uicheckbox(toggles,'Text','Thresholds','Value',obj.Config.showThresholds, ...
                'ValueChangedFcn',@(source,~)obj.setDisplayOption('showThresholds',source.Value));
            uicheckbox(toggles,'Text','Event markers','Value',obj.Config.showEventMarkers, ...
                'ValueChangedFcn',@(source,~)obj.setDisplayOption('showEventMarkers',source.Value));
            sg=uigridlayout(signalRoot,[3 3]); obj.SignalAxes=gobjects(9,1);
            titles=["Longitudinal acceleration","Lateral acceleration","Vertical acceleration", ...
                "Yaw rate","Longitudinal jerk","Lateral jerk","Vertical jerk","Data quality","Callback age"];
            obj.RawLines=gobjects(9,1); obj.FilteredLines=gobjects(9,1); obj.MarkerScatters=gobjects(9,1);
            obj.ThresholdLines=gobjects(9,4);
            for k=1:9
                ax=uiaxes(sg); obj.SignalAxes(k)=ax; title(ax,titles(k)); grid(ax,'on'); hold(ax,'on');
                obj.RawLines(k)=plot(ax,nan,nan,'Color',[.65 .65 .65],'DisplayName','raw');
                obj.FilteredLines(k)=plot(ax,nan,nan,'Color',[0 .35 .75],'LineWidth',1.2,'DisplayName','filtered');
                obj.MarkerScatters(k)=scatter(ax,nan,nan,28,'filled','MarkerFaceColor',[.85 .2 .2],'HandleVisibility','off');
                values=obj.thresholdValues(k);
                for thresholdIndex=1:4
                    thresholdValue=NaN; if thresholdIndex<=numel(values), thresholdValue=values(thresholdIndex); end
                    obj.ThresholdLines(k,thresholdIndex)=yline(ax,thresholdValue,':','Color',[.45 .45 .45],'HandleVisibility','off');
                end
                hold(ax,'off');
            end
            eg=uigridlayout(events,[2 1]); eg.RowHeight={100,'1x'};
            obj.DetectorTable=uitable(eg,'ColumnName',{'Detector','State'});
            obj.EventTable=uitable(eg,'ColumnName',{'ID','Type','Start','Duration','Peak acceleration','Peak jerk','Peak yaw','Samples','Quality','Reason'}, ...
                'CellSelectionCallback',@(~,event)obj.focusEvent(event));
            qg=uigridlayout(quality,[2 1]); obj.QualityTable=uitable(qg,'ColumnName',{'Metric','Value'});
            obj.QualityAxes=uiaxes(qg); title(obj.QualityAxes,'Callback age / buffer utilization / data quality / effective frequency'); grid(obj.QualityAxes,'on');
            hold(obj.QualityAxes,'on'); obj.QualityLines=gobjects(4,1);
            qualityNames={'callback age ms','data quality %','buffer utilization %','effective frequency Hz'};
            for k=1:4, obj.QualityLines(k)=plot(obj.QualityAxes,nan,nan,'DisplayName',qualityNames{k}); end
            hold(obj.QualityAxes,'off'); legend(obj.QualityAxes,'show');
            if obj.Config.enableCalibrationTab
                cg=uigridlayout(calibration,[1 2]); obj.CalibrationTable=uitable(cg,'ColumnName',{'Field','Value'});
                obj.CalibrationAxes=uiaxes(cg); title(obj.CalibrationAxes,'Sensor and vehicle coordinates'); view(obj.CalibrationAxes,3); grid(obj.CalibrationAxes,'on');
                hold(obj.CalibrationAxes,'on'); obj.CalibrationQuivers=gobjects(6,1); colors={'r','g','b','m','c','k'};
                for k=1:6, obj.CalibrationQuivers(k)=quiver3(obj.CalibrationAxes,0,0,0,0,0,0,colors{k},'LineWidth',1.5); end
                hold(obj.CalibrationAxes,'off'); axis(obj.CalibrationAxes,'equal');
            end
            if obj.Config.enableRecordingTab
                rg=uigridlayout(recording,[2 1]); rg.RowHeight={'1x',130};
                obj.RecordingTable=uitable(rg,'ColumnName',{'Field','Value'});
                gaugeGrid=uigridlayout(rg,[1 3]); obj.RecordingGauges=gobjects(3,1);
                gaugeTitles={'Session size %','Duration %','Free disk reserve %'};
                for k=1:3, obj.RecordingGauges(k)=uigauge(gaugeGrid,'Limits',[0 100]); obj.RecordingGauges(k).Tooltip=gaugeTitles{k}; end
            end
            if obj.Config.enableAcceptanceTab
                obj.AcceptanceTable=uitable(acceptance,'ColumnName',{'Stage','State','Progress','Message'});
            end
            lg=uigridlayout(logTab,[2 1]); lg.RowHeight={30,'1x'};
            obj.LogFilter=uidropdown(lg,'Items',{'All','Lifecycle','Events','Warnings','Errors','Operator'}, ...
                'Value','All','ValueChangedFcn',@(~,~)obj.renderSafely());
            obj.LogTable=uitable(lg,'ColumnName',{'Timestamp','Severity','Source','Stage','Type','Message'});
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
            completed=obj.completedStages(s); rawCurrent=string(s.currentStage); current=obj.pipelineStageName(rawCurrent);
            for k=1:numel(names)
                state="NOT_STARTED"; symbol="—"; color=[.94 .94 .94]; progress=0;
                if any(completed==names(k)), state="PASSED"; symbol="✓"; color=[.82 .94 .82]; progress=100; end
                if current==names(k)
                    state="RUNNING"; symbol="…"; color=[.78 .88 1]; progress=round(100*s.stageProgress);
                    if string(s.lifecycleState)=="CALIBRATION_REQUIRED", state="WAITING_OPERATOR"; symbol="!"; color=[1 .93 .72]; end
                    if string(s.lifecycleState)=="FAILED", state="FAILED"; symbol="✕"; color=[1 .78 .78]; end
                end
                elapsed=obj.stageElapsed(s,names(k));
                if current==names(k), elapsed=obj.stageElapsed(s,rawCurrent); end
                obj.StageLabels(k).Text=sprintf('%s %s %d%% %.1fs',char(symbol),char(state),progress,elapsed);
                obj.StageLabels(k).BackgroundColor=color;
                obj.StageLamps(k).Color=color;
                if current==names(k), obj.StageLabels(k).Tooltip=char(string(s.message)); else, obj.StageLabels(k).Tooltip=''; end
            end
        end
        function renderOverview(obj,s)
            indicator=obj.indicator(s); obj.StatusLabel.Text=char(indicator);
            obj.setTableData(obj.OverviewTable,{'Lifecycle',obj.displayValue(s.lifecycleState);'Current stage',obj.displayValue(s.currentStage); ...
                'Mode',obj.displayValue(s.mode);'Bus ID',obj.displayValue(s.busId);'IMU UID',obj.displayValue(s.imuUid); ...
                'Firmware',mat2str(s.firmwareVersion);'Sensor fusion',mat2str(s.sensorFusionMode); ...
                'Commit',obj.displayValue(s.checkoutCommit);'Stream owner',obj.displayValue(obj.field(s.realtime,'streamOwner',"none")); ...
                'Recorder',obj.displayValue(obj.field(s.recording,'status',"disabled"));'Last error',obj.displayValue(obj.lastError(s))});
        end
        function renderSignals(obj,s)
            history=s.signalHistory; if isempty(history), return; end
            x=obj.vector(history,'elapsedSeconds'); fields={{'longitudinalRaw','longitudinalFiltered'}, ...
                {'lateralRaw','lateralFiltered'},{'verticalRaw','verticalFiltered'}, ...
                {'yawRateRaw','yawRateFiltered'},{'longitudinalJerk'},{'lateralJerk'}, ...
                {'verticalJerk'},{'dataQuality'},{'callbackAgeMs'}};
            indices=obj.decimationIndices(numel(x)); renderedX=x(indices);
            for k=1:9
                if numel(fields{k})>1
                    raw=obj.vector(history,fields{k}{1}); filtered=obj.vector(history,fields{k}{2});
                    obj.setSeries(obj.RawLines(k),renderedX,raw(indices),obj.Config.showRawSignals);
                    obj.setSeries(obj.FilteredLines(k),renderedX,filtered(indices),obj.Config.showFilteredSignals);
                else
                    filtered=obj.vector(history,fields{k}{1});
                    obj.setSeries(obj.RawLines(k),[],[],false);
                    obj.setSeries(obj.FilteredLines(k),renderedX,filtered(indices),obj.Config.showFilteredSignals);
                end
                obj.renderThresholds(k);
                obj.renderEventMarkers(k,s,x,history,fields{k}{end});
                if obj.Config.autoScaleSignals
                    obj.SignalAxes(k).XLimMode='auto'; obj.SignalAxes(k).YLimMode='auto';
                elseif strcmp(obj.SignalAxes(k).YLimMode,'auto')
                    limits=ylim(obj.SignalAxes(k)); obj.SignalAxes(k).YLim=limits;
                end
            end
        end
        function renderEvents(obj,s)
            types=["BRAKING_CANDIDATE","ACCELERATION_CANDIDATE","TURN_LEFT_CANDIDATE","TURN_RIGHT_CANDIDATE","VERTICAL_SHOCK_CANDIDATE"];
            states=repmat("IDLE",5,1);
            for k=1:numel(s.activeEvents), if isfield(s.activeEvents(k),'type'), states(types==string(s.activeEvents(k).type))="ACTIVE"; end, end
            obj.setTableData(obj.DetectorTable,[cellstr(types(:)),cellstr(states(:))]);
            e=s.recentEvents; data=cell(numel(e),10);
            for k=1:numel(e), data(k,:)={obj.displayValue(obj.field(e(k),'eventId',"")),obj.displayValue(obj.field(e(k),'type',"")), ...
                    obj.displayValue(obj.field(e(k),'startTimestamp',"")),obj.field(e(k),'durationSeconds',NaN), ...
                    obj.field(e(k),'peakAcceleration',NaN),obj.field(e(k),'peakJerk',NaN), ...
                    obj.field(e(k),'peakYawRate',NaN),obj.field(e(k),'sampleCount',0), ...
                    obj.field(e(k),'dataQuality',NaN),obj.displayValue(obj.field(e(k),'terminationReason',""))}; end
            obj.setTableData(obj.EventTable,data);
        end
        function renderQuality(obj,s)
            c=s.callback; fields={'averageFrequencyHz','currentCallbackAgeMs','maximumCallbackAgeMs','bufferUtilization', ...
                'received','buffered','missingSamples','duplicateSamples','invalidSamples','lateSamples', ...
                'overflowDropped','coalesced','staleSessionDropped'};
            data=cell(numel(fields)+1,2); data(1,:)={'status',obj.displayValue(obj.qualityStatus(c))};
            for k=1:numel(fields), data(k+1,:)={fields{k},obj.field(c,fields{k},0)}; end
            obj.setTableData(obj.QualityTable,data);
            history=s.signalHistory;
            if ~isempty(history)
                x=obj.vector(history,'elapsedSeconds'); age=obj.vector(history,'callbackAgeMs'); quality=obj.vector(history,'dataQuality');
                indices=obj.decimationIndices(numel(x)); x=x(indices); age=age(indices); quality=quality(indices);
                frequency=obj.vector(history,'effectiveFrequencyHz');
                obj.setSeries(obj.QualityLines(1),x,age,true);
                obj.setSeries(obj.QualityLines(2),x,100*quality,true);
                obj.setSeries(obj.QualityLines(3),x,repmat(100*c.bufferUtilization,size(x)),true);
                obj.setSeries(obj.QualityLines(4),x,frequency(indices),true);
            end
        end
        function renderCalibration(obj,s)
            if ~obj.Config.enableCalibrationTab || isempty(obj.CalibrationTable), return; end
            c=s.calibration; names=fieldnames(c); data=cell(numel(names),2);
            for k=1:numel(names), data(k,:)={names{k},obj.displayValue(c.(names{k}))}; end
            obj.setTableData(obj.CalibrationTable,data);
            directions=[eye(3);zeros(3)];
            if isfield(c,'rotationVehicleFromSensor') && isequal(size(c.rotationVehicleFromSensor),[3 3])
                directions(4:6,:)=c.rotationVehicleFromSensor;
            end
            for axisIndex=1:6
                direction=directions(axisIndex,:); q=obj.CalibrationQuivers(axisIndex);
                q.UData=direction(1); q.VData=direction(2); q.WData=direction(3);
            end
        end
        function renderRecording(obj,s)
            if ~obj.Config.enableRecordingTab || isempty(obj.RecordingTable), return; end
            r=s.recording; names=fieldnames(r); data=cell(numel(names),2);
            for k=1:numel(names), data(k,:)={names{k},obj.displayValue(r.(names{k}))}; end
            obj.setTableData(obj.RecordingTable,data);
            sizeRatio=obj.ratio(obj.field(r,'bytesWritten',0)+obj.field(r,'estimatedBufferedBytes',0),obj.field(r,'maximumSessionBytes',0));
            durationRatio=obj.ratio(obj.field(r,'durationSeconds',0),obj.field(r,'maximumDurationSeconds',0));
            freeRatio=obj.ratio(obj.field(r,'freeDiskBytes',0),obj.field(r,'minimumFreeDiskBytes',0));
            obj.RecordingGauges(1).Value=sizeRatio; obj.RecordingGauges(2).Value=durationRatio; obj.RecordingGauges(3).Value=freeRatio;
        end
        function renderAcceptance(obj,s)
            if ~obj.Config.enableAcceptanceTab || isempty(obj.AcceptanceTable), return; end
            stages=s.stageHistory; data=cell(numel(stages),4);
            for k=1:numel(stages), data(k,:)={obj.displayValue(obj.field(stages(k),'stage',"")),obj.displayValue(obj.field(stages(k),'state',"")), ...
                    obj.field(stages(k),'progress',0),obj.displayValue(obj.field(stages(k),'message',""))}; end
            summary=s.acceptance;
            if isstruct(summary)
                names=fieldnames(summary); summaryData=cell(numel(names),4);
                for k=1:numel(names), summaryData(k,:)={['Summary.' names{k}],'',[],obj.displayValue(summary.(names{k}))}; end
                data=[data;summaryData];
            end
            obj.setTableData(obj.AcceptanceTable,data);
        end
        function renderLog(obj,s)
            log=s.log; data=cell(numel(log),6);
            if ~isempty(obj.LogFilter) && isvalid(obj.LogFilter) && ~strcmp(obj.LogFilter.Value,'All')
                keep=false(numel(log),1); filter=string(obj.LogFilter.Value);
                for index=1:numel(log)
                    severity=upper(string(obj.field(log(index),'severity',""))); type=lower(string(obj.field(log(index),'type',"")));
                    switch filter
                        case "Lifecycle", keep(index)=contains(type,"lifecycle");
                        case "Events", keep(index)=contains(type,"event");
                        case "Warnings", keep(index)=severity=="WARNING";
                        case "Errors", keep(index)=severity=="ERROR";
                        case "Operator", keep(index)=string(obj.field(log(index),'source',""))=="operator";
                    end
                end
                log=log(keep); data=cell(numel(log),6);
            end
            for k=1:numel(log), data(k,:)={obj.displayValue(obj.field(log(k),'timestamp',"")),obj.displayValue(obj.field(log(k),'severity',"")), ...
                    obj.displayValue(obj.field(log(k),'source',"")),obj.displayValue(obj.field(log(k),'stage',"")), ...
                    obj.displayValue(obj.field(log(k),'type',"")),obj.displayValue(obj.field(log(k),'message',""))}; end
            obj.setTableData(obj.LogTable,data);
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
            if ~usejava('desktop') && (obj.field(status,'isAcceptanceRunning',false) || ...
                    obj.field(status,'isCalibrationRunning',false) || obj.field(status,'isRealtimeRunning',false))
                return;
            end
            if obj.field(status,'isAcceptanceRunning',false)
                choice=uiconfirm(obj.Figure,'Hardware acceptance is active and cannot be cancelled safely.', ...
                    'Close dashboard','Options',{'Leave acceptance running','Cancel close'}, ...
                    'DefaultOption',2,'CancelOption',2);
                if strcmp(choice,'Cancel close'), return; end
                previous=obj.Config.closeStopsSystem; obj.Config.closeStopsSystem=false;
                cleanup=onCleanup(@()obj.restoreCloseOption(previous)); obj.close(); clear cleanup;
                return;
            end
            if obj.field(status,'isCalibrationRunning',false)
                choice=uiconfirm(obj.Figure,'Calibration is active.', ...
                    'Close dashboard','Options',{'Cancel calibration and close','Leave calibration running','Cancel'}, ...
                    'DefaultOption',1,'CancelOption',3);
                if strcmp(choice,'Cancel'), return; end
                if strcmp(choice,'Leave calibration running')
                    previous=obj.Config.closeStopsSystem; obj.Config.closeStopsSystem=false;
                    cleanup=onCleanup(@()obj.restoreCloseOption(previous)); obj.close(); clear cleanup;
                    return;
                end
            end
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
            values=obj.thresholdValues(index);
            for thresholdIndex=1:4
                visible=obj.Config.showThresholds && thresholdIndex<=numel(values);
                if visible
                    obj.ThresholdLines(index,thresholdIndex).Value=values(thresholdIndex);
                    obj.ThresholdLines(index,thresholdIndex).Visible='on';
                else
                    obj.ThresholdLines(index,thresholdIndex).Visible='off';
                end
            end
        end
        function renderEventMarkers(obj,index,s,x,history,fieldName)
            handle=obj.MarkerScatters(index);
            if ~obj.Config.showEventMarkers || isempty(x) || isempty(s.recentEvents)
                obj.setSeries(handle,[],[],false); return;
            end
            markerX=[];
            for k=1:numel(s.recentEvents)
                value=obj.field(s.recentEvents(k),'startElapsedSeconds',NaN);
                if isfinite(value) && value>=x(1) && value<=x(end), markerX(end+1)=value; end %#ok<AGROW>
            end
            if isempty(markerX), obj.setSeries(handle,[],[],false); return; end
            y=obj.vector(history,fieldName); markerY=interp1(x,y,markerX,'nearest','extrap');
            obj.setSeries(handle,markerX,markerY,true);
        end
        function values=thresholdValues(obj,index)
            t=obj.ThresholdConfig;
            switch index
                case 1, values=[t.brakingStartThreshold,t.brakingStopThreshold,t.accelerationStartThreshold,t.accelerationStopThreshold];
                case 2, values=[-t.lateralStartThreshold,-t.lateralStopThreshold,t.lateralStopThreshold,t.lateralStartThreshold];
                case 3, values=[-t.verticalShockThreshold,t.verticalShockThreshold];
                case 4, values=[-t.yawRateStartThresholdDegPerSecond,-t.yawRateStopThresholdDegPerSecond,t.yawRateStopThresholdDegPerSecond,t.yawRateStartThresholdDegPerSecond];
                case {5,6,7}, values=[-t.jerkCandidateThreshold,t.jerkCandidateThreshold];
                otherwise, values=[];
            end
        end
        function indices=decimationIndices(obj,count)
            maximum=obj.Config.maximumRenderedPointsPerSeries;
            if count<=maximum, indices=1:count; return; end
            indices=unique(round(linspace(1,count,maximum)));
        end
        function setSeries(~,handle,x,y,visible)
            handle.XData=x; handle.YData=y;
            if visible, handle.Visible='on'; else, handle.Visible='off'; end
        end
        function setTableData(~,handle,data)
            if ~isequaln(handle.Data,data), handle.Data=data; end
        end
        function setDisplayOption(obj,name,value)
            obj.Config.(name)=logical(value); obj.renderSafely();
        end
        function elapsed=stageElapsed(obj,s,name)
            elapsed=0; stages=s.stageHistory;
            for index=numel(stages):-1:1
                if string(obj.field(stages(index),'stage',""))==name
                    elapsed=double(obj.field(stages(index),'elapsedSeconds',0)); return;
                end
            end
        end
        function checkRenderDuration(obj)
            if obj.LastRenderMilliseconds<=obj.Config.maximumRenderMilliseconds, return; end
            nowValue=obj.Dependencies.nowUtc();
            if ~isnat(obj.LastRenderWarningAt) && seconds(nowValue-obj.LastRenderWarningAt)<10, return; end
            obj.LastRenderWarningAt=nowValue;
            message=sprintf('Dashboard render took %.1f ms (limit %.1f ms).', ...
                obj.LastRenderMilliseconds,obj.Config.maximumRenderMilliseconds);
            warning('IMU:SystemDashboardSlowRender','%s',message);
            try
                obj.Controller.TelemetryHub.ingestWarning(struct('identifier',"IMU:SystemDashboardSlowRender", ...
                    'message',string(message),'renderMilliseconds',obj.LastRenderMilliseconds));
            catch
            end
        end
        function dependencies=mergeDependencies(~,custom)
            defaults=struct('createTimer',@timer,'nowUtc',@()datetime('now','TimeZone','UTC'), ...
                'exportPng',@exportDashboardPng, ...
                'writeJson',@writeDashboardJson,'saveMat',@saveDashboardMat);
            if ~isstruct(custom) || ~isscalar(custom)
                error('IMU:InvalidDashboardDependencies','Dashboard dependencies must be a scalar struct.');
            end
            unknown=setdiff(fieldnames(custom),fieldnames(defaults));
            if ~isempty(unknown), error('IMU:InvalidDashboardDependencies','Unknown dependency: %s.',unknown{1}); end
            dependencies=defaults; names=fieldnames(custom);
            for index=1:numel(names), dependencies.(names{index})=custom.(names{index}); end
        end
        function value=ratio(~,numerator,denominator)
            if isempty(denominator) || ~isfinite(double(denominator)) || denominator<=0, value=0;
            else, value=max(0,min(100,100*double(numerator)/double(denominator))); end
        end
        function focusEvent(obj,event)
            if isempty(event.Indices) || size(event.Indices,1)~=1 || ...
                    ~strcmp(obj.Figure.SelectionType,'open'), return; end
            row=event.Indices(1); events=obj.LastSnapshot.recentEvents;
            if row>numel(events), return; end
            startTime=obj.field(events(row),'startElapsedSeconds',NaN);
            duration=obj.field(events(row),'durationSeconds',1);
            if ~isfinite(startTime), return; end
            window=[startTime-max(1,duration),startTime+max(1,2*duration)];
            for axisIndex=1:numel(obj.SignalAxes), xlim(obj.SignalAxes(axisIndex),window); end
        end
        function value=indicator(obj,s)
            state=string(s.lifecycleState);
            if state=="FAILED", value="FAILED"; elseif state=="CALIBRATION_REQUIRED", value="CALIBRATION REQUIRED";
            elseif any(state==["STOP_REQUESTED","STOP_DEFERRED","STOPPING","QUIESCING","DRAINING_TAIL", ...
                    "FINAL_STATS","FINALIZING_EVENTS","FINALIZING_RECORDING","CLEARING_BUFFER","RELEASING_OWNER"]), value="STOPPING";
            elseif state=="STREAMING" && obj.qualityStatus(s.callback)~="GOOD", value="DEGRADED DATA";
            elseif state=="STREAMING", value="STREAMING"; elseif state=="READY", value="SYSTEM READY"; else, value="SYSTEM "+state; end
        end
        function completed=completedStages(obj,s)
            completed=strings(0,1); stages=s.stageHistory;
            for k=1:numel(stages)
                if isfield(stages(k),'state') && string(stages(k).state)=="PASSED"
                    completed(end+1,1)=obj.pipelineStageName(string(stages(k).stage));
                end
            end
        end
        function value=pipelineStageName(~,value)
            switch lower(string(value))
                case "bootstrap", value="Bootstrap";
                case "class_api", value="Class API";
                case "commit_check", value="IMU";
                case "installation_calibration", value="Calibration";
                case {"runtime_fifo","realtime_monitor"}, value="Realtime";
                case "summary_validation", value="Result";
                case "artifact_save", value="Result";
            end
        end
    end
end

function writeDashboardJson(filename,value)
fileId=fopen(filename,'w');
if fileId<0, error('IMU:SnapshotWriteFailed','Unable to open %s.',filename); end
cleanup=onCleanup(@()fclose(fileId));
fprintf(fileId,'%s',jsonencode(value,'PrettyPrint',true));
clear cleanup;
end

function saveDashboardMat(filename,snapshot,config)
save(filename,'snapshot','config','-v7');
end

function exportDashboardPng(figureHandle,filename)
exportapp(figureHandle,filename);
end
