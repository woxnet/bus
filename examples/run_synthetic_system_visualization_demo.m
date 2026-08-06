function [syntheticController,syntheticDashboard,summary]=run_synthetic_system_visualization_demo(showDashboard)
%RUN_SYNTHETIC_SYSTEM_VISUALIZATION_DEMO Hardware-free 60-second scenario.
% SYNTHETIC DEMONSTRATION - NOT A HARDWARE ACCEPTANCE.
if nargin<1, showDashboard=true; end
fprintf('SYNTHETIC DEMONSTRATION\nNOT A HARDWARE ACCEPTANCE\n');
syntheticController=SyntheticBusDrivingSystemController();
syntheticDashboard=BusDrivingSystemDashboard(syntheticController);
if showDashboard, syntheticDashboard.open(); end
syntheticController.startSimulation(60,10);
summary=syntheticController.getSimulationSummary();
end
