function report = runInstallationCalibrationHardwareAcceptance(options)
%RUNINSTALLATIONCALIBRATIONHARDWAREACCEPTANCE Calibrate and verify one IMU.
if nargin<1 || isempty(options), options=struct(); end
observerWarnings=strings(0,1);
capture(notifyHardwareAcceptanceObserver(options,"stage_started","installation_calibration","RUNNING",0, ...
    "Installation calibration acceptance started.",struct()));
assertImuAcceptanceClassApi();
checkoutCommit = getImuAcceptanceCommit();
assertImuRuntimeReady();
config = getImuConfig();
report = struct('success',false,'commit',checkoutCommit, ...
    'matlabVersion',string(version),'javaVersion',string(version('-java')), ...
    'uid',config.uid,'busId',config.busId,'firmwareVersion',[NaN NaN NaN], ...
    'sensorFusionMode',NaN,'calibrationFile',"",'backupFile',"", ...
    'quality',[],'verification',[],'rotationVehicleFromSensor',[], ...
    'bias',[],'errors',strings(0,1),'warnings',strings(0,1));
imu = ImuBrick2(config.uid,config.host,config.port);
imuCleanup = onCleanup(@()imu.disconnect());
try
    preflight = diagnoseImuBrick2UsingExistingConnection(imu);
    assert(preflight.success,strjoin(preflight.errors," "));
    workflowOptions = getImuInstallationCalibrationWorkflowConfig();
    controller = ImuInstallationCalibrationController(imu,config.busId, ...
        config.calibrationDirectory,workflowOptions);
    controllerCleanup = onCleanup(@()delete(controller));
    result = controller.runBlocking();
    assert(result.success,strjoin(result.errors," "));
    saved = loadImuCalibration(result.finalFile,config.busId,config.uid);
    applyMountCalibration(imu.readOnce(),saved);
    identity = imu.getIdentity();
    report.uid=string(identity.uid); report.firmwareVersion=identity.firmwareVersion;
    report.sensorFusionMode=imu.getSensorFusionMode();
    report.calibrationFile=result.finalFile; report.backupFile=result.backupFile;
    report.quality=saved.quality; report.verification=result.verification;
    report.rotationVehicleFromSensor=saved.rotationVehicleFromSensor;
    report.bias=saved.bias; report.warnings=result.warnings; report.success=true;
catch exception
    report.errors(end+1,1)=string(exception.identifier)+": "+string(exception.message);
end
report.observerWarnings=observerWarnings;
if report.success, observerState="PASSED"; observerType="stage_completed"; else, observerState="FAILED"; observerType="stage_failed"; end
capture(notifyHardwareAcceptanceObserver(options,observerType,"installation_calibration",observerState,1, ...
    "Installation calibration acceptance completed.",report));
report.observerWarnings=observerWarnings;
report = savePhaseReport(report,'calibration_acceptance');
capture(notifyHardwareAcceptanceObserver(options,"report_saved","artifact_save","PASSED",1, ...
    "Calibration acceptance report saved.",struct('matFile',report.matFile,'jsonFile',report.jsonFile)));
report.observerWarnings=observerWarnings; persistPhaseReport(report);

    function capture(value)
        if strlength(value)>0, observerWarnings(end+1,1)=value; end
    end
end

function persistPhaseReport(report)
save(char(report.matFile),'report','-v7');
fileId=fopen(char(report.jsonFile),'w');
if fileId<0, error('IMU:AcceptanceSaveFailed','Cannot write %s.',report.jsonFile); end
cleanup=onCleanup(@()fclose(fileId)); fprintf(fileId,'%s',jsonencode(report,'PrettyPrint',true)); clear cleanup;
end

function report = savePhaseReport(report,prefix)
artifactDirectory=resolveProjectPath('artifacts');
if ~isfolder(artifactDirectory), mkdir(artifactDirectory); end
stamp=char(datetime('now','Format','yyyyMMdd_HHmmss_SSS'));
stem=fullfile(artifactDirectory,[prefix '_' stamp]);
report.matFile=string(stem)+".mat"; report.jsonFile=string(stem)+".json";
save(char(report.matFile),'report','-v7');
fileId=fopen(char(report.jsonFile),'w');
if fileId<0, error('IMU:AcceptanceSaveFailed','Cannot write %s.',report.jsonFile); end
fileCleanup=onCleanup(@()fclose(fileId));
fprintf(fileId,'%s',jsonencode(report,'PrettyPrint',true));
end
