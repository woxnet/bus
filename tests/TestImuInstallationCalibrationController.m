classdef TestImuInstallationCalibrationController < matlab.unittest.TestCase
    methods (TestClassSetup)
        function paths(testCase)
            root=fileparts(fileparts(mfilename('fullpath')));
            addpath(fullfile(root,'src'),fullfile(root,'tests'));
            testCase.addTeardown(@()rmpath(fullfile(root,'src'),fullfile(root,'tests')));
        end
    end
    methods (Test)
        function successfulHeadlessWorkflow(testCase)
            folder=testCase.tempFolder();
            controller=testCase.controller(folder,testCase.samples(),@(~)true,testCase.preflight(true));
            cleanup=onCleanup(@()delete(controller));
            result=controller.runBlocking();
            testCase.verifyTrue(result.success);
            testCase.verifyEqual(result.state,"READY");
            testCase.verifyTrue(isfile(result.finalFile));
            testCase.verifyFalse(isfile(result.workingFile));
            testCase.verifyEqual(result.calibration.metadata.workflowVersion,"1.0");
            testCase.verifyTrue(result.calibration.metadata.verificationPassed);
            testCase.verifyTrue(result.verificationPerformed);
            testCase.verifyTrue(result.activationAttempted);
            testCase.verifyTrue(result.activationVerified);
            testCase.verifyTrue(result.calibration.metadata.operatorConfirmedStationary);
            testCase.verifyTrue(result.calibration.metadata.operatorConfirmedForward);
            testCase.verifyTrue(result.calibration.metadata.operatorConfirmedVerificationForward);
            testCase.verifyEqual(result.calibration.metadata.operatorConfirmationMode,"test");
            testCase.verifyTrue(result.calibration.metadata.verificationPerformed);
            testCase.verifyFalse(isnat(result.calibration.metadata.verificationCompletedAt));
            testCase.verifyEqual(result.calibration.metadata.preflightCallbackFrequencyHz,50);
            testCase.verifyFalse(isnat(result.calibration.metadata.preflightGeneratedAt));
        end
        function preflightFailureStopsWorkflow(testCase)
            controller=testCase.controller(testCase.tempFolder(),testCase.samples(), ...
                @(~)true,testCase.preflight(false));
            result=controller.runBlocking();
            testCase.verifyFalse(result.success); testCase.verifyEqual(result.state,"FAILED");
            testCase.verifyEqual(controller.LastError.identifier,'IMU:CalibrationPreflightFailed');
            delete(controller);
        end
        function stationaryRefusalCancels(testCase)
            controller=testCase.controller(testCase.tempFolder(),testCase.samples(), ...
                @(~)false,testCase.preflight(true));
            result=controller.runBlocking();
            testCase.verifyTrue(result.cancelled); testCase.verifyEqual(result.state,"CANCELLED");
            delete(controller);
        end
        function repeatedStartRejected(testCase)
            controller=testCase.controller(testCase.tempFolder(),testCase.samples(), ...
                @(~)true,testCase.preflight(true));
            controller.runBlocking();
            testCase.verifyError(@()controller.runBlocking(),'IMU:CalibrationAlreadyStarted');
            controller.cancel(); controller.cancel(); delete(controller);
        end
        function activeStreamRequiresExclusiveAccess(testCase)
            imu=MockImuBrick2(testCase.samples()); imu.start(20);
            options=testCase.options(testCase.tempFolder());
            controller=ImuInstallationCalibrationController(imu,getImuConfig().busId, ...
                options.calibrationDirectory,options,testCase.dependencies(testCase.preflight(true),@(~)true));
            result=controller.runBlocking();
            testCase.verifyEqual(controller.LastError.identifier,'IMU:CalibrationRequiresExclusiveAccess');
            testCase.verifyFalse(result.success); delete(controller); imu.stop();
        end
        function stopOptionCannotStopMonitor(testCase)
            imu=MockImuBrick2(testCase.samples()); imu.claimStreamOwner("RealtimeDrivingMonitor"); imu.start(20);
            options=testCase.options(testCase.tempFolder()); options.StopExistingStream=true;
            controller=ImuInstallationCalibrationController(imu,getImuConfig().busId, ...
                options.calibrationDirectory,options,testCase.dependencies(testCase.preflight(true),@(~)true));
            result=controller.runBlocking();
            testCase.verifyFalse(result.success); testCase.verifyTrue(imu.IsStreaming);
            testCase.verifyEqual(imu.StreamOwner,"RealtimeDrivingMonitor");
            delete(controller); imu.stop();
        end
        function callbackFailureIsContained(testCase)
            controller=testCase.controller(testCase.tempFolder(),testCase.samples(), ...
                @(~)true,testCase.preflight(true));
            controller.OnProgress=@(~,~)error('Test:Callback','Injected callback failure.');
            result=controller.runBlocking();
            testCase.verifyTrue(result.success); delete(controller);
        end
        function successfulReplacementCreatesBackup(testCase)
            folder=testCase.tempFolder(); final=fullfile(folder,char(getImuConfig().busId+"_imu_mount.mat"));
            calibration=createTestImuCalibration(false); calibration.metadata.previousMarker="old"; %#ok<NASGU>
            save(final,'calibration');
            controller=testCase.controller(folder,testCase.samples(),@(~)true,testCase.preflight(true));
            result=controller.runBlocking();
            testCase.verifyTrue(result.success); testCase.verifyTrue(isfile(result.backupFile));
            old=load(result.backupFile,'calibration');
            testCase.verifyEqual(old.calibration.metadata.previousMarker,"old");
            delete(controller);
        end
        function failedAtomicMovePreservesOldCalibration(testCase)
            folder=testCase.tempFolder(); final=fullfile(folder,char(getImuConfig().busId+"_imu_mount.mat"));
            calibration=createTestImuCalibration(false); calibration.metadata.previousMarker="old"; %#ok<NASGU>
            save(final,'calibration');
            imu=MockImuBrick2(testCase.samples()); options=testCase.options(folder);
            dependencies=testCase.dependencies(testCase.preflight(true),@(~)true);
            dependencies.moveFile=@(~,~)error('Test:MoveFailure','Injected atomic move failure.');
            controller=ImuInstallationCalibrationController(imu,getImuConfig().busId,folder,options,dependencies);
            result=controller.runBlocking();
            testCase.verifyFalse(result.success); testCase.verifyTrue(isfile(final));
            old=load(final,'calibration'); testCase.verifyEqual(old.calibration.metadata.previousMarker,"old");
            testCase.verifyFalse(isfile(result.workingFile)); delete(controller);
        end
        function cancelDuringStationaryVerification(testCase)
            [controller,imu]=testCase.cancellableController(testCase.tempFolder());
            imu.OnRead=@(count)cancelOnRead(controller,count,2);
            result=controller.runBlocking();
            testCase.verifyCancelledWithoutActivation(result); delete(controller);
        end
        function cancelBeforeForwardVerification(testCase)
            [controller,~]=testCase.cancellableController(testCase.tempFolder());
            controller.OnStateChanged=@(source,status)cancelAtState(source,status, ...
                "OPERATOR_CONFIRMATION",.94,.96);
            result=controller.runBlocking();
            testCase.verifyCancelledWithoutActivation(result); delete(controller);
        end
        function cancelDuringForwardVerification(testCase)
            [controller,imu]=testCase.cancellableController(testCase.tempFolder());
            imu.OnRead=@(count)cancelOnRead(controller,count,6);
            result=controller.runBlocking();
            testCase.verifyCancelledWithoutActivation(result); delete(controller);
        end
        function cancelAfterVerificationBeforeSave(testCase)
            [controller,~]=testCase.cancellableController(testCase.tempFolder());
            controller.OnProgress=@(source,status)cancelWhenVerificationComplete(source,status);
            result=controller.runBlocking();
            testCase.verifyCancelledWithoutActivation(result); delete(controller);
        end
        function cancelAfterBackupBeforeActivation(testCase)
            folder=testCase.tempFolder(); final=fullfile(folder,char(getImuConfig().busId+"_imu_mount.mat"));
            calibration=createTestImuCalibration(false); calibration.metadata.previousMarker="old"; %#ok<NASGU>
            save(final,'calibration');
            [controller,~]=testCase.cancellableController(folder);
            controller.OnStateChanged=@(source,status)cancelAtState(source,status,"SAVING",.985,1);
            result=controller.runBlocking();
            testCase.verifyTrue(result.cancelled); testCase.verifyFalse(result.activationAttempted);
            old=load(final,'calibration'); testCase.verifyEqual(old.calibration.metadata.previousMarker,"old");
            testCase.verifyFalse(isfile(result.workingFile)); delete(controller);
        end
        function disabledConfirmationAndVerificationAreTruthful(testCase)
            folder=testCase.tempFolder(); imu=MockImuBrick2(); options=testCase.options(folder);
            options.requireOperatorConfirmation=false; options.performVerification=false;
            controller=ImuInstallationCalibrationController(imu,getImuConfig().busId,folder, ...
                options,testCase.dependencies(testCase.preflight(true),@(~)true));
            result=controller.runBlocking(); metadata=result.calibration.metadata;
            testCase.verifyTrue(result.success); testCase.verifyFalse(result.verificationPerformed);
            testCase.verifyFalse(metadata.verificationPerformed); testCase.verifyFalse(metadata.verificationPassed);
            testCase.verifyTrue(isnan(metadata.verificationScore)); testCase.verifyTrue(isnat(metadata.verificationCompletedAt));
            testCase.verifyFalse(metadata.operatorConfirmedStationary);
            testCase.verifyFalse(metadata.operatorConfirmedForward);
            testCase.verifyFalse(metadata.operatorConfirmedVerificationForward);
            testCase.verifyEqual(metadata.operatorConfirmationMode,"disabled"); delete(controller);
        end
        function failedVerificationWorkingMetadataIsTruthful(testCase)
            folder=testCase.tempFolder(); samples=[MockImuBrick2.createStationarySequence(1); ...
                MockImuBrick2.createForwardAccelerationSequence(1,eye(3),-1)];
            imu=MockImuBrick2(samples); options=testCase.options(folder); options.keepFailedWorkingFiles=true;
            controller=ImuInstallationCalibrationController(imu,getImuConfig().busId,folder,options, ...
                testCase.dependencies(testCase.preflight(true),@(~)true));
            result=controller.runBlocking(); testCase.verifyFalse(result.success);
            testCase.verifyTrue(isfile(result.workingFile));
            diagnostic=loadImuCalibration(result.workingFile,getImuConfig().busId,getImuConfig().uid);
            testCase.verifyTrue(diagnostic.metadata.verificationPerformed);
            testCase.verifyFalse(diagnostic.metadata.verificationPassed);
            testCase.verifyFalse(isnat(diagnostic.metadata.verificationCompletedAt)); delete(controller);
        end
        function dashboardConfirmationUsesControllerDecision(testCase)
            folder=testCase.tempFolder(); imu=MockImuBrick2(testCase.samples()); options=testCase.options(folder);
            options.enableDashboard=true;
            dependencies=testCase.dependencies(testCase.preflight(true), ...
                @(~)error('Test:ModalUsed','Modal confirmation must not be used.'));
            controller=ImuInstallationCalibrationController(imu,getImuConfig().busId,folder,options,dependencies);
            controller.OnStateChanged=@(source,status)confirmDashboardStep(source,status);
            result=controller.runBlocking();
            testCase.verifyTrue(result.success); testCase.verifyTrue(result.calibration.metadata.operatorConfirmedStationary);
            testCase.verifyTrue(result.calibration.metadata.operatorConfirmedForward);
            testCase.verifyTrue(result.calibration.metadata.operatorConfirmedVerificationForward); delete(controller);
        end
    end
    methods (Access=private)
        function controller=controller(testCase,folder,samples,confirm,preflight)
            imu=MockImuBrick2(samples);
            options=testCase.options(folder);
            controller=ImuInstallationCalibrationController(imu,getImuConfig().busId, ...
                folder,options,testCase.dependencies(preflight,confirm));
        end
        function options=options(~,folder)
            options=getImuInstallationCalibrationWorkflowConfig();
            options.calibrationDirectory=string(folder); options.enableDashboard=false;
            options.verificationStationarySeconds=.02; options.verificationForwardSeconds=.02;
        end
        function [controller,imu]=cancellableController(testCase,folder)
            stationary=MockImuBrick2.createStationarySequence(4);
            forward=MockImuBrick2.createForwardAccelerationSequence(4,eye(3),1);
            imu=MockImuBrick2([stationary;forward]); options=testCase.options(folder);
            options.verificationStationarySeconds=.08; options.verificationForwardSeconds=.08;
            controller=ImuInstallationCalibrationController(imu,getImuConfig().busId, ...
                folder,options,testCase.dependencies(testCase.preflight(true),@(~)true));
        end
        function verifyCancelledWithoutActivation(testCase,result)
            testCase.verifyTrue(result.cancelled); testCase.verifyEqual(result.state,"CANCELLED");
            testCase.verifyFalse(result.activationAttempted); testCase.verifyFalse(result.activationVerified);
            testCase.verifyFalse(isfile(result.finalFile)); testCase.verifyFalse(isfile(result.workingFile));
        end
        function dependencies=dependencies(~,preflight,confirm)
            dependencies=struct('runPreflight',@(~)preflight, ...
                'createCalibrator',@(~,~)FakeInstallationCalibrator(), ...
                'createDashboard',@(~)[], 'confirm',confirm, ...
                'nowUtc',@()datetime('now','TimeZone','UTC'), ...
                'createTimer',@(varargin)FakeRealtimeTimer(false,varargin{:}), ...
                'copyFile',@copyTest,'moveFile',@moveTest,'deleteFile',@delete, ...
                'loadCalibration',@loadImuCalibration,'sleep',@(~)[]);
        end
        function report=preflight(~,success)
            config=getImuConfig();
            report=struct('success',logical(success),'uid',config.uid, ...
                'firmwareVersion',[2 0 15],'sensorFusionMode',config.sensorFusionMode, ...
                'callbackFrequencyHz',50,'callbackMissingSequences',0, ...
                'callbackOverflowDropped',0,'callbackMaximumAgeMs',1, ...
                'generatedAt',datetime('now','TimeZone','UTC'));
        end
        function samples=samples(~)
            samples=[MockImuBrick2.createStationarySequence(1); ...
                MockImuBrick2.createForwardAccelerationSequence(1,eye(3),1)];
        end
        function folder=tempFolder(testCase)
            folder=tempname; mkdir(folder); testCase.addTeardown(@()removeFolder(folder));
        end
    end
end
function cancelOnRead(controller,count,target)
if count==target, controller.cancel(); end
end
function cancelAtState(controller,status,state,minimum,maximum)
if status.state==state && status.progress>=minimum && status.progress<=maximum, controller.cancel(); end
end
function cancelWhenVerificationComplete(controller,status)
if status.phase=="verification_forward" && status.samplesRequired>0 && status.samplesRemaining==0
    controller.cancel();
end
end
function confirmDashboardStep(controller,status)
if status.state=="OPERATOR_CONFIRMATION", controller.confirmCurrentStep(); end
end
function copyTest(source,destination)
[ok,message]=copyfile(source,destination,'f'); if ~ok,error('Test:Copy',message);end
end
function moveTest(source,destination)
[ok,message]=movefile(source,destination,'f'); if ~ok,error('Test:Move',message);end
end
function removeFolder(folder)
if isfolder(folder), rmdir(folder,'s'); end
end
