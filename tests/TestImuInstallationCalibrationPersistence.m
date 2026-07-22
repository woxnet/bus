classdef TestImuInstallationCalibrationPersistence < matlab.unittest.TestCase
    methods (TestClassSetup)
        function paths(testCase)
            root=fileparts(fileparts(mfilename('fullpath'))); addpath(fullfile(root,'src'),fullfile(root,'tests'));
            testCase.addTeardown(@()rmpath(fullfile(root,'src'),fullfile(root,'tests')));
        end
    end
    methods (Test)
        function ensureDoesNotAutoCalibrate(testCase)
            folder=testCase.tempFolder(); options=getImuInstallationCalibrationWorkflowConfig();
            options.calibrationDirectory=string(folder);
            imu=MockImuBrick2(); before=imu.ReadCount;
            result=ensureImuInstallationCalibration(imu,getImuConfig().busId,options);
            testCase.verifyTrue(result.calibrationRequired); testCase.verifyEqual(imu.ReadCount,before);
        end
        function ensureLoadsValidFile(testCase)
            folder=testCase.tempFolder(); options=getImuInstallationCalibrationWorkflowConfig();
            options.calibrationDirectory=string(folder); calibration=createTestImuCalibration(false);
            calibration.metadata.workflowVersion="1.0";
            calibration.metadata.verificationPerformed=true;
            calibration.metadata.verificationPassed=true; %#ok<NASGU>
            filename=fullfile(folder,char(getImuConfig().busId+"_imu_mount.mat")); save(filename,'calibration');
            result=ensureImuInstallationCalibration(MockImuBrick2(),getImuConfig().busId,options);
            testCase.verifyTrue(result.success); testCase.verifyFalse(result.calibrationRequired);
        end
        function ensureRejectsUnverifiedLegacyByDefault(testCase)
            folder=testCase.tempFolder(); options=getImuInstallationCalibrationWorkflowConfig();
            options.calibrationDirectory=string(folder); calibration=createTestImuCalibration(false); %#ok<NASGU>
            filename=fullfile(folder,char(getImuConfig().busId+"_imu_mount.mat")); save(filename,'calibration');
            result=ensureImuInstallationCalibration(MockImuBrick2(),getImuConfig().busId,options);
            testCase.verifyFalse(result.success); testCase.verifyTrue(result.calibrationRequired);
            testCase.verifyTrue(any(contains(result.errors,"verified workflow provenance")));
        end
        function explicitLegacyMigrationOptionIsRequired(testCase)
            folder=testCase.tempFolder(); options=getImuInstallationCalibrationWorkflowConfig();
            options.calibrationDirectory=string(folder); options.AllowUnverifiedLegacyCalibration=true;
            calibration=createTestImuCalibration(false); %#ok<NASGU>
            filename=fullfile(folder,char(getImuConfig().busId+"_imu_mount.mat")); save(filename,'calibration');
            result=ensureImuInstallationCalibration(MockImuBrick2(),getImuConfig().busId,options);
            testCase.verifyTrue(result.success); testCase.verifyNotEmpty(result.warnings);
        end
        function legacyScriptDelegatesToControllerWorkflow(testCase)
            root=fileparts(fileparts(mfilename('fullpath')));
            source=strtrim(string(fileread(fullfile(root,'examples', ...
                'run_imu_installation_calibration.m'))));
            testCase.verifyEqual(source, ...
                "run(""examples/run_interactive_imu_installation_calibration.m"");");
        end
        function finalFileIsReloadedAndVerified(testCase)
            [controller,probe]=testCase.controller(testCase.tempFolder(),"none",false,false);
            result=controller.runBlocking();
            testCase.verifyTrue(result.success); testCase.verifyTrue(result.activationVerified);
            testCase.verifyEqual(probe.FinalLoadCount,1); delete(controller);
        end
        function corruptedActivatedFinalIsDetected(testCase)
            [controller,~]=testCase.controller(testCase.tempFolder(),"corrupt",false,false);
            result=controller.runBlocking();
            testCase.verifyFalse(result.success); testCase.verifyFalse(result.activationVerified);
            testCase.verifyFalse(isfile(result.finalFile)); delete(controller);
        end
        function wrongActivatedUidRollsBack(testCase)
            [controller,probe,marker]=testCase.controller(testCase.tempFolder(),"uid",true,false);
            result=controller.runBlocking();
            testCase.verifyFalse(result.success); testCase.verifyTrue(result.rollbackAttempted);
            testCase.verifyTrue(result.rollbackSucceeded); testCase.verifyEqual(probe.FinalLoadCount,2);
            restored=load(result.finalFile,'calibration');
            testCase.verifyEqual(restored.calibration.metadata.previousMarker,marker); delete(controller);
        end
        function wrongActivatedBusRollsBack(testCase)
            [controller,~,marker]=testCase.controller(testCase.tempFolder(),"bus",true,false);
            result=controller.runBlocking();
            testCase.verifyFalse(result.success); testCase.verifyTrue(result.rollbackSucceeded);
            restored=load(result.finalFile,'calibration');
            testCase.verifyEqual(restored.calibration.metadata.previousMarker,marker); delete(controller);
        end
        function corruptedFinalRestoresValidatedBackup(testCase)
            [controller,probe,marker]=testCase.controller(testCase.tempFolder(),"corrupt",true,false);
            result=controller.runBlocking();
            testCase.verifyTrue(result.rollbackAttempted); testCase.verifyTrue(result.rollbackSucceeded);
            testCase.verifyEqual(probe.FinalLoadCount,2); testCase.verifyTrue(isfile(result.backupFile));
            restored=loadImuCalibration(result.finalFile,getImuConfig().busId,getImuConfig().uid);
            testCase.verifyEqual(restored.metadata.previousMarker,marker); delete(controller);
        end
        function rollbackFailurePreservesDiagnostics(testCase)
            [controller,~,~]=testCase.controller(testCase.tempFolder(),"corrupt",true,true);
            result=controller.runBlocking();
            testCase.verifyEqual(result.errorIdentifier,"IMU:CalibrationRollbackFailed");
            testCase.verifyTrue(result.rollbackAttempted); testCase.verifyFalse(result.rollbackSucceeded);
            testCase.verifyTrue(isfile(result.backupFile)); testCase.verifyTrue(isfile(result.workingFile));
            testCase.verifyTrue(any(result.errorIdentifiers=="Test:RollbackCopyFailure"));
            testCase.verifyGreaterThanOrEqual(numel(result.errors),2); delete(controller);
        end
        function existingFinalRequiresBackup(testCase)
            folder=testCase.tempFolder();
            [controller,~,marker]=testCase.controller(folder,"none",true,false);
            options=getImuInstallationCalibrationWorkflowConfig(); %#ok<NASGU>
            % Rebuild with backup explicitly disabled.
            delete(controller);
            samples=[MockImuBrick2.createStationarySequence(1); ...
                MockImuBrick2.createForwardAccelerationSequence(1,eye(3),1)];
            imu=MockImuBrick2(samples); workflow=getImuInstallationCalibrationWorkflowConfig();
            workflow.calibrationDirectory=string(folder); workflow.enableDashboard=false;
            workflow.backupExistingCalibration=false;
            workflow.verificationStationarySeconds=.02; workflow.verificationForwardSeconds=.02;
            probe=CalibrationPersistenceProbe();
            dependencies=struct('runPreflight',@(~)testCase.preflight(), ...
                'createCalibrator',@(~,~)FakeInstallationCalibrator(), ...
                'createDashboard',@(~)[],'confirm',@(~)true, ...
                'nowUtc',@()datetime('now','TimeZone','UTC'), ...
                'createTimer',@(varargin)FakeRealtimeTimer(false,varargin{:}), ...
                'copyFile',@(source,destination)probe.copyFile(source,destination), ...
                'moveFile',@(source,destination)probe.moveFile(source,destination), ...
                'deleteFile',@delete,'loadCalibration',@loadImuCalibration,'sleep',@(~)[]);
            controller=ImuInstallationCalibrationController(imu,getImuConfig().busId,folder,workflow,dependencies);
            result=controller.runBlocking();
            testCase.verifyFalse(result.success);
            testCase.verifyEqual(result.errorIdentifier,"IMU:CalibrationBackupRequired");
            old=load(result.finalFile,'calibration');
            testCase.verifyEqual(old.calibration.metadata.previousMarker,marker); delete(controller);
        end
    end
    methods (Access=private)
        function [controller,probe,marker]=controller(testCase,folder,mutation,withOld,failRollback)
            marker="old_unchanged";
            if withOld
                calibration=createTestImuCalibration(false); calibration.metadata.previousMarker=marker; %#ok<NASGU>
                final=fullfile(folder,char(getImuConfig().busId+"_imu_mount.mat")); save(final,'calibration');
            end
            samples=[MockImuBrick2.createStationarySequence(1); ...
                MockImuBrick2.createForwardAccelerationSequence(1,eye(3),1)];
            imu=MockImuBrick2(samples); options=getImuInstallationCalibrationWorkflowConfig();
            options.calibrationDirectory=string(folder); options.enableDashboard=false;
            options.verificationStationarySeconds=.02; options.verificationForwardSeconds=.02;
            probe=CalibrationPersistenceProbe(); probe.Mutation=mutation; probe.FailRollbackCopy=failRollback;
            dependencies=struct('runPreflight',@(~)testCase.preflight(), ...
                'createCalibrator',@(~,~)FakeInstallationCalibrator(), ...
                'createDashboard',@(~)[],'confirm',@(~)true, ...
                'nowUtc',@()datetime('now','TimeZone','UTC'), ...
                'createTimer',@(varargin)FakeRealtimeTimer(false,varargin{:}), ...
                'copyFile',@(source,destination)probe.copyFile(source,destination), ...
                'moveFile',@(source,destination)probe.moveFile(source,destination), ...
                'deleteFile',@delete, ...
                'loadCalibration',@(filename,bus,uid)probe.loadCalibration(filename,bus,uid), ...
                'sleep',@(~)[]);
            controller=ImuInstallationCalibrationController(imu,getImuConfig().busId,folder,options,dependencies);
        end
        function report=preflight(~)
            config=getImuConfig(); report=struct('success',true,'uid',config.uid, ...
                'firmwareVersion',[2 0 15],'sensorFusionMode',config.sensorFusionMode, ...
                'callbackFrequencyHz',50,'callbackMissingSequences',0, ...
                'callbackOverflowDropped',0,'callbackMaximumAgeMs',1, ...
                'generatedAt',datetime('now','TimeZone','UTC'));
        end
        function folder=tempFolder(testCase)
            folder=tempname; mkdir(folder); testCase.addTeardown(@()removeFolder2(folder));
        end
    end
end
function removeFolder2(folder)
if isfolder(folder), rmdir(folder,'s'); end
end
