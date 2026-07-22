classdef TestBusImuAcceptanceSummary < matlab.unittest.TestCase
    methods(TestClassSetup)
        function setup(~)
            root=fileparts(fileparts(mfilename('fullpath')));
            addpath(fullfile(root,'src'),fullfile(root,'tests'));
        end
    end
    methods(Test)
        function matchingReportsPassAndJsonRoundTrips(testCase)
            calibrationFile=[tempname '.mat']; calibration=1; %#ok<NASGU>
            save(calibrationFile,'calibration'); testCase.addTeardown(@()deleteIfFile(calibrationFile));
            [calibrationReport,runtimeReport,realtimeReport]=testCase.reports(calibrationFile);
            summary=summarizeBusImuAcceptance(calibrationReport,runtimeReport,realtimeReport);
            testCase.verifyTrue(summary.success);
            fields={'commitMatch','uidMatch','busIdMatch','sensorFusionModeMatch', ...
                'calibrationFileExists','calibrationVerified','runtimeSuccess','realtimeSuccess', ...
                'runtimeTailComplete','runtimeBufferEmpty'};
            for index=1:numel(fields), testCase.verifyTrue(summary.(fields{index})); end
            jsonFile=[tempname '.json']; testCase.addTeardown(@()deleteIfFile(jsonFile));
            fileId=fopen(jsonFile,'w'); testCase.assertGreaterThanOrEqual(fileId,0);
            cleanup=onCleanup(@()fclose(fileId)); fprintf(fileId,'%s',jsonencode(summary)); clear cleanup;
            decoded=jsondecode(fileread(jsonFile));
            testCase.verifyTrue(decoded.success);
            testCase.verifyTrue(all(isfield(decoded,fields)));
        end

        function commitUidBusAndFusionMismatchesAreDetected(testCase)
            calibrationFile=[tempname '.mat']; calibration=1; %#ok<NASGU>
            save(calibrationFile,'calibration'); testCase.addTeardown(@()deleteIfFile(calibrationFile));
            [calibrationReport,runtimeReport,realtimeReport]=testCase.reports(calibrationFile);
            runtimeReport.commit="other"; runtimeReport.uid="other";
            realtimeReport.busId="other"; realtimeReport.sensorFusionMode=1;
            summary=summarizeBusImuAcceptance(calibrationReport,runtimeReport,realtimeReport);
            testCase.verifyFalse(summary.success); testCase.verifyFalse(summary.commitMatch);
            testCase.verifyFalse(summary.uidMatch); testCase.verifyFalse(summary.busIdMatch);
            testCase.verifyFalse(summary.sensorFusionModeMatch);
        end

        function verifiedCalibrationAndAllPhasesAreMandatory(testCase)
            [calibrationReport,runtimeReport,realtimeReport]=testCase.reports("missing.mat");
            calibrationReport.verification.success=false; runtimeReport.success=false;
            realtimeReport.success=false;
            summary=summarizeBusImuAcceptance(calibrationReport,runtimeReport,realtimeReport);
            testCase.verifyFalse(summary.success);
            testCase.verifyFalse(summary.calibrationFileExists);
            testCase.verifyFalse(summary.calibrationVerified);
            testCase.verifyFalse(summary.runtimeSuccess);
            testCase.verifyFalse(summary.realtimeSuccess);
        end
        function incompleteRuntimeTailIsRejected(testCase)
            calibrationFile=[tempname '.mat']; calibration=1; %#ok<NASGU>
            save(calibrationFile,'calibration'); testCase.addTeardown(@()deleteIfFile(calibrationFile));
            [calibrationReport,runtimeReport,realtimeReport]=testCase.reports(calibrationFile);
            runtimeReport.samplesReadMatchesReceived=false;
            summary=summarizeBusImuAcceptance(calibrationReport,runtimeReport,realtimeReport);
            testCase.verifyFalse(summary.success);
            testCase.verifyFalse(summary.runtimeTailComplete);
            runtimeReport.samplesReadMatchesReceived=true;
            runtimeReport.stopDrainTimedOut=true;
            summary=summarizeBusImuAcceptance(calibrationReport,runtimeReport,realtimeReport);
            testCase.verifyFalse(summary.runtimeTailComplete);
            runtimeReport.stopDrainTimedOut=false; runtimeReport.finalBufferedSamples=1;
            summary=summarizeBusImuAcceptance(calibrationReport,runtimeReport,realtimeReport);
            testCase.verifyFalse(summary.runtimeBufferEmpty);
            runtimeReport=rmfield(runtimeReport,'stopDrainTimedOut');
            summary=summarizeBusImuAcceptance(calibrationReport,runtimeReport,realtimeReport);
            testCase.verifyFalse(summary.runtimeTailComplete);
        end
        function hardwareReportProducersExposeIdentityContract(testCase)
            root=fileparts(fileparts(mfilename('fullpath')));
            files={fullfile(root,'src','runInstallationCalibrationHardwareAcceptance.m'), ...
                fullfile(root,'src','runImuHardwareAcceptance.m'), ...
                fullfile(root,'src','runRealtimeHardwareAcceptance.m')};
            required=["commit" "uid" "busId" "firmwareVersion" "sensorFusionMode"];
            for file=files
                source=string(fileread(file{1}));
                for field=required, testCase.verifyTrue(contains(source,field)); end
            end
        end
    end
    methods(Access=private)
        function [calibrationReport,runtimeReport,realtimeReport]=reports(~,calibrationFile)
            common=struct('success',true,'commit',"abc123",'uid',"imu", ...
                'busId',"bus",'firmwareVersion',[2 0 15],'sensorFusionMode',2);
            calibrationReport=common; calibrationReport.calibrationFile=string(calibrationFile);
            calibrationReport.verification=struct('success',true);
            runtimeReport=common;
            runtimeReport.samplesReadMatchesReceived=true;
            runtimeReport.stopDrainTimedOut=false;
            runtimeReport.finalBufferedSamples=0;
            realtimeReport=common;
        end
    end
end

function deleteIfFile(filename)
if isfile(filename), delete(filename); end
end
