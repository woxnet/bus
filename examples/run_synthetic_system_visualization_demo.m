function [syntheticController,syntheticDashboard,summary]=run_synthetic_system_visualization_demo(showDashboard,options)
%RUN_SYNTHETIC_SYSTEM_VISUALIZATION_DEMO Hardware-free 60-second scenario.
% SYNTHETIC DEMONSTRATION - NOT A HARDWARE ACCEPTANCE.
if nargin<1, showDashboard=true; end
if nargin<2 || isempty(options), options=struct(); end
waitForCompletion=isfield(options,'WaitForCompletion') && logical(options.WaitForCompletion);
fprintf('SYNTHETIC DEMONSTRATION\nNOT A HARDWARE ACCEPTANCE\n');
syntheticController=SyntheticBusDrivingSystemController();
syntheticDashboard=BusDrivingSystemDashboard(syntheticController);
if showDashboard, syntheticDashboard.open(); end
syntheticController.startSimulation(60,10);
summary=[];
if waitForCompletion
    syntheticController.waitForCompletion(10); summary=syntheticController.getSimulationSummary();
end
end
