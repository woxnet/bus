function shutdownImuRuntime(imu)
%SHUTDOWNIMURUNTIME Stop, clear, disconnect, and delete an IMU safely.

requiredMethods = {'stop','clearCallbackBuffer','disconnect','delete'};
if nargin < 1 || isempty(imu) || ~isobject(imu) || ...
        ~all(cellfun(@(name)ismethod(imu, name), requiredMethods))
    error('IMU:InvalidRuntimeObject', ...
        'imu must support stop, clearCallbackBuffer, disconnect, and delete.');
end
invoke(@()imu.stop(), 'stop');
invoke(@()imu.clearCallbackBuffer(), 'clear callback buffer');
invoke(@()imu.disconnect(), 'disconnect');
invoke(@()delete(imu), 'delete');
fprintf(['IMU runtime shut down. Clear the MATLAB variable, then use ', ...
    '''clear java'' or restart MATLAB before replacing Java JAR files.\n']);
end

function invoke(operation, label)
try
    operation();
catch exception
    warning('IMU:RuntimeShutdownStepFailed', ...
        'Could not %s: %s', label, exception.message);
end
end
