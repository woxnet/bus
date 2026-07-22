function result = ensureImuInstallationCalibration(imu, busId, options)
%ENSUREIMUINSTALLATIONCALIBRATION Inspect calibration without starting it.
if nargin < 3 || isempty(options), options = getImuInstallationCalibrationWorkflowConfig(); end
if nargin < 2 || isempty(busId), busId = options.busId; end
options.busId = string(busId);
options = validateImuInstallationCalibrationWorkflowConfig(options);
uid = "";
try
    identity = imu.getIdentity();
    uid = string(identity.uid);
catch exception
    result = emptyResult();
    result.errors(end+1,1) = string(exception.message);
    return;
end
filename = fullfile(char(resolveProjectPath(options.calibrationDirectory)), ...
    char(string(busId) + "_imu_mount.mat"));
result = emptyResult();
result.calibrationFile = string(filename);
try
    result.calibration = loadImuCalibration(filename, busId, uid);
    metadata=result.calibration.metadata;
    verified=isfield(metadata,'workflowVersion') && ...
        strlength(string(metadata.workflowVersion))>0 && ...
        isfield(metadata,'verificationPerformed') && ...
        islogical(metadata.verificationPerformed) && isscalar(metadata.verificationPerformed) && ...
        metadata.verificationPerformed && ...
        isfield(metadata,'verificationPassed') && ...
        islogical(metadata.verificationPassed) && isscalar(metadata.verificationPassed) && ...
        metadata.verificationPassed;
    if ~verified && ~options.AllowUnverifiedLegacyCalibration
        error('IMU:UnverifiedInstallationCalibration', ...
            'Installation calibration lacks verified workflow provenance.');
    end
    if ~verified
        result.warnings(end+1,1)= ...
            "Unverified legacy calibration accepted by explicit migration option.";
    end
    result.success = true;
    result.calibrationRequired = false;
    if verified
        result.message = "Existing verified installation calibration is valid.";
    else
        result.message = "Legacy installation calibration accepted for migration.";
    end
catch exception
    result.errors(end+1,1) = string(exception.message);
    result.message = "Installation calibration is required. Run examples/run_interactive_imu_installation_calibration.m.";
end
end

function result = emptyResult()
result = struct('success',false,'calibrationRequired',true,'calibration',[], ...
    'calibrationFile',"",'message',"Installation calibration is required.", ...
    'errors',strings(0,1),'warnings',strings(0,1));
end
