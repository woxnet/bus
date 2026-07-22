classdef TestImuInstallationCalibrationDashboard < matlab.unittest.TestCase
    methods (Test)
        function dashboardContainsNoCalibrationAlgorithm(testCase)
            root=fileparts(fileparts(mfilename('fullpath')));
            source=fileread(fullfile(root,'src','ImuInstallationCalibrationDashboard.m'));
            testCase.verifyNotEmpty(strfind(source,'Start')); %#ok<STRIFCND>
            testCase.verifyNotEmpty(strfind(source,'Confirm')); %#ok<STRIFCND>
            testCase.verifyNotEmpty(strfind(source,'Cancel')); %#ok<STRIFCND>
            testCase.verifyNotEmpty(strfind(source,'Close')); %#ok<STRIFCND>
            testCase.verifyEmpty(strfind(source,'buildRotation')); %#ok<STRIFCND>
            testCase.verifyEmpty(strfind(source,'calculateQuality')); %#ok<STRIFCND>
        end
    end
end
