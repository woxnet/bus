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
        ActivationAttempted = false
        ActivationVerified = false
        RollbackAttempted = false
        RollbackSucceeded = false
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
        OperatorConfirmedVerificationForward = false
        CalibrationForwardDecisionHandled = false
        SamplesRequired = 0
        SamplesCollected = 0
        Phase = "idle"
        ConfirmationPending = false
        ConfirmationDecision = NaN
        ErrorIdentifiers = strings(0,1)
        ErrorMessages = strings(0,1)
        PreserveDiagnostics = false
        DependenciesInjected = false
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
            obj.DependenciesInjected = ~isempty(fieldnames(dependencies));
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
            obj.ConfirmationPending = false;
            if ~isempty(obj.Calibrator)
                try, obj.Calibrator.cancel(); catch, end
            end
        end

        function confirmCurrentStep(obj)
            if ~obj.ConfirmationPending, return; end
            obj.ConfirmationDecision = true;
            obj.ConfirmationPending = false;
        end

        function rejectCurrentStep(obj)
            if ~obj.ConfirmationPending, return; end
            obj.ConfirmationDecision = false;
            obj.ConfirmationPending = false;
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
                'verification',obj.verificationScore(), ...
                'samplesRequired',obj.SamplesRequired, ...
                'samplesCollected',obj.SamplesCollected, ...
                'samplesRemaining',max(0,obj.SamplesRequired-obj.SamplesCollected), ...
                'phase',obj.Phase);
        end

        function delete(obj)
            if obj.Deleting, return; end
            obj.Deleting = true;
            obj.cancel();
            obj.destroyTimer();
            if ~obj.Options.keepFailedWorkingFiles && ~obj.PreserveDiagnostics, obj.safeDeleteWorking(); end
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
            obj.ErrorIdentifiers = strings(0,1);
            obj.ErrorMessages = strings(0,1);
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
                if ~obj.requestConfirmation(obj.stationaryPrompt(),0.03)
                    obj.cancel(); obj.checkCancelled();
                end
                if obj.Options.requireOperatorConfirmation
                    obj.OperatorConfirmedStationary = true;
                end
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
                        'beforeForward',@()obj.confirmVerificationForward(), ...
                        'checkCancelled',@()obj.checkCancelled(), ...
                        'onProgress',@(phase,collected,required)obj.onVerificationProgress( ...
                            phase,collected,required));
                    obj.VerificationReport = verifyImuInstallationCalibration( ...
                        obj.Imu,obj.Calibration,obj.Options,verificationDependencies);
                    obj.checkCancelled();
                    obj.Calibration.metadata.verificationPerformed = true;
                    obj.Calibration.metadata.verificationPassed = obj.VerificationReport.success;
                    obj.Calibration.metadata.verificationScore = obj.VerificationReport.score;
                    obj.Calibration.metadata.verificationCompletedAt = obj.Dependencies.nowUtc();
                    if obj.VerificationReport.forwardAccelerationMean <= 0
                        obj.saveFailedVerificationDiagnostics();
                        error('IMU:CalibrationForwardAxisReversed', ...
                            'Verification detected a reversed forward axis.');
                    end
                    if ~obj.VerificationReport.success
                        obj.saveFailedVerificationDiagnostics();
                        error('IMU:CalibrationVerificationFailed','%s', ...
                            strjoin(obj.VerificationReport.errors,' '));
                    end
                else
                    obj.VerificationReport = [];
                    obj.Calibration.metadata.verificationPerformed = false;
                    obj.Calibration.metadata.verificationPassed = false;
                    obj.Calibration.metadata.verificationScore = NaN;
                    obj.Calibration.metadata.verificationCompletedAt = NaT('TimeZone','UTC');
                end
                obj.synchronizeOperatorMetadata();
                obj.setStatus("SAVING",0.97,"Saving verified working calibration.");
                obj.checkCancelled();
                obj.saveWorkingCandidate();
                obj.setStatus("SAVING",0.98,"Saving verified calibration atomically.");
                obj.checkCancelled();
                obj.persistCandidate();
                obj.setStatus("READY",1,"Installation calibration is ready.");
                obj.finishSuccess();
            catch exception
                obj.recordError(exception);
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
            obj.copySampleStatus(status);
            state = string(status.state);
            if state == "WAIT_FORWARD_ACCELERATION" && ~obj.CalibrationForwardDecisionHandled
                if ~obj.requestConfirmation(obj.forwardPrompt(),max(.49,status.progress))
                    obj.cancel(); return;
                end
                if obj.Options.requireOperatorConfirmation
                    obj.OperatorConfirmedForward = true;
                end
                obj.CalibrationForwardDecisionHandled = true;
            end
            mapped = obj.mapCalibratorState(state,status.progress);
            obj.setStatus(mapped,status.progress,string(status.message));
        end

        function onCalibratorProgress(obj,status)
            obj.copySampleStatus(status);
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
                'operatorConfirmationRequired',obj.Options.requireOperatorConfirmation, ...
                'operatorConfirmationMode',obj.confirmationMode(), ...
                'operatorConfirmedStationary',false, ...
                'operatorConfirmedForward',false, ...
                'operatorConfirmedVerificationForward',false, ...
                'verificationPerformed',false,'verificationPassed',false, ...
                'verificationScore',NaN, ...
                'verificationCompletedAt',NaT('TimeZone','UTC'));
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
                obj.checkCancelled();
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
            obj.setStatus("SAVING",0.99,"Activating and verifying final calibration.");
            obj.checkCancelled();
            obj.ActivationAttempted = true;
            try
                obj.Dependencies.moveFile(char(obj.WorkingFile),char(obj.FinalFile));
                activated = obj.Dependencies.loadCalibration(char(obj.FinalFile), ...
                    obj.BusId,string(obj.PreflightReport.uid));
                obj.verifyActivatedCalibration(activated);
                obj.Calibration = activated;
                obj.ActivationVerified = true;
            catch activationException
                obj.recordError(activationException);
                if strlength(obj.BackupFile)>0 && isfile(obj.BackupFile)
                    try
                        obj.rollbackFromBackup();
                    catch rollbackException
                        obj.recordError(rollbackException);
                        obj.PreserveDiagnostics = true;
                        obj.ensureWorkingDiagnostics();
                        failure=MException('IMU:CalibrationRollbackFailed', ...
                            'Activation failed (%s) and rollback failed (%s).', ...
                            activationException.message,rollbackException.message);
                        failure=addCause(failure,activationException);
                        failure=addCause(failure,rollbackException);
                        throw(failure);
                    end
                elseif isfile(obj.FinalFile)
                    try, obj.Dependencies.deleteFile(char(obj.FinalFile)); catch cleanupException
                        obj.recordError(cleanupException);
                    end
                end
                rethrow(activationException);
            end
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
            if ~obj.Options.keepFailedWorkingFiles && ~obj.PreserveDiagnostics, obj.safeDeleteWorking(); end
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
            errors=obj.ErrorMessages; warnings=strings(0,1);
            if isstruct(obj.PreflightReport)
                if isfield(obj.PreflightReport,'errors'), errors=[string(obj.PreflightReport.errors(:));errors]; end
                if isfield(obj.PreflightReport,'warnings'), warnings=[warnings;string(obj.PreflightReport.warnings(:))]; end
            end
            if isstruct(obj.ValidationReport) && isfield(obj.ValidationReport,'errors')
                errors=[errors;string(obj.ValidationReport.errors(:))];
            end
            if isstruct(obj.VerificationReport) && isfield(obj.VerificationReport,'warnings')
                warnings=[warnings;string(obj.VerificationReport.warnings(:))];
                if isfield(obj.VerificationReport,'errors')
                    errors=[errors;string(obj.VerificationReport.errors(:))];
                end
            end
            errors=unique(errors(strlength(errors)>0),'stable');
            warnings=unique(warnings(strlength(warnings)>0),'stable');
            result=struct('success',obj.State=="READY",'cancelled',obj.State=="CANCELLED", ...
                'state',obj.State,'calibration',obj.Calibration,'preflight',obj.PreflightReport, ...
                'validation',obj.ValidationReport,'verification',obj.VerificationReport, ...
                'finalFile',obj.FinalFile,'backupFile',obj.BackupFile, ...
                'workingFile',obj.WorkingFile,'startedAt',obj.StartedAt, ...
                'completedAt',obj.CompletedAt,'errors',errors,'warnings',warnings);
            result.errorIdentifier=""; result.errorMessage="";
            if ~isempty(obj.LastError)
                result.errorIdentifier=string(obj.LastError.identifier);
                result.errorMessage=string(obj.LastError.message);
            end
            result.errorIdentifiers=obj.ErrorIdentifiers;
            result.verificationPerformed=isstruct(obj.Calibration) && ...
                isfield(obj.Calibration,'metadata') && ...
                isfield(obj.Calibration.metadata,'verificationPerformed') && ...
                logical(obj.Calibration.metadata.verificationPerformed);
            result.activationAttempted=obj.ActivationAttempted;
            result.activationVerified=obj.ActivationVerified;
            result.rollbackAttempted=obj.RollbackAttempted;
            result.rollbackSucceeded=obj.RollbackSucceeded;
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
            if ~obj.requestConfirmation(obj.forwardPrompt(),0.95)
                obj.cancel(); obj.checkCancelled();
            end
            if obj.Options.requireOperatorConfirmation
                obj.OperatorConfirmedVerificationForward = true;
            end
            obj.checkCancelled();
            obj.setStatus("VERIFYING",0.96,"Collecting forward verification samples.");
        end

        function confirmed=requestConfirmation(obj,prompt,progress)
            if ~obj.Options.requireOperatorConfirmation
                confirmed=true;
                return;
            end
            obj.Phase="operator_confirmation";
            obj.SamplesRequired=0; obj.SamplesCollected=0;
            if obj.Options.enableDashboard
                obj.ConfirmationDecision=NaN;
                obj.ConfirmationPending=true;
            end
            obj.setStatus("OPERATOR_CONFIRMATION",progress,prompt);
            obj.checkCancelled();
            if obj.Options.enableDashboard
                while obj.ConfirmationPending
                    obj.checkCancelled();
                    drawnow;
                    obj.Dependencies.sleep(obj.Options.pollStatusSeconds);
                end
                confirmed=logical(obj.ConfirmationDecision);
            else
                confirmed=logical(obj.Dependencies.confirm(prompt));
            end
            obj.checkCancelled();
        end

        function onVerificationProgress(obj,phase,collected,required)
            obj.Phase=string(phase);
            obj.SamplesCollected=double(collected);
            obj.SamplesRequired=double(required);
            if obj.Phase=="verification_stationary"
                progress=.93+.02*collected/required;
            else
                progress=.96+.01*collected/required;
            end
            obj.setProgress("VERIFYING",progress);
        end

        function copySampleStatus(obj,status)
            fields={'samplesRequired','samplesCollected','phase'};
            for index=1:numel(fields)
                if isfield(status,fields{index})
                    if strcmp(fields{index},'phase'), obj.Phase=string(status.(fields{index}));
                    elseif strcmp(fields{index},'samplesRequired'), obj.SamplesRequired=double(status.(fields{index}));
                    else, obj.SamplesCollected=double(status.(fields{index})); end
                end
            end
        end

        function synchronizeOperatorMetadata(obj)
            obj.Calibration.metadata.operatorConfirmedStationary=obj.OperatorConfirmedStationary;
            obj.Calibration.metadata.operatorConfirmedForward=obj.OperatorConfirmedForward;
            obj.Calibration.metadata.operatorConfirmedVerificationForward= ...
                obj.OperatorConfirmedVerificationForward;
        end

        function mode=confirmationMode(obj)
            if ~obj.Options.requireOperatorConfirmation, mode="disabled";
            elseif obj.DependenciesInjected, mode="test";
            else, mode="interactive"; end
        end

        function saveFailedVerificationDiagnostics(obj)
            obj.synchronizeOperatorMetadata();
            try, obj.saveWorkingCandidate();
            catch exception, obj.recordError(exception); end
        end

        function verifyActivatedCalibration(obj,activated)
            report=validateImuCalibration(activated);
            if ~report.valid
                error('IMU:CalibrationActivationValidationFailed','%s',strjoin(report.errors,' '));
            end
            metadata=activated.metadata;
            if string(metadata.busId)~=obj.BusId
                error('IMU:CalibrationBusMismatch','Activated calibration bus ID is incorrect.');
            end
            if string(metadata.imuUid)~=string(obj.PreflightReport.uid)
                error('IMU:CalibrationDeviceMismatch','Activated calibration UID is incorrect.');
            end
            provenance={'verificationPerformed','verificationPassed'};
            if ~all(isfield(metadata,provenance))
                error('IMU:CalibrationActivationValidationFailed', ...
                    'Activated calibration is missing verification provenance.');
            end
            if obj.Options.performVerification && ...
                    ~(logical(metadata.verificationPerformed)&&logical(metadata.verificationPassed))
                error('IMU:CalibrationActivationValidationFailed', ...
                    'Activated calibration did not pass performed verification.');
            end
            candidate=obj.Calibration;
            rotationDifference=norm(activated.rotationVehicleFromSensor- ...
                candidate.rotationVehicleFromSensor,'fro');
            linearBiasDifference=norm(activated.bias.linearAccelerationSensor- ...
                candidate.bias.linearAccelerationSensor);
            angularBiasDifference=norm(activated.bias.angularVelocitySensor- ...
                candidate.bias.angularVelocitySensor);
            if rotationDifference>1e-10 || linearBiasDifference>1e-10 || ...
                    angularBiasDifference>1e-10 || ...
                    abs(activated.quality.score-candidate.quality.score)>1e-12
                error('IMU:CalibrationActivationMismatch', ...
                    'Activated calibration differs from the verified candidate.');
            end
        end

        function rollbackFromBackup(obj)
            obj.RollbackAttempted=true;
            if isfile(obj.FinalFile), obj.Dependencies.deleteFile(char(obj.FinalFile)); end
            obj.Dependencies.copyFile(char(obj.BackupFile),char(obj.FinalFile));
            restored=obj.Dependencies.loadCalibration(char(obj.FinalFile), ...
                obj.BusId,string(obj.PreflightReport.uid));
            report=validateImuCalibration(restored);
            if ~report.valid
                error('IMU:CalibrationRollbackValidationFailed','%s',strjoin(report.errors,' '));
            end
            obj.RollbackSucceeded=true;
        end

        function ensureWorkingDiagnostics(obj)
            try
                calibration=obj.Calibration; %#ok<NASGU>
                directory=fileparts(char(obj.WorkingFile));
                if ~isfolder(directory), mkdir(directory); end
                save(char(obj.WorkingFile),'calibration');
            catch exception
                obj.recordError(exception);
            end
        end

        function recordError(obj,exception)
            identifier=string(exception.identifier);
            message=string(exception.message);
            duplicate=any(obj.ErrorIdentifiers==identifier & obj.ErrorMessages==message);
            if ~duplicate
                obj.ErrorIdentifiers(end+1,1)=identifier;
                obj.ErrorMessages(end+1,1)=message;
            end
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
