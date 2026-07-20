function report = diagnoseImuBrick2UsingExistingConnection(imu)
%DIAGNOSEIMUBRICK2USINGEXISTINGCONNECTION Run preflight on an owned device.
%   The exact previous callback stream state and period are restored.
report = diagnoseImuBrick2(imu);
end
