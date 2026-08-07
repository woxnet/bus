function result=runSystemDashboardVisualSmokeTest()
%RUNSYSTEMDASHBOARDVISUALSMOKETEST Exercise every tab during a timer-driven run.
lastwarn(''); retryInjected=false;
dashboardDependencies=struct('beforeTabRender',@injectOneRenderFailure);
[controller,dashboard,~]=run_synthetic_system_visualization_demo(true, ...
    struct('SimulationSpeed',4,'DashboardDependencies',dashboardDependencies));
cleanup=onCleanup(@()delete(dashboard));
uiWarnings=strings(0,1);
tabs=["Overview","Signals","Events","Data quality","Calibration","Recording","Hardware acceptance"];
exerciseRun(); firstSummary=controller.getSimulationSummary(); firstSnapshot=controller.getTelemetrySnapshot();
firstRunId=firstSnapshot.runId;

controller.startSimulation(60,4);
dashboard.selectTab("Signals"); dashboard.render(); cleanDiagnostics=dashboard.getGraphicsDiagnostics();
signalsStartedClean=all(arrayfun(@(h)isempty(h.XData),cleanDiagnostics.rawLines)) && ...
    all(arrayfun(@(h)isempty(h.XData),cleanDiagnostics.filteredLines));
dashboard.selectTab("Events"); dashboard.render(); cleanDiagnostics=dashboard.getGraphicsDiagnostics();
eventsStartedClean=isempty(cleanDiagnostics.eventTable.Data) && ...
    ~cleanDiagnostics.detectorActivationObserved && ~cleanDiagnostics.eventMarkerObserved;
dashboard.selectTab("Hardware acceptance"); dashboard.render(); cleanDiagnostics=dashboard.getGraphicsDiagnostics();
acceptanceNamesAtStart=firstColumn(cleanDiagnostics.acceptanceTable.Data);
acceptanceStartedClean=~any(acceptanceNamesAtStart=="Summary.success");
secondRunStartedClean=signalsStartedClean && eventsStartedClean && acceptanceStartedClean;
secondRunId=controller.getSummarySnapshot().runId;
assert(secondRunId~=firstRunId && secondRunStartedClean && firstSummary.success);

exerciseRun();
summary=controller.getSimulationSummary(); snapshot=controller.getTelemetrySnapshot();
diagnostics=dashboard.getGraphicsDiagnostics();
required=["STOP_DEFERRED","QUIESCING","DRAINING_TAIL","RELEASING_OWNER","STOPPED"];
eventTypes=unique(string({snapshot.recentEvents.type}));
assert(summary.durationSeconds>=60 && numel(snapshot.recentEvents)==3 && ~isempty(snapshot.warnings));
assert(numel(unique(controller.TransitionHistory))>=5 && all(ismember(required,controller.TransitionHistory)));

rawRendered=any(arrayfun(@(h)numel(h.XData)>0,diagnostics.rawLines));
filteredRendered=any(arrayfun(@(h)numel(h.XData)>0,diagnostics.filteredLines));
markersRendered=diagnostics.eventMarkerObserved;
eventRows=size(diagnostics.eventTable.Data,1);
qualityPointsRendered=numel(diagnostics.qualityLines(1).XData);
qualityRendered=qualityPointsRendered>0 && numel(diagnostics.qualityLines(2).XData)>0 && ...
    numel(diagnostics.qualityLines(4).XData)>0;
calibrationNames=firstColumn(diagnostics.calibrationTable.Data);
calibrationRendered=any(calibrationNames=="verificationScore") && any(calibrationNames=="activationVerified");
quiverMagnitude=0;
for index=4:min(6,numel(diagnostics.calibrationQuivers))
    quiverMagnitude=quiverMagnitude+abs(diagnostics.calibrationQuivers(index).UData)+ ...
        abs(diagnostics.calibrationQuivers(index).VData)+abs(diagnostics.calibrationQuivers(index).WData);
end
recordingNames=firstColumn(diagnostics.recordingTable.Data);
recording= snapshot.recording;
recordingMetricsObserved=objField(recording,'bytesWritten',0)>0 && ...
    objField(recording,'durationSeconds',0)>0 && strlength(string(objField(recording,'stopReason',"")))>0 && ...
    all(ismember(["bytesWritten","durationSeconds","stopReason"],recordingNames));
acceptanceNames=firstColumn(diagnostics.acceptanceTable.Data);
acceptanceSummaryObserved=any(acceptanceNames=="Summary.success") && snapshot.acceptance.success;
logData=diagnostics.logTable.Data; logTypes=strings(0,1); logSeverities=strings(0,1); logSources=strings(0,1);
if ~isempty(logData)
    logSeverities=string(logData(:,2)); logSources=string(logData(:,3)); logTypes=string(logData(:,5));
end
logCoverage=any(contains(lower(logTypes),"lifecycle")) && any(contains(lower(logTypes),"event")) && ...
    any(upper(logSeverities)=="WARNING") && any(lower(logSources)=="acceptance");
tabRenderCounts=dashboard.TabRenderCounts; tabKeys=cellfun(@matlab.lang.makeValidName,cellstr([tabs,"Log"]),'UniformOutput',false);
allTabsRendered=all(cellfun(@(key)isfield(tabRenderCounts,key) && tabRenderCounts.(key)>=2,tabKeys));
renderRetryPassed=retryInjected && dashboard.RenderFailureCount>=1 && dashboard.RenderRetrySuccessCount>=1;

files=dashboard.saveSnapshot(resolveProjectPath('artifacts')); assert(isfile(files.pngFile));
unhandled=[uiWarnings;controller.TimerErrors];
desktopMeasured=usejava('desktop'); performancePassed=~desktopMeasured || ...
    (dashboard.RenderP95Milliseconds<=100 && dashboard.ConsecutiveDeadlineMisses<2);
contentPassed=rawRendered && filteredRendered && markersRendered && eventRows==3 && ...
    diagnostics.detectorActivationObserved && qualityRendered && calibrationRendered && ...
    quiverMagnitude>0 && recordingMetricsObserved && acceptanceSummaryObserved && logCoverage && allTabsRendered;
result=struct('success',isempty(unhandled) && performancePassed && contentPassed && renderRetryPassed, ...
    'summary',summary,'files',files,'tabCount',numel(dashboard.getTabNames()), ...
    'firstRunId',firstRunId,'secondRunId',secondRunId, ...
    'secondRunStartedClean',secondRunStartedClean, ...
    'syntheticSampleRateHz',controller.TelemetryHub.Config.sampleRateHz, ...
    'signalHistoryDurationSeconds',snapshot.signalHistory(end).elapsedSeconds-snapshot.signalHistory(1).elapsedSeconds, ...
    'renderCount',dashboard.RenderCount,'tabRenderCounts',tabRenderCounts, ...
    'runtimeTelemetryRefreshCount',controller.RuntimeTelemetryRefreshCount, ...
    'qualityPointsRendered',qualityPointsRendered, ...
    'recordingMetricsObserved',recordingMetricsObserved, ...
    'acceptanceSummaryObserved',acceptanceSummaryObserved,'renderRetryPassed',renderRetryPassed, ...
    'initialRenderMilliseconds',dashboard.InitialRenderMilliseconds, ...
    'renderP50Milliseconds',dashboard.RenderP50Milliseconds, ...
    'renderP95Milliseconds',dashboard.RenderP95Milliseconds, ...
    'maximumSteadyStateRenderMilliseconds',dashboard.MaximumSteadyStateRenderMilliseconds, ...
    'droppedRenderTicks',dashboard.DroppedRenderTicks, ...
    'consecutiveDeadlineMisses',dashboard.ConsecutiveDeadlineMisses, ...
    'observedLifecycleStates',controller.TransitionHistory,'observedEventTypes',eventTypes, ...
    'warningCount',numel(snapshot.warnings),'unhandledUiExceptions',numel(unhandled), ...
    'unhandledUiExceptionMessages',unhandled);
if ~result.success
    disp(struct('rawRendered',rawRendered,'filteredRendered',filteredRendered, ...
        'markersRendered',markersRendered,'eventRows',eventRows, ...
        'detectorActivationObserved',diagnostics.detectorActivationObserved, ...
        'qualityRendered',qualityRendered,'calibrationRendered',calibrationRendered, ...
        'quiverMagnitude',quiverMagnitude,'recordingMetricsObserved',recordingMetricsObserved, ...
        'acceptanceSummaryObserved',acceptanceSummaryObserved,'logCoverage',logCoverage, ...
        'allTabsRendered',allTabsRendered,'renderRetryPassed',renderRetryPassed, ...
        'performancePassed',performancePassed,'unhandled',unhandled));
end
assert(result.success); clear cleanup; delete(dashboard);

    function injectOneRenderFailure(tab,~)
        if string(tab)=="Signals" && ~retryInjected
            retryInjected=true; error('Test:SmokeRenderRetry','Injected smoke render retry.');
        end
    end
    function exerciseRun()
        thresholds=[0 7 19 43 47 51 55]; selectedIndex=1;
        dashboard.selectTab(tabs(selectedIndex)); selectedBaseline=tabCount(tabs(selectedIndex));
        started=tic;
        while controller.IsSimulationRunning && toc(started)<20
            if selectedIndex<numel(tabs) && controller.SimulatedSeconds>=thresholds(selectedIndex+1) && ...
                    tabCount(tabs(selectedIndex))>=selectedBaseline+2
                selectedIndex=selectedIndex+1; dashboard.selectTab(tabs(selectedIndex));
                selectedBaseline=tabCount(tabs(selectedIndex));
            end
            pause(0.05); drawnow; collectWarning();
        end
        controller.waitForCompletion(2);
        for tab=[tabs,"Log"], waitForTabCycles(tab,2); end
    end
    function collectWarning()
        [message,identifier]=lastwarn();
        if any(string(identifier)==["IMU:SystemDashboardRenderFailed","MATLAB:timer:TimerFcnError"]) && ...
                ~contains(string(message),"Injected smoke render retry")
            uiWarnings(end+1,1)=string(identifier)+": "+string(message); %#ok<AGROW>
        end
        lastwarn('');
    end
    function waitForTabCycles(tab,count)
        dashboard.selectTab(tab); key=matlab.lang.makeValidName(char(tab));
        baseline=0; if isfield(dashboard.TabRenderCounts,key), baseline=dashboard.TabRenderCounts.(key); end
        timer=tic;
        while toc(timer)<5
            pause(.05); drawnow; collectWarning();
            if isfield(dashboard.TabRenderCounts,key) && dashboard.TabRenderCounts.(key)>=baseline+count, return; end
        end
        error('IMU:SmokeTabRenderTimeout','Tab %s did not render %d cycles.',tab,count);
    end
    function value=tabCount(tab)
        key=matlab.lang.makeValidName(char(tab)); value=0;
        if isfield(dashboard.TabRenderCounts,key), value=dashboard.TabRenderCounts.(key); end
    end
end

function values=firstColumn(data)
values=strings(0,1); if ~isempty(data), values=string(data(:,1)); end
end

function value=objField(model,name,default)
value=default; if isstruct(model) && isfield(model,name), value=model.(name); end
end
