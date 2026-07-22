classdef RealtimeEventState < handle
%REALTIMEEVENTSTATE Stateful two-state online event accumulator.
    properties (SetAccess = private)
        Type
        IsActive = false
    end
    properties (Access = private)
        Config
        StartSample
        LastSample
        AccelerationSum = 0
        IntegratedAcceleration = 0
        PeakAcceleration = NaN
        PeakAbsoluteAcceleration = 0
        PeakJerk = NaN
        PeakYawRate = NaN
        SampleCount = 0
        OutlierCount = 0
        MaximumCallbackAgeMs = 0
    end
    methods
        function obj = RealtimeEventState(type, config)
            obj.Type = string(type);
            supported = ["BRAKING_CANDIDATE","ACCELERATION_CANDIDATE", ...
                "TURN_LEFT_CANDIDATE","TURN_RIGHT_CANDIDATE", ...
                "VERTICAL_SHOCK_CANDIDATE"];
            if ~isscalar(obj.Type) || ~any(obj.Type == supported)
                error('IMU:InvalidRealtimeEventType', 'Unsupported event type.');
            end
            obj.Config = validateRealtimeDrivingConfig(config);
            obj.reset();
        end
        function [stateChanged, completedEvent] = update(obj, sample, startCondition, stopCondition)
            stateChanged = false; completedEvent = [];
            if ~obj.IsActive
                if startCondition
                    obj.begin(sample); stateChanged = true;
                end
                return;
            end
            if stopCondition
                completedEvent = obj.finish("threshold", 0);
                stateChanged = true;
                return;
            end
            obj.accumulate(sample);
        end
        function event = terminate(obj, reason, missingSamples)
            if nargin < 3, missingSamples = 0; end
            if ~obj.IsActive, event = []; return; end
            event = obj.finish(string(reason), missingSamples);
        end
        function preview = getPreview(obj)
            if ~obj.IsActive, preview = []; return; end
            preview = struct('type', obj.Type, ...
                'startSequence', obj.StartSample.sequenceNumber, ...
                'startTimestamp', obj.StartSample.hostTimestamp, ...
                'source', "realtime", 'status', "active");
        end
        function reset(obj)
            obj.IsActive = false; obj.StartSample = []; obj.LastSample = [];
            obj.AccelerationSum = 0; obj.IntegratedAcceleration = 0;
            obj.PeakAcceleration = NaN; obj.PeakAbsoluteAcceleration = 0;
            obj.PeakJerk = NaN; obj.PeakYawRate = NaN; obj.SampleCount = 0;
            obj.OutlierCount = 0; obj.MaximumCallbackAgeMs = 0;
        end
    end
    methods (Access = private)
        function begin(obj, sample)
            obj.reset(); obj.IsActive = true; obj.StartSample = sample;
            obj.accumulate(sample);
        end
        function accumulate(obj, sample)
            [acceleration, jerk] = obj.eventSignals(sample);
            obj.SampleCount = obj.SampleCount + 1;
            obj.AccelerationSum = obj.AccelerationSum + acceleration;
            obj.IntegratedAcceleration = obj.IntegratedAcceleration + ...
                acceleration / obj.Config.sampleRateHz;
            if isnan(obj.PeakAcceleration) || abs(acceleration) > abs(obj.PeakAcceleration)
                obj.PeakAcceleration = acceleration;
            end
            obj.PeakAbsoluteAcceleration = max(obj.PeakAbsoluteAcceleration, abs(acceleration));
            if isfinite(jerk) && (isnan(obj.PeakJerk) || abs(jerk) > abs(obj.PeakJerk))
                obj.PeakJerk = jerk;
            end
            yaw = sample.yawRateFiltered;
            if isfinite(yaw) && (isnan(obj.PeakYawRate) || abs(yaw) > abs(obj.PeakYawRate))
                obj.PeakYawRate = yaw;
            end
            obj.OutlierCount = obj.OutlierCount + double(sample.outlierReplaced);
            obj.MaximumCallbackAgeMs = max(obj.MaximumCallbackAgeMs, sample.callbackAgeMs);
            obj.LastSample = sample;
        end
        function event = finish(obj, reason, missingSamples)
            duration = obj.SampleCount / obj.Config.sampleRateHz;
            isShock = obj.Type == "VERTICAL_SHOCK_CANDIDATE";
            if ~isShock && duration < obj.Config.minimumEventDurationSeconds
                event = []; obj.reset(); return;
            end
            quality = 1 - 0.45*obj.OutlierCount/max(1,obj.SampleCount) - ...
                0.30*double(obj.MaximumCallbackAgeMs > obj.Config.maximumSampleAgeMs) - ...
                0.25*missingSamples/max(1,obj.SampleCount+missingSamples);
            event = struct('eventId', '', 'type', obj.Type, ...
                'startSequence', obj.StartSample.sequenceNumber, ...
                'endSequence', obj.LastSample.sequenceNumber, ...
                'startTimestamp', obj.StartSample.hostTimestamp, ...
                'endTimestamp', obj.LastSample.hostTimestamp, ...
                'startElapsedSeconds', obj.StartSample.elapsedSeconds, ...
                'endElapsedSeconds', obj.LastSample.elapsedSeconds, ...
                'durationSeconds', duration, 'peakAcceleration', obj.PeakAcceleration, ...
                'meanAcceleration', obj.AccelerationSum/max(1,obj.SampleCount), ...
                'peakAbsoluteAcceleration', obj.PeakAbsoluteAcceleration, ...
                'peakJerk', obj.PeakJerk, 'peakYawRate', obj.PeakYawRate, ...
                'integratedAcceleration', obj.IntegratedAcceleration, ...
                'sampleCount', obj.SampleCount, ...
                'missingSamplesInside', double(missingSamples), ...
                'outlierSamplesInside', obj.OutlierCount, ...
                'maximumCallbackAgeMs', obj.MaximumCallbackAgeMs, ...
                'dataQuality', max(0,min(1,quality)), ...
                'thresholds', obj.thresholds(), 'status', "completed", ...
                'source', "realtime", 'terminationReason', string(reason));
            obj.reset();
        end
        function [acceleration, jerk] = eventSignals(obj, sample)
            if any(obj.Type == ["BRAKING_CANDIDATE","ACCELERATION_CANDIDATE"])
                acceleration = sample.longitudinalFiltered;
                jerk = sample.longitudinalJerk;
            elseif any(obj.Type == ["TURN_LEFT_CANDIDATE","TURN_RIGHT_CANDIDATE"])
                acceleration = sample.lateralFiltered; jerk = sample.lateralJerk;
            else
                acceleration = sample.verticalFiltered; jerk = sample.verticalJerk;
            end
        end
        function value = thresholds(obj)
            switch obj.Type
                case "BRAKING_CANDIDATE"
                    value = struct('start',obj.Config.brakingStartThreshold, ...
                        'stop',obj.Config.brakingStopThreshold);
                case "ACCELERATION_CANDIDATE"
                    value = struct('start',obj.Config.accelerationStartThreshold, ...
                        'stop',obj.Config.accelerationStopThreshold);
                case {"TURN_LEFT_CANDIDATE","TURN_RIGHT_CANDIDATE"}
                    value = struct('lateralStart',obj.Config.lateralStartThreshold, ...
                        'lateralStop',obj.Config.lateralStopThreshold, ...
                        'yawStartDegPerSecond',obj.Config.yawRateStartThresholdDegPerSecond, ...
                        'yawStopDegPerSecond',obj.Config.yawRateStopThresholdDegPerSecond);
                otherwise
                    value = struct('verticalAcceleration',obj.Config.verticalShockThreshold, ...
                        'jerk',obj.Config.jerkCandidateThreshold);
            end
        end
    end
end
