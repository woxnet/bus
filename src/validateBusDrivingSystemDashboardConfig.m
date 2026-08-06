function config=validateBusDrivingSystemDashboardConfig(config)
%VALIDATEBUSDRIVINGSYSTEMDASHBOARDCONFIG Validate dashboard limits.
if ~isstruct(config) || ~isscalar(config)
    error('IMU:InvalidSystemDashboardConfig','Configuration must be a scalar struct.');
end
imu=getImuConfig();
defaults=struct('refreshHz',5,'maximumRefreshHz',10,'sampleRateHz',imu.sampleRateHz, ...
    'signalHistorySeconds',30,'maximumEventRows',500, ...
    'maximumLogRows',1000,'maximumStageHistory',100, ...
    'showRawSignals',true,'showFilteredSignals',true, ...
    'showThresholds',true,'showEventMarkers',true, ...
    'enableCalibrationTab',true,'enableRecordingTab',true, ...
    'enableAcceptanceTab',true,'autoScaleSignals',false, ...
    'maximumRenderMilliseconds',50,'maximumRenderedPointsPerSeries',1500, ...
    'closeStopsSystem',true);
missing=setdiff(fieldnames(defaults),fieldnames(config));
unknown=setdiff(fieldnames(config),fieldnames(defaults));
if ~isempty(missing), error('IMU:InvalidSystemDashboardConfig','Missing setting: %s.',missing{1}); end
if ~isempty(unknown), error('IMU:InvalidSystemDashboardConfig','Unknown setting: %s.',unknown{1}); end
numeric={'refreshHz','maximumRefreshHz','sampleRateHz','signalHistorySeconds','maximumEventRows', ...
    'maximumLogRows','maximumStageHistory','maximumRenderMilliseconds','maximumRenderedPointsPerSeries'};
for k=1:numel(numeric)
    validateattributes(config.(numeric{k}),{'numeric'},{'scalar','real','finite','positive'});
end
integerNames={'maximumEventRows','maximumLogRows','maximumStageHistory','maximumRenderedPointsPerSeries'};
for k=1:numel(integerNames)
    validateattributes(config.(integerNames{k}),{'numeric'},{'integer'});
end
if config.refreshHz>config.maximumRefreshHz || config.maximumRefreshHz>10
    error('IMU:InvalidSystemDashboardConfig','Refresh rate must not exceed 10 Hz.');
end
logicalNames=setdiff(fieldnames(defaults),numeric);
for k=1:numel(logicalNames)
    if ~islogical(config.(logicalNames{k})) || ~isscalar(config.(logicalNames{k}))
        error('IMU:InvalidSystemDashboardConfig','%s must be scalar logical.',logicalNames{k});
    end
end
end
