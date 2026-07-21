projectRoot = fileparts(fileparts(mfilename('fullpath')));
run(fullfile(projectRoot,"startup.m"));
assertImuRuntimeReady();
imuConfig=getImuConfig();
calibrationFile=resolveProjectPath(fullfile(imuConfig.calibrationDirectory, ...
    imuConfig.busId+"_imu_mount.mat"));
calibration=loadImuCalibration(calibrationFile,imuConfig.busId,imuConfig.uid);
imu=ImuBrick2(imuConfig.uid,imuConfig.host,imuConfig.port);
imuCleanup=onCleanup(@()imu.disconnect());
preflight=diagnoseImuBrick2UsingExistingConnection(imu);
disp(preflight); assert(preflight.success);
options=getRealtimeDrivingConfig(); options.enableLivePlot=false;
options.enableRecording=false; options.UseTimer=true;
monitor=RealtimeDrivingMonitor(imu,calibration,options);
monitorCleanup=onCleanup(@()delete(monitor));
monitor.start(); pause(120);
runningAtEnd=monitor.IsRunning; summary=monitor.stop();
report=summary; report.runningAtEnd=runningAtEnd;
report.success=runningAtEnd && summary.overflowDropped==0 && ...
    summary.staleSessionDropped==0 && summary.missingSamples==0 && ...
    summary.averageFrequencyHz>=40 && summary.averageFrequencyHz<=60 && ...
    summary.maximumCallbackAgeMs<=options.maximumSampleAgeMs;
artifactDirectory=resolveProjectPath('artifacts');
if ~isfolder(artifactDirectory), mkdir(artifactDirectory); end
stamp=char(datetime('now','Format','yyyyMMdd_HHmmss'));
matFile=fullfile(artifactDirectory,['realtime_acceptance_',stamp,'.mat']);
jsonFile=fullfile(artifactDirectory,['realtime_acceptance_',stamp,'.json']);
save(matFile,'report','-v7');
jsonReport=report; jsonReport.startedAt=string(report.startedAt);
jsonReport.stoppedAt=string(report.stoppedAt); jsonReport.lastError=[];
fileId=fopen(jsonFile,'w'); assert(fileId>=0); fileCleanup=onCleanup(@()fclose(fileId));
fprintf(fileId,'%s',jsonencode(jsonReport,'PrettyPrint',true)); clear fileCleanup;
report.matFile=string(matFile); report.jsonFile=string(jsonFile); disp(report);
assert(report.success);
clear projectRoot;
