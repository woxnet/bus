projectRoot=fileparts(fileparts(mfilename("fullpath")));
run(fullfile(projectRoot,"startup.m"));
assertImuRuntimeReady();
config=getImuConfig();
imu=ImuBrick2(config.uid,config.host,config.port);
imuCleanup=onCleanup(@()imu.disconnect());
report=struct('success',false,'commit',"unknown",'matlabVersion',string(version), ...
    'javaVersion',string(version('-java')),'uid',config.uid,'busId',config.busId, ...
    'firmwareVersion',[NaN NaN NaN],'sensorFusionMode',NaN, ...
    'calibrationFile',"",'backupFile',"",'quality',[], ...
    'verification',[],'rotationVehicleFromSensor',[],'bias',[], ...
    'errors',strings(0,1),'warnings',strings(0,1));
try
    [status,commit]=system('git rev-parse HEAD');
    if status==0, report.commit=strtrim(string(commit)); end
    preflight=diagnoseImuBrick2UsingExistingConnection(imu);
    assert(preflight.success,strjoin(preflight.errors," "));
    options=getImuInstallationCalibrationWorkflowConfig();
    controller=ImuInstallationCalibrationController(imu,config.busId, ...
        config.calibrationDirectory,options);
    controllerCleanup=onCleanup(@()delete(controller));
    result=controller.runBlocking();
    assert(result.success,strjoin(result.errors," "));
    saved=loadImuCalibration(result.finalFile,config.busId,config.uid);
    sample=imu.readOnce();
    applyMountCalibration(sample,saved);
    identity=imu.getIdentity();
    report.uid=string(identity.uid); report.firmwareVersion=identity.firmwareVersion;
    report.sensorFusionMode=imu.getSensorFusionMode();
    report.calibrationFile=result.finalFile; report.backupFile=result.backupFile;
    report.quality=saved.quality; report.verification=result.verification;
    report.rotationVehicleFromSensor=saved.rotationVehicleFromSensor;
    report.bias=saved.bias; report.warnings=result.warnings; report.success=true;
catch exception
    report.errors(end+1,1)=string(exception.message);
end
artifacts=fullfile(projectRoot,'artifacts'); if ~isfolder(artifacts), mkdir(artifacts); end
timestamp=datetime('now','TimeZone','UTC'); timestamp.Format='yyyyMMdd_HHmmss';
stem=fullfile(artifacts,['calibration_acceptance_' char(string(timestamp))]);
save([stem '.mat'],'report');
fileId=fopen([stem '.json'],'w'); cleanupFile=onCleanup(@()fclose(fileId));
fprintf(fileId,'%s',jsonencode(report,'PrettyPrint',true)); clear cleanupFile;
disp(report); assert(report.success,strjoin(report.errors," "));
clear projectRoot;
