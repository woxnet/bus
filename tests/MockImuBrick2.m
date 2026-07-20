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
        SampleSequence = uint64(0)
        LatestData = []
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
    end
    properties (Access = private)
        Index = 1
        StreamTimer
        LastCallbackTime = 0
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
            obj.SampleSequence = obj.SampleSequence + uint64(1);
            data.sequenceNumber = obj.SampleSequence;
            if ~isfield(data, 'hostTimestamp'), data.hostTimestamp = data.timestamp; end
            data.timestamp = data.hostTimestamp;
        end

        function start(obj, periodMs)
            obj.IsStreaming = true;
            obj.StreamingPeriodMs = double(periodMs);
            obj.StreamTimer = tic;
            obj.LastCallbackTime = 0;
        end
        function stop(obj), obj.IsStreaming = false; end
        function data = latest(obj)
            if ~obj.IsStreaming, error('MockImu:NotStreaming', 'Stream is stopped.'); end
            elapsed = toc(obj.StreamTimer);
            due = obj.StreamingPeriodMs / 1000 * obj.CallbackPeriodScale;
            if isempty(obj.LatestData) || (~obj.FreezeCallback && ...
                    elapsed - obj.LastCallbackTime >= due)
                obj.LatestData = obj.readOnce();
                obj.LatestData.hostTimestamp = datetime('now');
                obj.LatestData.timestamp = obj.LatestData.hostTimestamp;
                obj.LastCallbackTime = elapsed;
            end
            data = obj.LatestData;
        end
        function mode = getSensorFusionMode(obj), mode = obj.SensorFusionMode; end
        function setSensorFusionMode(obj, mode)
            if ~obj.IgnoreSensorFusionSet, obj.SensorFusionMode = double(mode); end
        end
        function identity = getIdentity(obj), identity = obj.Identity; end
        function disconnect(obj)
            obj.IsStreaming = false;
            obj.DisconnectCount = obj.DisconnectCount + 1;
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
                'calibration', struct());
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
