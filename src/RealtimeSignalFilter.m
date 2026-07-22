classdef RealtimeSignalFilter < handle
%REALTIMESIGNALFILTER Bounded causal despiking, EMA and derivative.
    properties (SetAccess = private)
        SampleRateHz
        CutoffHz
        Alpha
    end
    properties (Access = private)
        WindowSize
        MadThreshold
        History
        PreviousFiltered = NaN
    end
    methods
        function obj = RealtimeSignalFilter(sampleRateHz, cutoffHz, options)
            if nargin < 3, options = struct(); end
            defaults = getRealtimeDrivingConfig();
            window = defaults.medianWindowSamples;
            threshold = defaults.outlierMadThreshold;
            if isfield(options, 'medianWindowSamples'), window = options.medianWindowSamples; end
            if isfield(options, 'outlierMadThreshold'), threshold = options.outlierMadThreshold; end
            unknown = setdiff(fieldnames(options), {'medianWindowSamples','outlierMadThreshold'});
            if ~isempty(unknown), error('IMU:InvalidRealtimeFilterOptions', 'Unknown option: %s.', unknown{1}); end
            validateattributes(sampleRateHz, {'numeric'}, {'scalar','positive','finite'});
            validateattributes(cutoffHz, {'numeric'}, {'scalar','positive','finite'});
            validateattributes(window, {'numeric'}, {'scalar','integer','positive'});
            validateattributes(threshold, {'numeric'}, {'scalar','positive','finite'});
            if cutoffHz >= sampleRateHz / 2 || mod(window, 2) ~= 1
                error('IMU:InvalidRealtimeFilterOptions', 'Invalid cutoff or median window.');
            end
            obj.SampleRateHz = double(sampleRateHz); obj.CutoffHz = double(cutoffHz);
            obj.Alpha = 1 - exp(-2*pi*cutoffHz/sampleRateHz);
            obj.WindowSize = double(window); obj.MadThreshold = double(threshold);
            obj.reset();
        end
        function reset(obj)
            obj.History = zeros(0, 1); obj.PreviousFiltered = NaN;
        end
        function output = update(obj, value)
            valid = isnumeric(value) && isscalar(value) && isfinite(value);
            raw = NaN;
            if isnumeric(value) && isscalar(value), raw = double(value); end
            output = struct('raw', raw, 'despiked', NaN, 'filtered', NaN, ...
                'derivative', NaN, 'outlierReplaced', false, 'valid', valid);
            if ~valid, return; end
            window = [obj.History; raw];
            center = median(window); localMad = median(abs(window-center));
            difference = abs(raw-center); tolerance = eps(max(1,abs(center)));
            if localMad > tolerance
                outlier = difference > obj.MadThreshold * 1.4826 * localMad;
            else
                outlier = numel(obj.History) >= 2 && difference > tolerance && ...
                    all(abs(obj.History(max(1,end-1):end)-center) <= tolerance);
            end
            despiked = raw; if outlier, despiked = center; end
            if isnan(obj.PreviousFiltered)
                filtered = despiked; derivative = NaN;
            else
                filtered = obj.Alpha*despiked + (1-obj.Alpha)*obj.PreviousFiltered;
                derivative = (filtered-obj.PreviousFiltered)*obj.SampleRateHz;
            end
            obj.PreviousFiltered = filtered;
            obj.History(end+1,1) = raw;
            if numel(obj.History) > obj.WindowSize-1
                obj.History = obj.History(end-obj.WindowSize+2:end);
            end
            output.despiked = despiked; output.filtered = filtered;
            output.derivative = derivative; output.outlierReplaced = outlier;
        end
    end
end
