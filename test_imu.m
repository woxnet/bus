config = getImuConfig();

imu = ImuBrick2(config.uid, config.host, config.port);

cleanup = onCleanup(@() imu.disconnect());

% 20 мс — получение данных примерно каждые 0.02 с.
imu.start(config.callbackPeriodMs);

pause(0.2);

data = imu.latest();

fprintf('Acceleration: %.3f %.3f %.3f m/s^2\n', ...
    data.acceleration);

fprintf('Linear acceleration: %.3f %.3f %.3f m/s^2\n', ...
    data.linearAcceleration);

fprintf('Angular velocity: %.3f %.3f %.3f deg/s\n', ...
    data.angularVelocity);

fprintf('Quaternion [w x y z]: %.5f %.5f %.5f %.5f\n', ...
    data.quaternion);

fprintf('Calibration [mag acc gyro sys]: %d %d %d %d\n', ...
    data.calibration.magnetometer, ...
    data.calibration.accelerometer, ...
    data.calibration.gyroscope, ...
    data.calibration.system);
    
