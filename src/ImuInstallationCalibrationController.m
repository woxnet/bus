classdef ImuInstallationCalibrationController < handle
%IMUINSTALLATIONCALIBRATIONCONTROLLER Operator-controlled IMU calibration.
    properties (SetAccess = private)
        State = "IDLE"
        Progress = 0
        Message = ""
        IsRunning = false
        CancelRequested = false
        PreflightReport = []
        Calibration = []
        ValidationReport = []
        VerificationReport = []
        FinalFile = ""
        BackupFile = ""
        WorkingFile = ""
        StartedAt = NaT
        CompletedAt = NaT
        LastError = []
    end
    properties
        OnStateChanged = []
        OnProgress = []
        OnMessage = []
        OnCompleted = []
        OnCancelled = []
        OnError = []
    end
    properties (Access = private)
        Imu
        BusId
        CalibrationDirectory
        Options
        Dependencies
        Calibrator = []
        Dashboard = []
        WorkflowTimer = []
        Result = []
        StoppedExistingStream = false
        PreviousStreamingPeriodMs = NaN
        OperatorConfirmedStationary = false
        OperatorConfirmedForward = false
        Deleting = false
    end

    methods
        function obj = ImuInstallationCalibrationController(imu, busId, calibrationDirectory, options, dependencies)
            if nargin < 1 || isempty(imu) || ~ismethod(imu, 'readOnce')
                error('IMU:InvalidConfiguration', 'imu must support readOnce().');
            end
            defaults = getImuInstallationCalibrationWorkflowConfig();
            if nargin < 2 || isempty(busId), busId = defaults.busId; end
            if nargin < 3 || isempty(calibrationDirectory), calibrationDirectory = defaults.calibrationDirectory; end
            if nargin < 4 || isempty(options), options = struct(); end
            options.busId = string(busId);
            options.calibrationDirectory = string(calibrationDirectory);
            obj.Options = validateImuInstallationCalibrationWorkflowConfig(options);
            if nargin < 5, dependencies = struct(); end
            obj.Dependencies = obj.mergeDependencies(dependencies);
            obj.Imu = imu;
            obj.BusId = string(busId);
            obj.CalibrationDirectory = string(resolveProjectPath(calibrationDirectory));
            stem = char(obj.BusId + "_imu_mount");
            obj.FinalFile = string(fullfile(char(obj.CalibrationDirectory), [stem '.mat']));
            obj.WorkingFile = string(fullfile(char(obj.CalibrationDirectory), [stem '.inprogress.mat']));
        end

        function start(obj)
            if obj.IsRunning || obj.State ~= "IDLE"
                error('IMU:CalibrationAlreadyStarted', 'Calibration controller can only be started once.');
            end
            obj.beginRun();
            try
                obj.WorkflowTimer = obj.Dependencies.createTimer( ...
                    'ExecutionMode','singleShot','TimerFcn',@(~,~)obj.executeWorkflow());
                start(obj.WorkflowTimer);
            catch exception
                obj.finishFailure(exception);
                rethrow(exception);
            end
        end

        function cancel(obj)
            obj.CancelRequested = true;
            if ~isempty(obj.Calibrator)
                try, obj.Calibrator.cancel(); catch, end
            end
        end

        function result = wait(obj)
            while obj.IsRunning
                obj.Dependencies.sleep(obj.Options.pollStatusSeconds);
                drawnow limitrate;
            end
            if isempty(obj.Result), obj.Result = obj.makeResult(); end
            result = obj.Result;
        end

        function result = runBlocking(obj)
            if obj.IsRunning || obj.State ~= "IDLE"
                error('IMU:CalibrationAlreadyStarted', 'Calibration controller can only be started once.');
            end
            obj.beginRun();
            obj.executeWorkflow();
            result = obj.Result;
        end

        function status = getStatus(obj)
            status = struct('state',obj.State,'progress',obj.Progress, ...
                'message',obj.Message,'isRunning',obj.IsRunning, ...
                'cancelRequested',obj.CancelRequested,'startedAt',obj.StartedAt, ...
                'completedAt',obj.CompletedAt,'lastError',obj.LastError, ...
                'finalFile',obj.FinalFile,'backupFile',obj.BackupFile, ...
                'workingFile',obj.WorkingFile,'quality',obj.qualityScore(), ...
                'verification',obj.verificationScore());
        end

        function delete(obj)
            if obj.Deleting, return; end
            obj.Deleting = true;
            obj.cancel();
            obj.destroyTimer();
            if ~obj.Options.keepFailedWorkingFiles, obj.safeDeleteWorking(); end
            if ~isempty(obj.Dashboard)
                try, delete(obj.Dashboard); catch, end
            end
        end
    end

    methods (Access = private)
        function beginRun(obj)
            obj.IsRunning = true;
            obj.CancelRequested = false;
            obj.StartedAt = obj.Dependencies.nowUtc();
            obj.CompletedAt = NaT;
            obj.LastError = [];
            if obj.Options.enableDashboard
                obj.Dashboard = obj.Dependencies.createDashboard(obj);
            end
        end

        function executeWorkflow(obj)
            try
                obj.checkCancelled();
                obj.acquireExclusiveAccess();
                obj.setStatus("PREFLIGHT",0.01,"Running IMU hardware preflight.");
                obj.PreflightReport = obj.Dependencies.runPreflight(obj.Imu);
                obj.validatePreflight();
                obj.checkCancelled();
                obj.setStatus("OPERATOR_CONFIRMATION",0.03, ...
                    "Confirm that the bus is stationary, level, closed, and the IMU is secured.");
                if obj.Options.requireOperatorConfirmation && ...
                        ~obj.Dependencies.confirm(obj.stationaryPrompt())
                    obj.cancel(); obj.checkCancelled();
                end
                obj.OperatorConfirmedStationary = true;
                calibrationConfig = getImuCalibrationConfig();
                obj.Calibrator = obj.Dependencies.createCalibrator(obj.Imu, calibrationConfig);
                obj.attachCalibratorCallbacks();
                metadata = obj.makeMetadata();
                obj.Calibration = obj.Calibrator.run(char(obj.WorkingFile), metadata);
                obj.checkCancelled();
                obj.setStatus("CALCULATING",0.90,"Validating candidate calibration.");
                obj.Calibration = obj.Dependencies.loadCalibration(char(obj.WorkingFile), ...
                    obj.BusId, string(obj.PreflightReport.uid));
                obj.ValidationReport = validateImuCalibration(obj.Calibration);
                if ~obj.ValidationReport.valid
                    error('IMU:CalibrationRejected','%s',strjoin(obj.ValidationReport.errors,' '));
                end
                if obj.Options.performVerification
                    obj.setStatus("VERIFYING",0.93,"Verifying the candidate calibration.");
                    verificationDependencies=struct('sleep',obj.Dependencies.sleep, ...
                        'beforeForward',@()obj.confirmVerificationForward());
                    obj.VerificationReport = verifyImuInstallationCalibration( ...
                        obj.Imu,obj.Calibration,obj.Options,verificationDependencies);
                    if obj.VerificationReport.forwardAccelerationMean <= 0
                        error('IMU:CalibrationForwardAxisReversed', ...
                            'Verification detected a reversed forward axis.');
                    end
                    if ~obj.VerificationReport.success
                        error('IMU:CalibrationVerificationFailed','%s', ...
                            strjoin(obj.VerificationReport.errors,' '));
                    end
                else
                    obj.VerificationReport = struct('success',true,'score',1, ...
                        'errors',strings(0,1),'warnings',strings(0,1));
                end
                obj.Calibration.metadata.verificationPassed = true;
                obj.Calibration.metadata.verificationScore = obj.VerificationReport.score;
                obj.saveWorkingCandidate();
                obj.setStatus("SAVING",0.98,"Saving verified calibration atomically.");
                obj.persistCandidate();
                obj.setStatus("READY",1,"Installation calibration is ready.");
                obj.finishSuccess();
            catch exception
                if strcmp(exception.identifier,'IMU:CalibrationCancelled') || obj.CancelRequested
                    obj.finishCancelled();
                else
                    obj.finishFailure(exception);
                end
            end
        end

        function acquireExclusiveAccess(obj)
            streaming = isprop(obj.Imu,'IsStreaming') && logical(obj.Imu.IsStreaming);
            if ~streaming, return; end
            if ~obj.Options.StopExistingStream
                error('IMU:CalibrationRequiresExclusiveAccess', ...
                    'Stop the active IMU consumer before calibration.');
            end
            if isprop(obj.Imu,'StreamOwner') && ...
                    ~any(string(obj.Imu.StreamOwner)==["none","callback"])
                error('IMU:CalibrationRequiresExclusiveAccess', ...
                    'An active monitor or recorder owns the IMU stream.');
            end
            obj.PreviousStreamingPeriodMs = double(obj.Imu.StreamingPeriodMs);
            obj.Imu.stop();
            obj.StoppedExistingStream = true;
        end

        function validatePreflight(obj)
            report = obj.PreflightReport;
            required = {'success','uid','firmwareVersion','sensorFusionMode', ...
                'callbackFrequencyHz','callbackMissingSequences', ...
                'callbackOverflowDropped','callbackMaximumAgeMs'};
            if ~isstruct(report) || ~all(isfield(report,required)) || ~logical(report.success)
                error('IMU:CalibrationPreflightFailed','IMU hardware preflight failed.');
            end
            config = getImuConfig();
            if string(report.uid) ~= string(config.uid)
                error('IMU:CalibrationPreflightFailed','Preflight UID does not match configured IMU.');
            end
            if ~obj.versionAtLeast(report.firmwareVersion,config.minimumFirmwareVersion) || ...
                    report.sensorFusionMode ~= config.sensorFusionMode || ...
                    report.callbackMissingSequences ~= 0 || report.callbackOverflowDropped ~= 0 || ...
                    report.callbackMaximumAgeMs > config.maximumCallbackSampleAgeMs
                error('IMU:CalibrationPreflightFailed','Preflight metrics do not meet requirements.');
            end
        end

        function attachCalibratorCallbacks(obj)
            if isprop(obj.Calibrator,'OnStatusChanged')
                obj.Calibrator.OnStatusChanged = @(~,status)obj.onCalibratorStatus(status);
                obj.Calibrator.OnProgress = @(~,status)obj.onCalibratorProgress(status);
                obj.Calibrator.OnMessage = @(~,status)obj.onCalibratorMessage(status);
            end
        end

        function onCalibratorStatus(obj,status)
            state = string(status.state);
            if state == "WAIT_FORWARD_ACCELERATION" && ~obj.OperatorConfirmedForward
                obj.setStatus("OPERATOR_CONFIRMATION",max(.49,status.progress),obj.forwardPrompt());
                if obj.Options.requireOperatorConfirmation && ...
                        ~obj.Dependencies.confirm(obj.forwardPrompt())
                    obj.cancel(); return;
                end
                obj.OperatorConfirmedForward = true;
            end
            mapped = obj.mapCalibratorState(state,status.progress);
            obj.setStatus(mapped,status.progress,string(status.message));
        end

        function onCalibratorProgress(obj,status)
            state = obj.mapCalibratorState(string(status.state),status.progress);
            obj.setProgress(state,status.progress);
        end

        function onCalibratorMessage(obj,status)
            obj.Message = string(status.message);
            obj.safeCallback(obj.OnMessage,obj.getStatus());
        end

        function state = mapCalibratorState(~,state,progress)
            if state == "WAIT_STILL" && progress > 0.05, state = "STATIONARY_SAMPLING"; end
            if state == "LEVEL_CALIBRATION", state = "WAIT_FORWARD_ACCELERATION"; end
            if state == "WAIT_FORWARD_ACCELERATION" && progress > 0.50, state = "FORWARD_SAMPLING"; end
            if state == "VALIDATION", state = "CALCULATING"; end
            if ~any(state == ["WAIT_STILL","STATIONARY_SAMPLING", ...
                    "WAIT_FORWARD_ACCELERATION","FORWARD_SAMPLING","CALCULATING"])
                if state ~= "CANCELLED", state = "WAIT_STILL"; end
            end
        end

        function metadata = makeMetadata(obj)
            identity = obj.Imu.getIdentity();
            metadata = struct('busId',obj.BusId,'imuUid',string(identity.uid), ...
                'deviceIdentifier',identity.deviceIdentifier, ...
                'firmwareVersion',identity.firmwareVersion, ...
                'sensorFusionMode',obj.PreflightReport.sensorFusionMode, ...
                'sampleRateHz',getImuCalibrationConfig().sampleRate, ...
                'algorithmVersion',"2.0",'synthetic',false, ...
                'workflowVersion',"1.0", ...
                'preflightGeneratedAt',obj.preflightTime(), ...
                'preflightCallbackFrequencyHz',obj.PreflightReport.callbackFrequencyHz, ...
                'previousCalibrationBackedUp',false,'previousCalibrationFile',"", ...
                'verificationPassed',false,'verificationScore',NaN, ...
                'operatorConfirmedStationary',obj.OperatorConfirmedStationary, ...
                'operatorConfirmedForward',true);
        end

        function value = preflightTime(obj)
            if isfield(obj.PreflightReport,'generatedAt'), value=obj.PreflightReport.generatedAt;
            else, value=obj.Dependencies.nowUtc(); end
        end

        function saveWorkingCandidate(obj)
            calibration = obj.Calibration; %#ok<NASGU>
            directory = fileparts(char(obj.WorkingFile));
            if ~isfolder(directory), mkdir(directory); end
            save(char(obj.WorkingFile),'calibration');
            obj.Calibration = obj.Dependencies.loadCalibration(char(obj.WorkingFile), ...
                obj.BusId,string(obj.PreflightReport.uid));
        end

        function persistCandidate(obj)
            directory = fileparts(char(obj.FinalFile));
            if ~isfolder(directory), mkdir(directory); end
            if isfile(obj.FinalFile) && obj.Options.backupExistingCalibration
                archive = fullfile(directory,'archive');
                if ~isfolder(archive), mkdir(archive); end
                timestamp = obj.Dependencies.nowUtc();
                timestamp.Format = 'yyyyMMdd_HHmmss_SSS';
                stamp = char(string(timestamp));
                obj.BackupFile = string(fullfile(archive, ...
                    char(obj.BusId + "_imu_mount_" + stamp + ".mat")));
                obj.Dependencies.copyFile(char(obj.FinalFile),char(obj.BackupFile));
                obj.Calibration.metadata.previousCalibrationBackedUp = true;
                obj.Calibration.metadata.previousCalibrationFile = obj.BackupFile;
                obj.saveWorkingCandidate();
            end
            obj.Dependencies.moveFile(char(obj.WorkingFile),char(obj.FinalFile));
        end

        function finishSuccess(obj)
            obj.IsRunning=false; obj.CompletedAt=obj.Dependencies.nowUtc();
            obj.restoreStreamIfAllowed(true); obj.destroyTimer();
            obj.Result=obj.makeResult(); obj.safeCallback(obj.OnCompleted,obj.Result);
        end

        function finishCancelled(obj)
            obj.State="CANCELLED"; obj.Message="Calibration cancelled.";
            obj.IsRunning=false; obj.CompletedAt=obj.Dependencies.nowUtc();
            obj.safeDeleteWorking(); obj.restoreStreamIfAllowed(false); obj.destroyTimer();
            obj.Result=obj.makeResult(); obj.safeCallback(obj.OnCancelled,obj.Result);
        end

        function finishFailure(obj,exception)
            obj.State="FAILED"; obj.Message=string(exception.message); obj.LastError=exception;
            obj.IsRunning=false; obj.CompletedAt=obj.Dependencies.nowUtc();
            if ~obj.Options.keepFailedWorkingFiles, obj.safeDeleteWorking(); end
            obj.restoreStreamIfAllowed(false); obj.destroyTimer();
            obj.Result=obj.makeResult(); obj.safeCallback(obj.OnError,exception);
        end

        function restoreStreamIfAllowed(obj,success)
            if success && obj.StoppedExistingStream && obj.Options.RestorePreviousStream
                try, obj.Imu.start(obj.PreviousStreamingPeriodMs);
                catch exception, warning('IMU:StreamRestoreFailed','%s',exception.message); end
            end
        end

        function setStatus(obj,state,progress,message)
            obj.State=string(state); obj.Progress=max(0,min(1,double(progress))); obj.Message=string(message);
            status=obj.getStatus();
            obj.safeCallback(obj.OnStateChanged,status);
            obj.safeCallback(obj.OnProgress,status);
            obj.safeCallback(obj.OnMessage,status);
        end

        function setProgress(obj,state,progress)
            obj.State=state; obj.Progress=max(0,min(1,double(progress)));
            obj.safeCallback(obj.OnProgress,obj.getStatus());
        end

        function checkCancelled(obj)
            if obj.CancelRequested, error('IMU:CalibrationCancelled','Calibration was cancelled.'); end
        end

        function result = makeResult(obj)
            errors=strings(0,1); warnings=strings(0,1);
            if ~isempty(obj.LastError), errors=string(obj.LastError.message); end
            if isstruct(obj.VerificationReport) && isfield(obj.VerificationReport,'warnings')
                warnings=string(obj.VerificationReport.warnings);
            end
            result=struct('success',obj.State=="READY",'cancelled',obj.State=="CANCELLED", ...
                'state',obj.State,'calibration',obj.Calibration,'preflight',obj.PreflightReport, ...
                'validation',obj.ValidationReport,'verification',obj.VerificationReport, ...
                'finalFile',obj.FinalFile,'backupFile',obj.BackupFile, ...
                'workingFile',obj.WorkingFile,'startedAt',obj.StartedAt, ...
                'completedAt',obj.CompletedAt,'errors',errors,'warnings',warnings);
        end

        function safeCallback(obj,callback,value)
            if isempty(callback), return; end
            try, callback(obj,value); catch exception
                warning('IMU:CalibrationCallbackFailed','User callback failed: %s',exception.message);
            end
        end

        function safeDeleteWorking(obj)
            try
                if isfile(obj.WorkingFile), obj.Dependencies.deleteFile(char(obj.WorkingFile)); end
            catch exception
                warning('IMU:CalibrationCleanupFailed','%s',exception.message);
            end
        end

        function destroyTimer(obj)
            if isempty(obj.WorkflowTimer), return; end
            try, stop(obj.WorkflowTimer); catch, end
            try, delete(obj.WorkflowTimer); catch, end
            obj.WorkflowTimer=[];
        end

        function score=qualityScore(obj)
            score=NaN;
            if isstruct(obj.Calibration) && isfield(obj.Calibration,'quality'), score=obj.Calibration.quality.score; end
        end

        function score=verificationScore(obj)
            score=NaN;
            if isstruct(obj.VerificationReport) && isfield(obj.VerificationReport,'score'), score=obj.VerificationReport.score; end
        end

        function prompt=stationaryPrompt(~)
            prompt=strjoin(["The bus is on a level surface.";"Doors are closed."; ...
                "There are no moving passengers.";"The engine state follows the procedure."; ...
                "The IMU is permanently secured."],newline);
        end

        function prompt=forwardPrompt(~)
            prompt=strjoin(["There is sufficient free space ahead."; ...
                "Perform a smooth, straight acceleration forward."; ...
                "Do not turn or brake during measurement."; ...
                "Use forward acceleration, not braking."],newline);
        end

        function confirmVerificationForward(obj)
            obj.checkCancelled();
            obj.setStatus("OPERATOR_CONFIRMATION",0.95, ...
                "Confirm the separate straight-forward verification manoeuvre.");
            if obj.Options.requireOperatorConfirmation && ...
                    ~obj.Dependencies.confirm(obj.forwardPrompt())
                obj.cancel(); obj.checkCancelled();
            end
            obj.setStatus("VERIFYING",0.96,"Collecting forward verification samples.");
        end
    end

    methods (Static, Access=private)
        function dependencies=mergeDependencies(custom)
            dependencies=struct( ...
                'runPreflight',@productionPreflight, ...
                'createCalibrator',@(imu,config)ImuMountCalibrator(imu,config), ...
                'createDashboard',@(controller)ImuInstallationCalibrationDashboard(controller), ...
                'confirm',@productionConfirm,'nowUtc',@()datetime('now','TimeZone','UTC'), ...
                'createTimer',@(varargin)timer(varargin{:}), ...
                'copyFile',@copyChecked,'moveFile',@moveChecked, ...
                'deleteFile',@delete,'loadCalibration',@loadImuCalibration,'sleep',@pause);
            if ~isstruct(custom) || ~isscalar(custom)
                error('IMU:InvalidConfiguration','dependencies must be a scalar structure.');
            end
            fields=fieldnames(custom);
            unknown=setdiff(fields,fieldnames(dependencies));
            if ~isempty(unknown), error('IMU:InvalidConfiguration','Unknown dependency: %s.',unknown{1}); end
            for index=1:numel(fields), dependencies.(fields{index})=custom.(fields{index}); end
        end

        function valid=versionAtLeast(actual,required)
            actual=double(actual(:)).'; required=double(required(:)).';
            width=max(numel(actual),numel(required)); actual(end+1:width)=0; required(end+1:width)=0;
            different=find(actual~=required,1,'first');
            valid=isempty(different)||actual(different)>required(different);
        end
    end
end

function report=productionPreflight(imu)
assertImuRuntimeReady();
report=diagnoseImuBrick2UsingExistingConnection(imu);
end

function confirmed=productionConfirm(prompt)
answer=questdlg(char(prompt),'IMU installation calibration','Confirm','Cancel','Cancel');
confirmed=strcmp(answer,'Confirm');
end

function copyChecked(source,destination)
[success,message]=copyfile(source,destination,'f');
if ~success, error('IMU:CalibrationBackupFailed','%s',message); end
end

function moveChecked(source,destination)
[success,message]=movefile(source,destination,'f');
if ~success, error('IMU:CalibrationSaveFailed','%s',message); end
end
