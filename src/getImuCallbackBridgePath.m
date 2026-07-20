function bridgePath = getImuCallbackBridgePath()
%GETIMUCALLBACKBRIDGEPATH Prefer the shipped bridge JAR at runtime.

root = fileparts(fileparts(mfilename('fullpath')));
prebuiltJar = fullfile(root, 'lib-generated', 'imu-callback-bridge.jar');
if isfile(prebuiltJar)
    bridgePath = prebuiltJar;
    return;
end

% Developer fallback for source checkouts where the generated JAR is absent.
bridgePath = buildImuCallbackBridge();
end
