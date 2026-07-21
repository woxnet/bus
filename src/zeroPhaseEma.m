function filtered = zeroPhaseEma(values, sampleRateHz, cutoffHz)
%ZEROPHASEEMA Apply a forward/backward EMA without toolbox dependencies.

validateattributes(values, {'numeric'}, {'vector','real','finite'});
validateattributes(sampleRateHz, {'numeric'}, {'scalar','real','finite','positive'});
validateattributes(cutoffHz, {'numeric'}, {'scalar','real','finite','positive'});
if cutoffHz >= sampleRateHz / 2
    error('IMU:InvalidFilterCutoff', 'cutoffHz must be below Nyquist frequency.');
end
wasRow = isrow(values);
values = double(values(:));
if isempty(values), filtered = values; return; end
alpha = 1 - exp(-2 * pi * cutoffHz / sampleRateHz);
forward = emaPass(values, alpha);
filtered = flipud(emaPass(flipud(forward), alpha));
if wasRow, filtered = filtered.'; end
end

function output = emaPass(input, alpha)
output = zeros(size(input));
output(1) = input(1);
for index = 2:numel(input)
    output(index) = alpha * input(index) + (1 - alpha) * output(index - 1);
end
end
