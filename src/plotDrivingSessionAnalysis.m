function figureHandle = plotDrivingSessionAnalysis(result)
%PLOTDRIVINGSESSIONANALYSIS Save diagnostic plots; never affects detection.

if ~isstruct(result) || ~isscalar(result) || ~isfield(result, 'success') || ...
        ~result.success || ~isfield(result, 'processed')
    error('IMU:InvalidAnalysisResult', 'A successful analysis result is required.');
end
p = result.processed; time = p.timeSeconds;
figureHandle = figure('Name', 'IMU driving-event analysis', 'Color', 'w');

subplot(5, 1, 1);
plot(time, p.longitudinalRaw, ':', time, p.longitudinalFiltered, '-', 'LineWidth', 1);
ylabel('Long. m/s^2'); grid on; markEvents(result.events, time, p.longitudinalFiltered, ...
    ["BRAKING_CANDIDATE","ACCELERATION_CANDIDATE"]);

subplot(5, 1, 2);
yyaxis left; plot(time, p.lateralFiltered, 'LineWidth', 1); ylabel('Lateral m/s^2');
yyaxis right; plot(time, p.yawRateFiltered, 'LineWidth', 1); ylabel('Yaw deg/s');
grid on; markEvents(result.events, time, p.lateralFiltered, ...
    ["TURN_LEFT_CANDIDATE","TURN_RIGHT_CANDIDATE"]);

subplot(5, 1, 3);
plot(time, p.verticalFiltered, 'LineWidth', 1); ylabel('Vertical m/s^2'); grid on;
markEvents(result.events, time, p.verticalFiltered, "VERTICAL_SHOCK_CANDIDATE");

subplot(5, 1, 4);
plot(time, p.longitudinalJerk, time, p.lateralJerk, time, p.verticalJerk);
ylabel('Jerk m/s^3'); legend('longitudinal','lateral','vertical'); grid on;

subplot(5, 1, 5);
stairs(time, p.segmentId, 'LineWidth', 1); hold on;
invalid = ~p.dataValid;
plot(time(invalid), p.segmentId(invalid), 'rx');
gapIndices = find(diff(double(p.sequenceNumber)) > 1) + 1;
plot(time(gapIndices), p.segmentId(gapIndices), 'ko', 'MarkerFaceColor', 'y');
ylabel('Segment'); xlabel('Time, s'); grid on;

if isfield(result, 'analysisDirectory') && strlength(result.analysisDirectory) > 0
    saveas(figureHandle, fullfile(char(result.analysisDirectory), 'diagnostic_plots.png'));
    savefig(figureHandle, fullfile(char(result.analysisDirectory), 'diagnostic_plots.fig'));
end
end

function markEvents(events, time, values, acceptedTypes)
hold on;
for index = 1:numel(events)
    if ~any(events(index).type == acceptedTypes), continue; end
    mask = time >= events(index).startTimeSeconds & time <= events(index).endTimeSeconds;
    plot(time(mask), values(mask), '.', 'MarkerSize', 8);
end
end
