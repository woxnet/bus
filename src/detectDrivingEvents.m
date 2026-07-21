function events = detectDrivingEvents(processed, config)
%DETECTDRIVINGEVENTS Detect preliminary IMU-only maneuver candidates.
%   Thresholds are engineering settings, not normative driving limits.

if nargin < 2 || isempty(config), config = getDrivingAnalysisConfig(); end
config = validateDrivingAnalysisConfig(config);
validateProcessed(processed);
valid = processed.dataValid & processed.segmentId > 0;

candidates = emptyCandidates();
candidates = appendCandidates(candidates, "BRAKING_CANDIDATE", ...
    hysteresisIntervals(processed.longitudinalFiltered <= ...
        config.brakingStartThreshold, processed.longitudinalFiltered >= ...
        config.brakingStopThreshold, valid, processed.segmentId));
candidates = appendCandidates(candidates, "ACCELERATION_CANDIDATE", ...
    hysteresisIntervals(processed.longitudinalFiltered >= ...
        config.accelerationStartThreshold, processed.longitudinalFiltered <= ...
        config.accelerationStopThreshold, valid, processed.segmentId));
leftStart = processed.lateralFiltered >= config.lateralStartThreshold & ...
    processed.yawRateFiltered >= config.yawRateStartThresholdDegPerSecond;
leftStop = processed.lateralFiltered <= config.lateralStopThreshold | ...
    processed.yawRateFiltered <= config.yawRateStopThresholdDegPerSecond;
candidates = appendCandidates(candidates, "TURN_LEFT_CANDIDATE", ...
    hysteresisIntervals(leftStart, leftStop, valid, processed.segmentId));
rightStart = processed.lateralFiltered <= -config.lateralStartThreshold & ...
    processed.yawRateFiltered <= -config.yawRateStartThresholdDegPerSecond;
rightStop = processed.lateralFiltered >= -config.lateralStopThreshold | ...
    processed.yawRateFiltered >= -config.yawRateStopThresholdDegPerSecond;
candidates = appendCandidates(candidates, "TURN_RIGHT_CANDIDATE", ...
    hysteresisIntervals(rightStart, rightStop, valid, processed.segmentId));
shockMask = abs(processed.verticalFiltered) >= config.verticalShockThreshold | ...
    abs(processed.verticalJerk) >= config.jerkCandidateThreshold;
candidates = appendCandidates(candidates, "VERTICAL_SHOCK_CANDIDATE", ...
    maskIntervals(shockMask & valid, processed.segmentId));

candidates = mergeCandidates(candidates, processed, config);
events = emptyEvents();
for index = 1:numel(candidates)
    candidate = candidates(index);
    duration = intervalDuration(candidate.first, candidate.last, processed, config);
    if candidate.type ~= "VERTICAL_SHOCK_CANDIDATE" && ...
            duration < config.minimumEventDurationSeconds
        continue;
    end
    events(end+1, 1) = makeEvent(candidate, processed, config); %#ok<AGROW>
end
if isempty(events), return; end
[~, order] = sort(double([events.startSequence]));
events = events(order);
for index = 1:numel(events), events(index).eventId = sprintf('EVT-%06d', index); end
end

function validateProcessed(processed)
required = {'sequenceNumber','hostTimestamp','timeSeconds','callbackAgeMs', ...
    'longitudinalFiltered','longitudinalJerk','lateralFiltered', ...
    'lateralJerk','verticalFiltered','verticalJerk','yawRateFiltered', ...
    'segmentId','dataValid','outlierReplaced'};
if ~isstruct(processed) || ~isscalar(processed) || ...
        ~all(isfield(processed, required))
    error('IMU:InvalidProcessedSession', 'Processed session lacks required fields.');
end
if ~isfield(processed, 'sampleRateHz') || ...
        ~(isnumeric(processed.sampleRateHz) && isscalar(processed.sampleRateHz) && ...
        isfinite(processed.sampleRateHz) && processed.sampleRateHz > 0)
    error('IMU:InvalidProcessedSession', 'Processed sampleRateHz is invalid.');
end
count = numel(processed.sequenceNumber);
for index = 1:numel(required)
    if numel(processed.(required{index})) ~= count
        error('IMU:InvalidProcessedSession', 'Processed field lengths differ.');
    end
end
end

function intervals = hysteresisIntervals(startMask, stopMask, valid, segmentId)
intervals = zeros(0, 3);
active = false; first = 0; activeSegment = 0;
for index = 1:numel(valid)
    if active && (~valid(index) || segmentId(index) ~= activeSegment)
        intervals(end+1, :) = [first, index - 1, activeSegment]; %#ok<AGROW>
        active = false;
    end
    if ~valid(index), continue; end
    if ~active && startMask(index)
        active = true; first = index; activeSegment = segmentId(index);
    elseif active && stopMask(index)
        intervals(end+1, :) = [first, max(first, index - 1), activeSegment]; %#ok<AGROW>
        active = false;
    end
end
if active, intervals(end+1, :) = [first, numel(valid), activeSegment]; end
end

function intervals = maskIntervals(mask, segmentId)
intervals = zeros(0, 3);
active = false;
for index = 1:numel(mask)
    if mask(index) && ~active
        first = index; activeSegment = segmentId(index); active = true;
    end
    ends = active && (~mask(index) || segmentId(index) ~= activeSegment);
    if ends
        intervals(end+1, :) = [first, index - 1, activeSegment]; %#ok<AGROW>
        active = false;
        if mask(index), first = index; activeSegment = segmentId(index); active = true; end
    end
end
if active, intervals(end+1, :) = [first, numel(mask), activeSegment]; end
end

function values = emptyCandidates()
values = struct('type', {}, 'first', {}, 'last', {}, 'segmentId', {});
end

function output = appendCandidates(output, type, intervals)
for index = 1:size(intervals, 1)
    output(end+1) = struct('type', type, 'first', intervals(index, 1), ...
        'last', intervals(index, 2), 'segmentId', intervals(index, 3)); %#ok<AGROW>
end
end

function merged = mergeCandidates(candidates, processed, config)
merged = emptyCandidates();
types = ["BRAKING_CANDIDATE","ACCELERATION_CANDIDATE", ...
    "TURN_LEFT_CANDIDATE","TURN_RIGHT_CANDIDATE","VERTICAL_SHOCK_CANDIDATE"];
samplePeriod = 1 / processed.sampleRateHz;
for type = types
    selected = candidates(string({candidates.type}) == type);
    if isempty(selected), continue; end
    [~, order] = sort([selected.first]); selected = selected(order);
    current = selected(1);
    for index = 2:numel(selected)
        next = selected(index);
        gap = processed.timeSeconds(next.first) - ...
            processed.timeSeconds(current.last) - samplePeriod;
        if next.segmentId == current.segmentId && gap <= config.maximumMergeGapSeconds
            current.last = next.last;
        else
            merged(end+1) = current; %#ok<AGROW>
            current = next;
        end
    end
    merged(end+1) = current; %#ok<AGROW>
end
end

function duration = intervalDuration(first, last, processed, ~)
duration = (last - first + 1) / processed.sampleRateHz;
end

function event = makeEvent(candidate, processed, config)
indices = candidate.first:candidate.last;
switch candidate.type
    case {"BRAKING_CANDIDATE", "ACCELERATION_CANDIDATE"}
        acceleration = processed.longitudinalFiltered(indices);
        jerk = processed.longitudinalJerk(indices);
        thresholds = struct('start', conditional(candidate.type == ...
            "BRAKING_CANDIDATE", config.brakingStartThreshold, ...
            config.accelerationStartThreshold), 'stop', conditional( ...
            candidate.type == "BRAKING_CANDIDATE", config.brakingStopThreshold, ...
            config.accelerationStopThreshold));
    case {"TURN_LEFT_CANDIDATE", "TURN_RIGHT_CANDIDATE"}
        acceleration = processed.lateralFiltered(indices);
        jerk = processed.lateralJerk(indices);
        thresholds = struct('lateralStart', config.lateralStartThreshold, ...
            'lateralStop', config.lateralStopThreshold, ...
            'yawStartDegPerSecond', config.yawRateStartThresholdDegPerSecond, ...
            'yawStopDegPerSecond', config.yawRateStopThresholdDegPerSecond);
    otherwise
        acceleration = processed.verticalFiltered(indices);
        jerk = processed.verticalJerk(indices);
        thresholds = struct('verticalAcceleration', config.verticalShockThreshold, ...
            'jerk', config.jerkCandidateThreshold);
end
[~, accelerationPeakIndex] = max(abs(acceleration));
finiteJerk = jerk; finiteJerk(~isfinite(finiteJerk)) = 0;
[~, jerkPeakIndex] = max(abs(finiteJerk));
yaw = processed.yawRateFiltered(indices);
[~, yawPeakIndex] = max(abs(yaw));
missing = double(processed.sequenceNumber(candidate.last) - ...
    processed.sequenceNumber(candidate.first)) + 1 - numel(indices);
outlierCount = sum(processed.outlierReplaced(indices));
quality = dataQuality(indices, missing, outlierCount, processed);
[contextFirst, contextLast] = eventContext(candidate, processed, config);
event = struct('eventId', '', 'type', candidate.type, ...
    'startSequence', processed.sequenceNumber(candidate.first), ...
    'endSequence', processed.sequenceNumber(candidate.last), ...
    'startTimestamp', processed.hostTimestamp(candidate.first), ...
    'endTimestamp', processed.hostTimestamp(candidate.last), ...
    'startTimeSeconds', processed.timeSeconds(candidate.first), ...
    'endTimeSeconds', processed.timeSeconds(candidate.last), ...
    'durationSeconds', intervalDuration(candidate.first, candidate.last, processed, config), ...
    'peakAcceleration', acceleration(accelerationPeakIndex), ...
    'meanAcceleration', mean(acceleration), ...
    'peakAbsoluteAcceleration', max(abs(acceleration)), ...
    'peakJerk', finiteJerk(jerkPeakIndex), 'peakYawRate', yaw(yawPeakIndex), ...
    'integratedAcceleration', trapz(processed.timeSeconds(indices), acceleration), ...
    'sampleCount', numel(indices), 'segmentId', candidate.segmentId, ...
    'contextStartSequence', processed.sequenceNumber(contextFirst), ...
    'contextEndSequence', processed.sequenceNumber(contextLast), ...
    'contextStartIndex', contextFirst, 'contextEndIndex', contextLast, ...
    'missingSamplesInside', max(0, missing), ...
    'outlierSamplesInside', outlierCount, 'dataQuality', quality, ...
    'thresholds', thresholds);
end

function [first, last] = eventContext(candidate, processed, config)
preSamples = floor(config.preEventSeconds * processed.sampleRateHz);
postSamples = floor(config.postEventSeconds * processed.sampleRateHz);
segmentIndices = find(processed.segmentId == candidate.segmentId);
first = max(segmentIndices(1), candidate.first - preSamples);
last = min(segmentIndices(end), candidate.last + postSamples);
end

function value = conditional(condition, whenTrue, whenFalse)
if condition, value = whenTrue; else, value = whenFalse; end
end

function quality = dataQuality(indices, missing, outliers, processed)
projectConfig = getImuConfig();
count = numel(indices);
ageBad = sum(~isfinite(processed.callbackAgeMs(indices)) | ...
    processed.callbackAgeMs(indices) > projectConfig.maximumCallbackSampleAgeMs);
completenessPenalty = missing / max(1, count + missing);
quality = 1 - 0.45 * outliers / max(1, count) - ...
    0.30 * ageBad / max(1, count) - 0.25 * completenessPenalty;
quality = max(0, min(1, quality));
end

function events = emptyEvents()
template = struct('eventId', '', 'type', "", 'startSequence', uint64(0), ...
    'endSequence', uint64(0), 'startTimestamp', NaT, 'endTimestamp', NaT, ...
    'startTimeSeconds', 0, 'endTimeSeconds', 0, 'durationSeconds', 0, ...
    'peakAcceleration', 0, 'meanAcceleration', 0, ...
    'peakAbsoluteAcceleration', 0, 'peakJerk', 0, 'peakYawRate', 0, ...
    'integratedAcceleration', 0, 'sampleCount', 0, 'segmentId', 0, ...
    'contextStartSequence', uint64(0), 'contextEndSequence', uint64(0), ...
    'contextStartIndex', 0, 'contextEndIndex', 0, ...
    'missingSamplesInside', 0, 'outlierSamplesInside', 0, ...
    'dataQuality', 0, 'thresholds', struct());
events = repmat(template, 0, 1);
end
