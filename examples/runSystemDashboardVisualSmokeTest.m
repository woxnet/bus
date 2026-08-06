function result=runSystemDashboardVisualSmokeTest()
%RUNSYSTEMDASHBOARDVISUALSMOKETEST Observe a real timer-driven dashboard run.
lastwarn('');
[controller,dashboard,~]=run_synthetic_system_visualization_demo(true);
cleanup=onCleanup(@()delete(dashboard));
uiWarnings=strings(0,1); started=tic;
while controller.IsSimulationRunning && toc(started)<12
    pause(0.05); drawnow;
    [message,identifier]=lastwarn();
    if any(string(identifier)==["IMU:SystemDashboardRenderFailed","MATLAB:timer:TimerFcnError"])
        uiWarnings(end+1,1)=string(identifier)+": "+string(message); %#ok<AGROW>
    end
    lastwarn('');
end
controller.waitForCompletion(1); pause(0.5); drawnow;
renderWait=tic;
while dashboard.RenderCount<20 && toc(renderWait)<15, pause(0.1); drawnow; end
summary=controller.getSimulationSummary(); snapshot=controller.getTelemetrySnapshot();
required=["STOP_DEFERRED","QUIESCING","DRAINING_TAIL","RELEASING_OWNER","STOPPED"];
eventTypes=unique(string({snapshot.recentEvents.type}));
assert(summary.durationSeconds>=60 && numel(snapshot.recentEvents)>=3 && ~isempty(snapshot.warnings));
assert(dashboard.RenderCount>=20 && numel(unique(controller.TransitionHistory))>=5);
assert(numel(eventTypes)>=3 && all(ismember(required,controller.TransitionHistory)));
files=dashboard.saveSnapshot(resolveProjectPath('artifacts'));
assert(isfile(files.pngFile));
unhandled=[uiWarnings;controller.TimerErrors];
result=struct('success',isempty(unhandled),'summary',summary,'files',files, ...
    'tabCount',numel(dashboard.getTabNames()),'renderCount',dashboard.RenderCount, ...
    'maximumRenderMilliseconds',dashboard.MaximumObservedRenderMilliseconds, ...
    'observedLifecycleStates',controller.TransitionHistory,'observedEventTypes',eventTypes, ...
    'warningCount',numel(snapshot.warnings),'unhandledUiExceptions',numel(unhandled), ...
    'unhandledUiExceptionMessages',unhandled);
assert(result.success);
clear cleanup; delete(dashboard);
end
