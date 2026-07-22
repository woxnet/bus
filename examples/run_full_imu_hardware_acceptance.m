% Run every physical IMU acceptance and emit one machine-readable summary.
acceptanceRoot=fileparts(fileparts(mfilename('fullpath')));
run(fullfile(acceptanceRoot,'startup.m'));
combined=struct('success',false,'generatedAt',datetime('now','TimeZone','UTC'), ...
    'installationCalibration',[],'imuRuntime',[],'realtimeMonitor',[], ...
    'errors',strings(0,1));
try
    run(fullfile(acceptanceRoot,'examples','run_installation_calibration_hardware_acceptance.m'));
    combined.installationCalibration=report;
    clear controllerCleanup imuCleanup imu;
    run(fullfile(acceptanceRoot,'examples','run_imu_hardware_acceptance.m'));
    combined.imuRuntime=report;
    clear cleanup imu;
    run(fullfile(acceptanceRoot,'examples','run_realtime_hardware_acceptance.m'));
    combined.realtimeMonitor=report;
    clear monitorCleanup imuCleanup monitor imu;
    combined.success=combined.installationCalibration.success && ...
        combined.imuRuntime.success && combined.realtimeMonitor.success;
catch exception
    combined.errors(end+1,1)=string(exception.identifier)+": "+string(exception.message);
end
artifactDirectory=resolveProjectPath('artifacts');
if ~isfolder(artifactDirectory), mkdir(artifactDirectory); end
stamp=char(datetime('now','Format','yyyyMMdd_HHmmss'));
matFile=fullfile(artifactDirectory,['full_imu_acceptance_',stamp,'.mat']);
jsonFile=fullfile(artifactDirectory,['full_imu_acceptance_',stamp,'.json']);
save(matFile,'combined','-v7');
fileId=fopen(jsonFile,'w'); assert(fileId>=0); cleanupFile=onCleanup(@()fclose(fileId));
fprintf(fileId,'%s',jsonencode(combined,'PrettyPrint',true)); clear cleanupFile;
combined.matFile=string(matFile); combined.jsonFile=string(jsonFile); disp(combined);
assert(combined.success,"IMU:FullHardwareAcceptanceFailed", ...
    "One or more physical IMU acceptance phases failed.");
clear acceptanceRoot;
