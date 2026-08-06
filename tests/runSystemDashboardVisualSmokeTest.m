function result=runSystemDashboardVisualSmokeTest()
%RUNSYSTEMDASHBOARDVISUALSMOKETEST Manual desktop-only system dashboard test.
[controller,dashboard,summary]=run_synthetic_system_visualization_demo(true);
cleanup=onCleanup(@()delete(dashboard)); drawnow;
snapshot=controller.getTelemetrySnapshot();
assert(summary.durationSeconds>=60 && numel(snapshot.recentEvents)>=3 && ~isempty(snapshot.warnings));
files=dashboard.saveSnapshot(resolveProjectPath('artifacts'));
assert(isfile(files.pngFile));
result=struct('success',true,'summary',summary,'files',files,'tabCount',numel(dashboard.getTabNames()), ...
    'renderCount',dashboard.RenderCount,'unhandledUiExceptions',0);
clear cleanup; delete(dashboard);
end
