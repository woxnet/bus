function [controller,dashboard]=runBusDrivingSystemDashboard(options)
%RUNBUSDRIVINGSYSTEMDASHBOARD Start the unified operator dashboard.
if nargin<1 || isempty(options), options=struct(); end
dependencies=struct(); dashboardDependencies=struct(); dashboardConfig=getBusDrivingSystemDashboardConfig(); openDashboard=true;
if isfield(options,'Dependencies'), dependencies=options.Dependencies; options=rmfield(options,'Dependencies'); end
if isfield(options,'DashboardConfig'), dashboardConfig=options.DashboardConfig; options=rmfield(options,'DashboardConfig'); end
if isfield(options,'DashboardDependencies')
    dashboardDependencies=options.DashboardDependencies; options=rmfield(options,'DashboardDependencies');
end
if isfield(options,'OpenDashboard'), openDashboard=logical(options.OpenDashboard); options=rmfield(options,'OpenDashboard'); end
dashboardConfig=validateBusDrivingSystemDashboardConfig(dashboardConfig);
options.dashboardConfig=dashboardConfig;
controller=BusDrivingSystemController(options,dependencies);
dashboard=BusDrivingSystemDashboard(controller,dashboardConfig,dashboardDependencies);
if openDashboard, dashboard.open(); end
end
