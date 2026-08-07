function report = runInstallationCalibrationHardwareAcceptance(options)
%RUNINSTALLATIONCALIBRATIONHARDWAREACCEPTANCE Calibrate and verify one IMU.
if nargin<1 || isempty(options), options=struct(); end
dependencies=defaultDependencies();
if isfield(options,'Dependencies')
    names=fieldnames(options.Dependencies);
    for dependencyIndex=1:numel(names), dependencies.(names{dependencyIndex})=options.Dependencies.(names{dependencyIndex}); end
end
observerWarnings=strings(0,1);
capture(notifyHardwareAcceptanceObserver(options,"stage_started","installation_calibration","RUNNING",0, ...
    "Installation calibration acceptance started.",struct()));
dependencies.assertClassApi();
checkoutCommit = dependencies.getCommit();
dependencies.assertRuntimeReady();
config = dependencies.getConfig();
report = struct('success',false,'commit',checkoutCommit, ...
    'matlabVersion',string(version),'javaVersion',string(version('-java')), ...
    'uid',config.uid,'busId',config.busId,'firmwareVersion',[NaN NaN NaN], ...
    'sensorFusionMode',NaN,'calibrationFile',"",'backupFile',"", ...
    'quality',[],'verification',[],'rotationVehicleFromSensor',[], ...
    'bias',[],'errors',strings(0,1),'warnings',strings(0,1));
imu = dependencies.createImu(config);
imuCleanup = onCleanup(@()imu.disconnect());
try
    preflight = dependencies.runPreflight(imu);
    assert(preflight.success,strjoin(preflight.errors," "));
    workflowOptions = getImuInstallationCalibrationWorkflowConfig();
    if isfield(options,'Observer') && ~isempty(options.Observer)
        workflowOptions.enableDashboard=false;
    end
    workflowDependencies=struct();
    if isfield(options,'Confirm') && ~isempty(options.Confirm)
        workflowDependencies.confirm=@(prompt)logical(options.Confirm(prompt));
    end
    controller = dependencies.createController(imu,config,workflowOptions,workflowDependencies);
    controllerCleanup = onCleanup(@()delete(controller));
    if isfield(options,'Observer') && ~isempty(options.Observer)
        controller.OnStateChanged=@(~,status)forwardCalibrationStatus(status);
        controller.OnProgress=@(~,status)forwardCalibrationStatus(status);
        controller.OnMessage=@(~,status)forwardCalibrationStatus(status);
    end
    result = controller.runBlocking();
    assert(result.success,strjoin(result.errors," "));
    saved = dependencies.loadCalibration(result.finalFile,config.busId,config.uid);
    dependencies.applyCalibration(imu.readOnce(),saved);
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
    function forwardCalibrationStatus(status)
        capture(notifyHardwareAcceptanceObserver(options,"stage_progress", ...
            "installation_calibration","RUNNING",status.progress,string(status.message),status));
    end
    function value=defaultDependencies()
        value=struct('assertClassApi',@assertImuAcceptanceClassApi, ...
            'getCommit',@getImuAcceptanceCommit,'assertRuntimeReady',@assertImuRuntimeReady, ...
            'getConfig',@getImuConfig,'createImu',@(c)ImuBrick2(c.uid,c.host,c.port), ...
            'runPreflight',@diagnoseImuBrick2UsingExistingConnection, ...
            'createController',@(device,c,w,d)ImuInstallationCalibrationController( ...
                device,c.busId,c.calibrationDirectory,w,d), ...
            'loadCalibration',@loadImuCalibration,'applyCalibration',@applyMountCalibration);
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
