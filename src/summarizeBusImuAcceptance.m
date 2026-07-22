function summary=summarizeBusImuAcceptance(calibrationReport,runtimeReport,realtimeReport)
%SUMMARIZEBUSIMUACCEPTANCE Cross-check all physical IMU acceptance phases.
reports={calibrationReport,runtimeReport,realtimeReport};
commits=fieldStrings(reports,'commit');
uids=fieldStrings(reports,'uid');
busIds=fieldStrings(reports,'busId');
fusionModes=fieldNumbers(reports,'sensorFusionMode');
summary=struct();
summary.commitMatch=allNonemptyEqual(commits);
summary.uidMatch=allNonemptyEqual(uids);
summary.busIdMatch=allNonemptyEqual(busIds);
summary.sensorFusionModeMatch=all(isfinite(fusionModes)) && ...
    numel(unique(fusionModes))==1;
calibrationFile=fieldString(calibrationReport,'calibrationFile');
summary.calibrationFileExists=strlength(calibrationFile)>0 && isfile(calibrationFile);
summary.calibrationVerified=isstruct(calibrationReport) && ...
    isfield(calibrationReport,'verification') && ...
    isstruct(calibrationReport.verification) && ...
    isfield(calibrationReport.verification,'success') && ...
    scalarTrue(calibrationReport.verification.success);
summary.calibrationSuccess=reportSuccess(calibrationReport);
summary.runtimeSuccess=reportSuccess(runtimeReport);
summary.realtimeSuccess=reportSuccess(realtimeReport);
summary.commit=commits(1); summary.uid=uids(1); summary.busId=busIds(1);
summary.sensorFusionMode=fusionModes(1);
summary.success=summary.calibrationSuccess && summary.runtimeSuccess && ...
    summary.realtimeSuccess && summary.commitMatch && summary.uidMatch && ...
    summary.busIdMatch && summary.sensorFusionModeMatch && ...
    summary.calibrationFileExists && summary.calibrationVerified;
end

function values=fieldStrings(reports,name)
values=strings(1,numel(reports));
for index=1:numel(reports), values(index)=fieldString(reports{index},name); end
end

function value=fieldString(report,name)
value="";
if isstruct(report) && isscalar(report) && isfield(report,name)
    candidate=string(report.(name));
    if isscalar(candidate), value=candidate; end
end
end

function values=fieldNumbers(reports,name)
values=nan(1,numel(reports));
for index=1:numel(reports)
    report=reports{index};
    if isstruct(report) && isscalar(report) && isfield(report,name) && ...
            isnumeric(report.(name)) && isscalar(report.(name))
        values(index)=double(report.(name));
    end
end
end

function result=allNonemptyEqual(values)
result=all(strlength(values)>0) && numel(unique(values))==1;
end

function result=reportSuccess(report)
result=isstruct(report) && isscalar(report) && isfield(report,'success') && ...
    scalarTrue(report.success);
end

function result=scalarTrue(value)
result=(islogical(value)||isnumeric(value)) && isscalar(value) && ...
    isfinite(double(value)) && logical(value);
end
