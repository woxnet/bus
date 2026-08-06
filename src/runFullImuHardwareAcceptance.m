function combined = runFullImuHardwareAcceptance(options)
%RUNFULLIMUHARDWAREACCEPTANCE Run isolated physical phases and save diagnostics.
if nargin < 1 || isempty(options), options=struct(); end
dependencies=defaultDependencies();
if isfield(options,'Dependencies')
    names=fieldnames(options.Dependencies);
    for index=1:numel(names)
        dependencies.(names{index})=options.Dependencies.(names{index});
    end
end
if isfield(options,'ArtifactDirectory')
    artifactDirectory=string(options.ArtifactDirectory);
else
    artifactDirectory=string(resolveProjectPath('artifacts'));
end

combined=struct('success',false,'generatedAt',datetime('now','TimeZone','UTC'), ...
    'checkoutCommit',"",'failurePhase',"bootstrap", ...
    'infrastructureFailure',false,'errors',strings(0,1), ...
    'imuBrick2Source',"",'controllerSource',"",'monitorSource',"", ...
    'imuBrick2MethodsValid',false,'controllerMethodsValid',false, ...
    'monitorMethodsValid',false,'matlabRestartRequired',false, ...
    'observerWarnings',strings(0,1));
calibrationReport=[]; runtimeReport=[]; realtimeReport=[];
childOptions=struct(); if isfield(options,'Observer'), childOptions.Observer=options.Observer; end
try
    notify("stage_started","bootstrap","RUNNING",0,"Acceptance bootstrap started.",struct());
    api=dependencies.assertClassApi();
    combined=copyApiDiagnostics(combined,api);
    if combined.matlabRestartRequired
        error('IMU:StaleMatlabClassDefinition','%s\n%s\n%s', ...
            'MATLAB has an older class definition loaded.', ...
            'Close IMU objects and restart MATLAB.', ...
            'Verify the checkout commit before retrying.');
    end
    combined.checkoutCommit=string(dependencies.getCommit());
    notify("stage_completed","bootstrap","PASSED",1,"Acceptance bootstrap complete.",api);
    notify("stage_started","class_api","RUNNING",0,"Class API validation started.",struct());
    notify("stage_completed","class_api","PASSED",1,"Class API validation passed.",api);
    notify("stage_started","commit_check","RUNNING",0,"Commit check started.",struct());
    notify("stage_completed","commit_check","PASSED",1,"Commit check passed.",struct('commit',combined.checkoutCommit));
catch exception
    combined.infrastructureFailure=true;
    combined.matlabRestartRequired=strcmp(exception.identifier, ...
        'IMU:StaleMatlabClassDefinition');
    combined.errors(end+1,1)=formatException(exception);
    notify("stage_failed",combined.failurePhase,"FAILED",1,exception.message,struct('identifier',exception.identifier));
    combined=saveCombined(combined,artifactDirectory);
    return;
end

try
    combined.failurePhase="installation_calibration";
    calibrationReport=runChild(dependencies.runCalibration,"installation_calibration");
    verifyPhaseReport(calibrationReport,combined.checkoutCommit);
    if ~phaseSuccess(calibrationReport)
        combined=finishFailedPhase(combined,calibrationReport,artifactDirectory);
        return;
    end
    combined.observerWarnings=[combined.observerWarnings; childWarnings(calibrationReport)];

    combined.failurePhase="runtime_fifo";
    runtimeReport=runChild(dependencies.runRuntime,"runtime_fifo");
    verifyPhaseReport(runtimeReport,combined.checkoutCommit);
    if ~phaseSuccess(runtimeReport)
        combined=attachReport(combined,'calibrationReport',calibrationReport);
        combined=finishFailedPhase(combined,runtimeReport,artifactDirectory);
        return;
    end
    combined.observerWarnings=[combined.observerWarnings; childWarnings(runtimeReport)];

    combined.failurePhase="realtime_monitor";
    realtimeReport=runChild(dependencies.runRealtime,"realtime_monitor");
    verifyPhaseReport(realtimeReport,combined.checkoutCommit);
    if ~phaseSuccess(realtimeReport)
        combined=attachReport(combined,'calibrationReport',calibrationReport);
        combined=attachReport(combined,'runtimeReport',runtimeReport);
        combined=finishFailedPhase(combined,realtimeReport,artifactDirectory);
        return;
    end
    combined.observerWarnings=[combined.observerWarnings; childWarnings(realtimeReport)];
catch exception
    combined.infrastructureFailure=true;
    combined.errors(end+1,1)=formatException(exception);
    notify("stage_failed",combined.failurePhase,"FAILED",1,exception.message,struct('identifier',exception.identifier));
    if ~isempty(calibrationReport)
        combined=attachReport(combined,'calibrationReport',calibrationReport);
    end
    if ~isempty(runtimeReport)
        combined=attachReport(combined,'runtimeReport',runtimeReport);
    end
    if ~isempty(realtimeReport)
        combined=attachReport(combined,'realtimeReport',realtimeReport);
    end
    combined=saveCombined(combined,artifactDirectory);
    return;
end

combined.failurePhase="summary_validation";
try
    notify("stage_started","summary_validation","RUNNING",0,"Summary validation started.",struct());
    summary=dependencies.summarize(calibrationReport,runtimeReport,realtimeReport);
    names=fieldnames(summary);
    for index=1:numel(names), combined.(names{index})=summary.(names{index}); end
    finalCommit=string(dependencies.getCommit());
    if finalCommit~=combined.checkoutCommit
        error('IMU:AcceptanceCommitMismatch', ...
            'The checkout commit changed during hardware acceptance.');
    end
    verifyPhaseReport(calibrationReport,combined.checkoutCommit);
    verifyPhaseReport(runtimeReport,combined.checkoutCommit);
    verifyPhaseReport(realtimeReport,combined.checkoutCommit);
    combined.calibrationReport=calibrationReport;
    combined.runtimeReport=runtimeReport;
    combined.realtimeReport=realtimeReport;
    combined.failurePhase="";
    notify("stage_completed","summary_validation","PASSED",1,"Summary validation passed.",summary);
catch exception
    combined.success=false; combined.infrastructureFailure=true;
    combined.errors(end+1,1)=formatException(exception);
    notify("stage_failed","summary_validation","FAILED",1,exception.message,struct('identifier',exception.identifier));
end
notify("stage_started","artifact_save","RUNNING",0,"Saving combined report.",struct());
combined=saveCombined(combined,artifactDirectory);
notify("report_saved","artifact_save","PASSED",1,"Combined report saved.",struct('matFile',combined.matFile,'jsonFile',combined.jsonFile));
persistCombined(combined);

    function dependencies=defaultDependencies()
        dependencies=struct( ...
            'assertClassApi',@()assertImuAcceptanceClassApi( ...
                struct('ThrowOnFailure',false)), ...
            'getCommit',@()getImuAcceptanceCommit(), ...
            'runCalibration',@(child)runInstallationCalibrationHardwareAcceptance(child), ...
            'runRuntime',@(child)runRuntimePhase(child), ...
            'runRealtime',@(child)runRealtimeHardwareAcceptance(child), ...
            'summarize',@summarizeBusImuAcceptance);
    end

    function report=runRuntimePhase(child)
        config=getImuConfig();
        imu=ImuBrick2(config.uid,config.host,config.port);
        imuCleanup=onCleanup(@()imu.disconnect());
        preflight=diagnoseImuBrick2UsingExistingConnection(imu);
        if ~preflight.success
            error('IMU:PreflightFailed','%s',strjoin(preflight.errors," "));
        end
        report=runImuHardwareAcceptance(imu,60,artifactDirectory,child);
    end

    function report=runChild(action,stage)
        acceptsOptions=nargin(action)~=0;
        if ~acceptsOptions, notify("stage_started",stage,"RUNNING",0,stage+" started.",struct()); end
        if acceptsOptions, report=action(childOptions); else, report=action(); end
        if ~acceptsOptions
            if phaseSuccess(report), type="stage_completed"; state="PASSED"; else, type="stage_failed"; state="FAILED"; end
            notify(type,stage,state,1,stage+" completed.",report);
        end
    end

    function warnings=childWarnings(report)
        warnings=strings(0,1);
        if isstruct(report) && isfield(report,'observerWarnings'), warnings=string(report.observerWarnings(:)); end
    end

    function notify(type,stage,state,progress,message,payload)
        if ~isfield(options,'Observer') || isempty(options.Observer), return; end
        event=struct('timestamp',datetime('now','TimeZone','UTC'),'type',string(type), ...
            'stage',string(stage),'state',string(state),'progress',double(progress), ...
            'message',string(message),'payload',payload);
        try
            options.Observer(event);
        catch observerException
            combined.observerWarnings(end+1,1)=string(observerException.identifier)+": "+string(observerException.message);
            warning('IMU:AcceptanceObserverFailed','Acceptance observer failed: %s',observerException.message);
        end
    end
end

function persistCombined(combined)
save(char(combined.matFile),'combined','-v7');
fileId=fopen(char(combined.jsonFile),'w');
if fileId<0, error('IMU:AcceptanceSaveFailed','Cannot write %s.',combined.jsonFile); end
cleanup=onCleanup(@()fclose(fileId)); fprintf(fileId,'%s',jsonencode(combined,'PrettyPrint',true)); clear cleanup;
end

function combined=copyApiDiagnostics(combined,api)
names={'imuBrick2Source','controllerSource','monitorSource', ...
    'imuBrick2MethodsValid','controllerMethodsValid','monitorMethodsValid', ...
    'matlabRestartRequired'};
for index=1:numel(names), combined.(names{index})=api.(names{index}); end
end

function verifyPhaseReport(report,checkoutCommit)
if ~isstruct(report) || ~isscalar(report) || ~isfield(report,'commit') || ...
        string(report.commit)~=string(checkoutCommit)
    error('IMU:AcceptanceCommitMismatch', ...
        'Hardware acceptance phases did not use the same checkout commit.');
end
end

function result=phaseSuccess(report)
result=isstruct(report) && isscalar(report) && isfield(report,'success') && ...
    isscalar(report.success) && logical(report.success);
end

function combined=finishFailedPhase(combined,report,artifactDirectory)
combined=attachReport(combined,reportFieldName(combined.failurePhase),report);
if isfield(report,'errors'), combined.errors=string(report.errors(:)); end
combined=saveCombined(combined,artifactDirectory);
end

function name=reportFieldName(phase)
switch string(phase)
    case "installation_calibration", name='calibrationReport';
    case "runtime_fifo", name='runtimeReport';
    otherwise, name='realtimeReport';
end
end

function combined=attachReport(combined,name,report)
if ~isempty(report), combined.(name)=report; end
end

function value=formatException(exception)
value=string(exception.identifier)+": "+string(exception.message);
end

function combined=saveCombined(combined,artifactDirectory)
if ~isfolder(artifactDirectory), mkdir(artifactDirectory); end
stamp=char(datetime('now','Format','yyyyMMdd_HHmmss_SSS'));
stem=fullfile(char(artifactDirectory),['full_imu_acceptance_' stamp]);
combined.matFile=string(stem)+".mat"; combined.jsonFile=string(stem)+".json";
save(char(combined.matFile),'combined','-v7');
fileId=fopen(char(combined.jsonFile),'w');
if fileId<0, error('IMU:AcceptanceSaveFailed','Cannot write %s.',combined.jsonFile); end
fileCleanup=onCleanup(@()fclose(fileId));
fprintf(fileId,'%s',jsonencode(combined,'PrettyPrint',true)); clear fileCleanup;
decoded=jsondecode(fileread(combined.jsonFile));
required={'success','checkoutCommit','failurePhase','infrastructureFailure', ...
    'imuBrick2Source','controllerSource','monitorSource', ...
    'imuBrick2MethodsValid','controllerMethodsValid','monitorMethodsValid', ...
    'matlabRestartRequired'};
if ~all(isfield(decoded,required))
    error('IMU:AcceptanceArtifactInvalid', ...
        'Combined acceptance JSON failed validation.');
end
end
