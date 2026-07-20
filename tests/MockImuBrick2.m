classdef MockImuBrick2 < handle
%MOCKIMUBRICK2 Deterministic, hardware-free test double for ImuBrick2.
    properties (SetAccess = private)
        ReadCount = 0
        IsStreaming = false
    end
    properties
        Samples
        RepeatLast = true
        FailureReads = []
        OnRead = []
    end
    properties (Access = private)
        Index = 1
    end

    methods
        function obj = MockImuBrick2(samples)
            if nargin < 1 || isempty(samples)
                samples = MockImuBrick2.makeSample([0 0 -9.81], [0 0 0], [0 0 0]);
            end
            obj.Samples = samples(:);
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
        end

        function start(obj, ~), obj.IsStreaming = true; end
        function stop(obj), obj.IsStreaming = false; end
        function disconnect(obj), obj.IsStreaming = false; end
    end

    methods (Static)
        function samples = createStationarySequence(count, rotation, linearBias, gyroBias)
            if nargin < 2 || isempty(rotation), rotation = eye(3); end
            if nargin < 3, linearBias = [0;0;0]; end
            if nargin < 4, gyroBias = [0;0;0]; end
            gravity = rotation' * [0;0;-9.81];
            sample = MockImuBrick2.makeSample(gravity, linearBias, gyroBias);
            samples = repmat(sample, count, 1);
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
        end

        function samples = createTurningSequence(count, rotation, magnitude)
            if nargin < 2 || isempty(rotation), rotation = eye(3); end
            if nargin < 3 || isempty(magnitude), magnitude = 1; end
            gravity = rotation' * [0;0;-9.81];
            acceleration = rotation' * [magnitude;0;0];
            sample = MockImuBrick2.makeSample(gravity, acceleration, [0;0;20]);
            samples = repmat(sample, count, 1);
        end

        function sample = makeSample(gravity, linearAcceleration, angularVelocity)
            sample = struct('timestamp', datetime('now'), ...
                'acceleration', gravity(:).' + linearAcceleration(:).', ...
                'linearAcceleration', linearAcceleration(:).', ...
                'gravity', gravity(:).', ...
                'angularVelocity', angularVelocity(:).', ...
                'magneticField', [0 0 0], 'euler', [0 0 0], ...
                'quaternion', [1 0 0 0], 'temperature', 20, ...
                'calibration', struct());
        end
    end
end
