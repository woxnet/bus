% Run every physical IMU acceptance and emit one cross-checked summary.
acceptanceRoot=fileparts(fileparts(mfilename('fullpath')));
run(fullfile(acceptanceRoot,'startup.m'));
calibrationReport=struct(); runtimeReport=struct(); realtimeReport=struct();
try
    run(fullfile(acceptanceRoot,'examples','run_installation_calibration_hardware_acceptance.m'));
    calibrationReport=report; clear controllerCleanup imuCleanup imu;
    run(fullfile(acceptanceRoot,'examples','run_imu_hardware_acceptance.m'));
    runtimeReport=report; clear cleanup imu;
    run(fullfile(acceptanceRoot,'examples','run_realtime_hardware_acceptance.m'));
    realtimeReport=report; clear monitorCleanup imuCleanup monitor imu;
catch exception
    acceptanceException=exception;
end
combined=summarizeBusImuAcceptance(calibrationReport,runtimeReport,realtimeReport);
combined.generatedAt=datetime('now','TimeZone','UTC');
combined.calibrationReport=calibrationReport;
combined.runtimeReport=runtimeReport;
combined.realtimeReport=realtimeReport;
combined.errors=strings(0,1);
if exist('acceptanceException','var')
    combined.errors(end+1,1)=string(acceptanceException.identifier)+": "+ ...
        string(acceptanceException.message);
    combined.success=false;
end
artifactDirectory=resolveProjectPath('artifacts');
if ~isfolder(artifactDirectory), mkdir(artifactDirectory); end
stamp=char(datetime('now','Format','yyyyMMdd_HHmmss'));
matFile=fullfile(artifactDirectory,['full_imu_acceptance_',stamp,'.mat']);
jsonFile=fullfile(artifactDirectory,['full_imu_acceptance_',stamp,'.json']);
save(matFile,'combined','-v7');
fileId=fopen(jsonFile,'w'); assert(fileId>=0); cleanupFile=onCleanup(@()fclose(fileId));
fprintf(fileId,'%s',jsonencode(combined,'PrettyPrint',true)); clear cleanupFile;
decoded=jsondecode(fileread(jsonFile));
required={'success','commitMatch','uidMatch','busIdMatch', ...
    'sensorFusionModeMatch','calibrationFileExists','calibrationVerified', ...
    'runtimeSuccess','realtimeSuccess','runtimeTailComplete','runtimeBufferEmpty'};
assert(all(isfield(decoded,required)) && logical(decoded.success)==combined.success, ...
    'IMU:AcceptanceArtifactInvalid','Combined acceptance JSON failed validation.');
combined.matFile=string(matFile); combined.jsonFile=string(jsonFile); disp(combined);
assert(combined.success,"IMU:FullHardwareAcceptanceFailed", ...
    "One or more physical IMU acceptance phases failed.");
clear acceptanceRoot;
