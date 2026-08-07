function [summary,controller,dashboard]=runSyntheticSystemVisualizationDemoBlocking(showDashboard)
%RUNSYNTHETICSYSTEMVISUALIZATIONDEMOBLOCKING Run and await the synthetic demo.
if nargin<1, showDashboard=true; end
[controller,dashboard,summary]=run_synthetic_system_visualization_demo(showDashboard, ...
    struct('WaitForCompletion',true));
end
