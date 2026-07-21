function processed = preprocessDrivingSession(session, config)
%PREPROCESSDRIVINGSESSION Despike, filter, and differentiate vehicle signals.
%   Uses only base MATLAB and never differentiates across sequence gaps.

if nargin < 2 || isempty(config), config = getDrivingAnalysisConfig(); end
config = validateDrivingAnalysisConfig(config);
if ~isstruct(session) || ~isscalar(session) || ~isfield(session, 'data') || ...
        ~istable(session.data)
    error('IMU:InvalidDrivingSession', 'session.data must be a MATLAB table.');
end
if ~isfield(session, 'sampleRateHz') || ...
        ~(isnumeric(session.sampleRateHz) && isscalar(session.sampleRateHz) && ...
        isfinite(session.sampleRateHz) && session.sampleRateHz > 0)
    error('IMU:InvalidDrivingSession', ...
        'session.sampleRateHz must contain the confirmed source frequency.');
end
sampleRateHz = double(session.sampleRateHz);
data = session.data;
required = {'sequenceNumber','hostTimestamp','sessionId','timeSeconds', ...
    'longitudinalAcceleration','lateralAcceleration','verticalAcceleration', ...
    'yawRate','callbackAgeMs'};
if ~all(ismember(required, data.Properties.VariableNames))
    error('IMU:InvalidDrivingSession', 'Session table lacks required channels.');
end

sequence = uint64(data.sequenceNumber(:));
longitudinalRaw = double(data.longitudinalAcceleration(:));
lateralRaw = double(data.lateralAcceleration(:));
verticalRaw = double(data.verticalAcceleration(:));
yawRateRaw = double(data.yawRate(:));
callbackAgeMs = double(data.callbackAgeMs(:));
dataValid = isfinite(longitudinalRaw) & isfinite(lateralRaw) & ...
    isfinite(verticalRaw) & isfinite(yawRateRaw) & isfinite(callbackAgeMs);
segmentId = assignSegments(sequence, data.hostTimestamp(:), dataValid, config);

longitudinalDespiked = longitudinalRaw;
lateralDespiked = lateralRaw;
verticalDespiked = verticalRaw;
yawDespiked = yawRateRaw;
outlierReplaced = false(height(data), 1);
segments = unique(segmentId(segmentId > 0)).';
for segment = segments
    indices = find(segmentId == segment);
    [longitudinalDespiked(indices), replaced] = robustDespike( ...
        longitudinalRaw(indices), config);
    outlierReplaced(indices) = outlierReplaced(indices) | replaced;
    [lateralDespiked(indices), replaced] = robustDespike(lateralRaw(indices), config);
    outlierReplaced(indices) = outlierReplaced(indices) | replaced;
    [verticalDespiked(indices), replaced] = robustDespike(verticalRaw(indices), config);
    outlierReplaced(indices) = outlierReplaced(indices) | replaced;
    [yawDespiked(indices), replaced] = robustDespike(yawRateRaw(indices), config);
    outlierReplaced(indices) = outlierReplaced(indices) | replaced;
end

longitudinalFiltered = nan(height(data), 1);
lateralFiltered = nan(height(data), 1);
verticalFiltered = nan(height(data), 1);
yawRateFiltered = nan(height(data), 1);
longitudinalJerk = nan(height(data), 1);
lateralJerk = nan(height(data), 1);
verticalJerk = nan(height(data), 1);
for segment = segments
    indices = find(segmentId == segment);
    longitudinalFiltered(indices) = zeroPhaseEma( ...
        longitudinalDespiked(indices), sampleRateHz, config.lowPassCutoffHz);
    lateralFiltered(indices) = zeroPhaseEma( ...
        lateralDespiked(indices), sampleRateHz, config.lowPassCutoffHz);
    verticalFiltered(indices) = zeroPhaseEma( ...
        verticalDespiked(indices), sampleRateHz, config.lowPassCutoffHz);
    yawRateFiltered(indices) = zeroPhaseEma( ...
        yawDespiked(indices), sampleRateHz, config.lowPassCutoffHz);
    longitudinalJerk(indices) = centralDifference( ...
        longitudinalFiltered(indices), sampleRateHz);
    lateralJerk(indices) = centralDifference( ...
        lateralFiltered(indices), sampleRateHz);
    verticalJerk(indices) = centralDifference( ...
        verticalFiltered(indices), sampleRateHz);
end

processed = struct('sequenceNumber', sequence, ...
    'hostTimestamp', data.hostTimestamp(:), 'sessionId', data.sessionId(:), ...
    'timeSeconds', double(data.timeSeconds(:)), ...
    'callbackAgeMs', callbackAgeMs, ...
    'longitudinalRaw', longitudinalRaw, ...
    'longitudinalFiltered', longitudinalFiltered, ...
    'longitudinalJerk', longitudinalJerk, ...
    'lateralRaw', lateralRaw, 'lateralFiltered', lateralFiltered, ...
    'lateralJerk', lateralJerk, 'verticalRaw', verticalRaw, ...
    'verticalFiltered', verticalFiltered, 'verticalJerk', verticalJerk, ...
    'yawRateRaw', yawRateRaw, 'yawRateFiltered', yawRateFiltered, ...
    'segmentId', segmentId, 'dataValid', dataValid, ...
    'outlierReplaced', outlierReplaced, 'sampleRateHz', sampleRateHz, ...
    'config', config);
end

function segmentId = assignSegments(sequence, hostTimestamp, valid, config)
segmentId = zeros(numel(sequence), 1);
current = 0;
for index = 1:numel(sequence)
    if ~valid(index), continue; end
    timestampGap = false;
    if index > 1 && valid(index - 1)
        timestampGap = seconds(hostTimestamp(index) - ...
            hostTimestamp(index - 1)) > config.segmentGapSeconds;
    end
    startsSegment = index == 1 || ~valid(index - 1) || ...
        sequence(index) ~= sequence(index - 1) + 1 || timestampGap;
    if startsSegment, current = current + 1; end
    segmentId(index) = current;
end
end

function [output, replaced] = robustDespike(values, config)
values = double(values(:));
output = values;
replaced = false(size(values));
halfWindow = floor(config.medianWindowSamples / 2);
for index = 1:numel(values)
    first = max(1, index - halfWindow);
    last = min(numel(values), index + halfWindow);
    window = values(first:last);
    center = median(window);
    localMad = median(abs(window - center));
    difference = abs(values(index) - center);
    if localMad > eps(max(1, abs(center)))
        isOutlier = difference > config.outlierMadThreshold * 1.4826 * localMad;
    else
        hasNeighbors = index > 1 && index < numel(values);
        isOutlier = hasNeighbors && difference > eps(max(1, abs(center))) && ...
            abs(values(index - 1) - center) <= eps(max(1, abs(center))) && ...
            abs(values(index + 1) - center) <= eps(max(1, abs(center)));
    end
    if isOutlier, output(index) = center; replaced(index) = true; end
end
end

function derivative = centralDifference(values, sampleRateHz)
derivative = nan(size(values));
if numel(values) < 3, return; end
derivative(2:end-1) = (values(3:end) - values(1:end-2)) * sampleRateHz / 2;
end
