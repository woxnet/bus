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
            options.calibrationDirectory=string(folder); calibration=createTestImuCalibration(false); %#ok<NASGU>
            filename=fullfile(folder,char(getImuConfig().busId+"_imu_mount.mat")); save(filename,'calibration');
            result=ensureImuInstallationCalibration(MockImuBrick2(),getImuConfig().busId,options);
            testCase.verifyTrue(result.success); testCase.verifyFalse(result.calibrationRequired);
        end
    end
    methods (Access=private)
        function folder=tempFolder(testCase)
            folder=tempname; mkdir(folder); testCase.addTeardown(@()removeFolder2(folder));
        end
    end
end
function removeFolder2(folder)
if isfolder(folder), rmdir(folder,'s'); end
end
