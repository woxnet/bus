classdef MockImuBrick2 < handle
%MOCKIMUBRICK2 Deterministic, hardware-free test double for ImuBrick2.
    properties (SetAccess = private)
        ReadCount = 0
        IsStreaming = false
        DisconnectCount = 0
        UID
        Host = "localhost"
        Port = 4223
        StreamingPeriodMs = NaN
        SynchronousSequence = uint64(0)
        LatestData = []
        CallbackReceivedCount = uint64(0)
        CallbackDroppedCount = uint64(0)
        CallbackOverflowDroppedCount = uint64(0)
        CallbackCoalescedCount = uint64(0)
        CallbackStaleSessionDropCount = uint64(0)
        CallbackBufferedCount = uint64(0)
        LastCallbackSequence = uint64(0)
        CallbackSessionId = uint64(0)
        DrainCallCount = 0
    end
    properties
        Samples
        RepeatLast = true
        FailureReads = []
        OnRead = []
        SensorFusionMode = 2
        IgnoreSensorFusionSet = false
        Identity
        FreezeCallback = false
        CallbackPeriodScale = 1
        CallbackSequenceStep = 1
        DuplicateCallbackAt = []
        CallbackTimestampOffsetSeconds = 0
        ReportedCallbackCapacity = 256
        InjectedDroppedSamples = 0
        InjectedCoalescedSamples = 0
        InjectedStaleSessionDrops = 0
    end
    properties (Access = private)
        Index = 1
        StreamTimer
        LastCallbackTime = 0
        CallbackQueue = cell(0, 1)
        CallbackGeneratedCount = 0
        CallbackBufferCapacity = 256
    end

    methods
        function obj = MockImuBrick2(samples)
            if nargin < 1 || isempty(samples)
                samples = MockImuBrick2.makeSample([0 0 -9.81], [0 0 0], [0 0 0]);
            end
            obj.Samples = samples(:);
            config = getImuConfig();
            obj.UID = config.uid;
            obj.Identity = struct('uid', config.uid, 'connectedUid', "0", ...
                'position', "a", 'hardwareVersion', [1 0 0], ...
                'firmwareVersion', [2 0 15], 'deviceIdentifier', 18);
        end

        function data = readOnce(obj)
            obj.ReadCount = obj.ReadCount + 1;
            if ~isempty(obj.OnRead), obj.OnRead(obj.ReadCount); end
            if any(obj.FailureReads == obj.ReadCount)
                error('MockImu:ReadFailure', 'Synthetic read failure.');
            end
            if obj.Index > numel(obj.Samples)
                if ~obj.RepeatLast
                    error('MockImu:EndOfData', 'No more synthetic samples.');
                end
                data = obj.Samples(end);
            else
                data = obj.Samples(obj.Index);
                obj.Index = obj.Index + 1;
            end
            obj.SynchronousSequence = obj.SynchronousSequence + uint64(1);
            data.sequenceNumber = obj.SynchronousSequence;
            if ~isfield(data, 'hostTimestamp'), data.hostTimestamp = data.timestamp; end
            data.timestamp = data.hostTimestamp;
        end

        function start(obj, periodMs)
            obj.clearCallbackBuffer();
            obj.IsStreaming = true;
            obj.StreamingPeriodMs = double(periodMs);
            obj.StreamTimer = tic;
            obj.LastCallbackTime = 0;
            obj.CallbackGeneratedCount = 0;
        end
        function stop(obj)
            obj.IsStreaming = false;
            obj.clearCallbackBuffer();
        end
        function data = latest(obj)
            if ~obj.IsStreaming, error('MockImu:NotStreaming', 'Stream is stopped.'); end
            obj.updateCallbacks();
            if isempty(obj.CallbackQueue)
                error('IMU:NoNewCallbackSample', 'No new callback sample is available.');
            end
            obj.LatestData = obj.CallbackQueue{end};
            stale = numel(obj.CallbackQueue) - 1;
            obj.CallbackCoalescedCount = obj.CallbackCoalescedCount + uint64(stale);
            obj.CallbackQueue = cell(0, 1);
            obj.CallbackBufferedCount = uint64(0);
            data = obj.LatestData;
        end
        function data = nextCallbackSample(obj)
            if ~obj.IsStreaming, error('MockImu:NotStreaming', 'Stream is stopped.'); end
            obj.updateCallbacks();
            data = [];
            if ~isempty(obj.CallbackQueue)
                data = obj.CallbackQueue{1};
                obj.CallbackQueue(1) = [];
                obj.CallbackQueue = obj.CallbackQueue(:);
                obj.CallbackBufferedCount = uint64(numel(obj.CallbackQueue));
                obj.LatestData = data;
            end
        end
        function metadata = nextCallbackMetadata(obj)
            sample = obj.nextCallbackSample();
            if isempty(sample)
                metadata = [];
            else
                metadata = struct('sequenceNumber', sample.sequenceNumber, ...
                    'sessionId', sample.sessionId, ...
                    'timestampEpochMillis', 1000 * posixtime(sample.hostTimestamp), ...
                    'timestampNanos', sample.callbackTimestampNanos, ...
                    'callbackAgeMs', sample.callbackAgeMs, ...
                    'callbackDroppedTotal', sample.callbackDroppedTotal);
            end
        end
        function samples = drainCallbackSamples(obj, maxCount)
            obj.DrainCallCount = obj.DrainCallCount + 1;
            if nargin < 2, maxCount = Inf; end
            samples = cell(0, 1);
            while numel(samples) < maxCount
                sample = obj.nextCallbackSample();
                if isempty(sample), break; end
                samples{end+1, 1} = sample; %#ok<AGROW>
            end
        end
        function injectCallbackSamples(obj, samples, sequences, callbackAgeMs)
            if ~obj.IsStreaming, error('MockImu:NotStreaming', 'Stream is stopped.'); end
            if nargin < 3 || isempty(sequences)
                sequences = double(obj.LastCallbackSequence) + (1:numel(samples));
            end
            if nargin < 4, callbackAgeMs = 0; end
            if isscalar(callbackAgeMs), callbackAgeMs = repmat(callbackAgeMs, numel(samples), 1); end
            for index = 1:numel(samples)
                sample = samples(index);
                sample.source = "callback";
                sample.sessionId = obj.CallbackSessionId;
                sample.sequenceNumber = uint64(sequences(index));
                if ~isfield(sample, 'hostTimestamp')
                    sample.hostTimestamp = datetime('now', 'TimeZone', 'UTC');
                end
                if isempty(sample.hostTimestamp.TimeZone), sample.hostTimestamp.TimeZone = 'UTC'; end
                sample.timestamp = sample.hostTimestamp;
                sample.callbackAgeMs = double(callbackAgeMs(index));
                sample.callbackDroppedTotal = obj.CallbackOverflowDroppedCount;
                sample.callbackOverflowDroppedTotal = obj.CallbackOverflowDroppedCount;
                sample.callbackCoalescedTotal = obj.CallbackCoalescedCount;
                sample.callbackStaleSessionDroppedTotal = obj.CallbackStaleSessionDropCount;
                if numel(obj.CallbackQueue) == obj.CallbackBufferCapacity
                    obj.CallbackQueue(1) = [];
                    obj.CallbackOverflowDroppedCount = obj.CallbackOverflowDroppedCount + uint64(1);
                    obj.CallbackDroppedCount = obj.CallbackOverflowDroppedCount;
                end
                obj.CallbackQueue{end+1,1} = sample;
                obj.LastCallbackSequence = uint64(sequences(index));
                obj.CallbackGeneratedCount = obj.CallbackGeneratedCount + 1;
                obj.CallbackReceivedCount = obj.CallbackReceivedCount + uint64(1);
            end
            obj.CallbackBufferedCount = uint64(numel(obj.CallbackQueue));
        end
        function clearCallbackBuffer(obj)
            obj.CallbackQueue = cell(0, 1);
            obj.CallbackSessionId = obj.CallbackSessionId + uint64(1);
            obj.CallbackGeneratedCount = 0;
            obj.CallbackReceivedCount = uint64(0);
            obj.CallbackOverflowDroppedCount = uint64(obj.InjectedDroppedSamples);
            obj.CallbackDroppedCount = obj.CallbackOverflowDroppedCount;
            obj.CallbackCoalescedCount = uint64(obj.InjectedCoalescedSamples);
            obj.CallbackStaleSessionDropCount = uint64( ...
                obj.InjectedStaleSessionDrops);
            obj.CallbackBufferedCount = uint64(0);
            obj.LastCallbackSequence = uint64(0);
            obj.LatestData = [];
        end
        function stats = getCallbackStats(obj)
            obj.updateCallbacks();
            stats = struct('received', obj.CallbackReceivedCount, ...
                'dropped', obj.CallbackDroppedCount, ...
                'overflowDropped', obj.CallbackOverflowDroppedCount, ...
                'coalesced', obj.CallbackCoalescedCount, ...
                'staleSessionDropped', obj.CallbackStaleSessionDropCount, ...
                'buffered', obj.CallbackBufferedCount, ...
                'capacity', uint64(obj.ReportedCallbackCapacity), ...
                'sessionId', obj.CallbackSessionId, ...
                'lastSequence', obj.LastCallbackSequence, ...
                'streamingPeriodMs', obj.StreamingPeriodMs);
        end
        function mode = getSensorFusionMode(obj), mode = obj.SensorFusionMode; end
        function setSensorFusionMode(obj, mode)
            if ~obj.IgnoreSensorFusionSet, obj.SensorFusionMode = double(mode); end
        end
        function identity = getIdentity(obj), identity = obj.Identity; end
        function disconnect(obj)
            obj.IsStreaming = false;
            obj.clearCallbackBuffer();
            obj.DisconnectCount = obj.DisconnectCount + 1;
        end
    end

    methods (Access = private)
        function updateCallbacks(obj)
            if ~obj.IsStreaming, return; end
            due = obj.StreamingPeriodMs / 1000 * obj.CallbackPeriodScale;
            target = floor(toc(obj.StreamTimer) / due);
            if obj.FreezeCallback, target = min(target, 1); end
            while obj.CallbackGeneratedCount < target
                sample = obj.readOnce();
                nextGenerated = obj.CallbackGeneratedCount + 1;
                if ~any(obj.DuplicateCallbackAt == nextGenerated)
                    obj.LastCallbackSequence = obj.LastCallbackSequence + ...
                        uint64(obj.CallbackSequenceStep);
                end
                sample.source = "callback";
                sample.sessionId = obj.CallbackSessionId;
                sample.sequenceNumber = obj.LastCallbackSequence;
                sample.hostTimestamp = datetime('now', 'TimeZone', 'UTC') - ...
                    seconds(obj.CallbackTimestampOffsetSeconds);
                sample.timestamp = sample.hostTimestamp;
                sample.callbackReceivedTimestamp = sample.hostTimestamp;
                sample.callbackAgeMs = 1000 * obj.CallbackTimestampOffsetSeconds;
                sample.callbackTimestampNanos = ...
                    (obj.CallbackGeneratedCount + 1) * due * 1e9 - ...
                    obj.CallbackTimestampOffsetSeconds * 1e9;
                sample.callbackDroppedTotal = obj.CallbackOverflowDroppedCount;
                sample.callbackOverflowDroppedTotal = obj.CallbackOverflowDroppedCount;
                sample.callbackCoalescedTotal = obj.CallbackCoalescedCount;
                sample.callbackStaleSessionDroppedTotal = ...
                    obj.CallbackStaleSessionDropCount;
                if numel(obj.CallbackQueue) == obj.CallbackBufferCapacity
                    obj.CallbackQueue(1) = [];
                    obj.CallbackOverflowDroppedCount = ...
                        obj.CallbackOverflowDroppedCount + uint64(1);
                    obj.CallbackDroppedCount = obj.CallbackOverflowDroppedCount;
                end
                obj.CallbackQueue{end+1, 1} = sample;
                obj.CallbackGeneratedCount = obj.CallbackGeneratedCount + 1;
                obj.CallbackReceivedCount = obj.CallbackReceivedCount + uint64(1);
                obj.CallbackBufferedCount = uint64(numel(obj.CallbackQueue));
            end
        end
    end

    methods (Static)
        function samples = createStationarySequence(count, rotation, linearBias, gyroBias)
            if nargin < 2 || isempty(rotation), rotation = eye(3); end
            if nargin < 3, linearBias = [0;0;0]; end
            if nargin < 4, gyroBias = [0;0;0]; end
            gravity = rotation' * [0;0;-9.81];
            sample = MockImuBrick2.makeSample(gravity, linearBias, gyroBias);
            samples = repmat(sample, count, 1);
            samples = MockImuBrick2.withAdvancingTimestamps(samples, 0.02);
        end

        function samples = createForwardAccelerationSequence(count, rotation, magnitude, linearBias, gyroBias)
            if nargin < 2 || isempty(rotation), rotation = eye(3); end
            if nargin < 3 || isempty(magnitude), magnitude = 1; end
            if nargin < 4, linearBias = [0;0;0]; end
            if nargin < 5, gyroBias = [0;0;0]; end
            gravity = rotation' * [0;0;-9.81];
            acceleration = rotation' * [magnitude;0;0] + linearBias(:);
            sample = MockImuBrick2.makeSample(gravity, acceleration, gyroBias);
            samples = repmat(sample, count, 1);
            samples = MockImuBrick2.withAdvancingTimestamps(samples, 0.02);
        end

        function samples = createTurningSequence(count, rotation, magnitude)
            if nargin < 2 || isempty(rotation), rotation = eye(3); end
            if nargin < 3 || isempty(magnitude), magnitude = 1; end
            gravity = rotation' * [0;0;-9.81];
            acceleration = rotation' * [magnitude;0;0];
            sample = MockImuBrick2.makeSample(gravity, acceleration, [0;0;20]);
            samples = repmat(sample, count, 1);
            samples = MockImuBrick2.withAdvancingTimestamps(samples, 0.02);
        end

        function sample = makeSample(gravity, linearAcceleration, angularVelocity)
            timestamp = datetime('now');
            sample = struct('timestamp', timestamp, 'hostTimestamp', timestamp, ...
                'sequenceNumber', uint64(0), ...
                'acceleration', gravity(:).' + linearAcceleration(:).', ...
                'linearAcceleration', linearAcceleration(:).', ...
                'gravity', gravity(:).', ...
                'angularVelocity', angularVelocity(:).', ...
                'magneticField', [0 0 0], 'euler', [0 0 0], ...
                'quaternion', [1 0 0 0], 'temperature', 20, ...
                'calibration', struct('magnetometer', 3, ...
                    'accelerometer', 3, 'gyroscope', 3, 'system', 3));
        end

        function samples = withAdvancingTimestamps(samples, stepSeconds)
            if nargin < 2, stepSeconds = 0.02; end
            firstTimestamp = datetime('now');
            for index = 1:numel(samples)
                samples(index).timestamp = firstTimestamp + seconds((index - 1) * stepSeconds);
                samples(index).hostTimestamp = samples(index).timestamp;
            end
        end
    end
end
