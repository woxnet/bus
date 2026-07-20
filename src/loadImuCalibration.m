function calibration = loadImuCalibration(filename, expectedBusId, expectedImuUid, varargin)
%LOADIMUCALIBRATION Load and validate an IMU installation calibration.
%   CALIBRATION = LOADIMUCALIBRATION(FILENAME) throws
%   IMU:InvalidCalibrationFile when the MAT-file is missing or invalid.

if nargin < 2, expectedBusId = ""; end
if nargin < 3, expectedImuUid = ""; end
if (ischar(expectedBusId) || isstring(expectedBusId)) && ...
        strcmpi(string(expectedBusId), "AllowLegacy")
    varargin = [{expectedBusId, expectedImuUid}, varargin];
    expectedBusId = "";
    expectedImuUid = "";
end
parser = inputParser;
addParameter(parser, 'AllowLegacy', false, @(value)islogical(value) && isscalar(value));
parse(parser, varargin{:});
allowLegacy = parser.Results.AllowLegacy;

try
    if ~(ischar(filename) || (isstring(filename) && isscalar(filename))) || ...
            ~isfile(filename)
        error('File does not exist.');
    end
    variables = whos('-file', filename);
    if ~any(strcmp({variables.name}, 'calibration'))
        error('Variable ''calibration'' is missing.');
    end
    contents = load(filename, 'calibration');
    calibration = contents.calibration;
    report = validateImuCalibration(calibration, allowLegacy);
    if ~report.valid
        error('%s', strjoin(report.errors, ' '));
    end
    if calibration.version == 2
        if strlength(string(expectedBusId)) > 0 && ...
                string(calibration.metadata.busId) ~= string(expectedBusId)
            error('IMU:CalibrationBusMismatch', ...
                'Calibration bus ID "%s" does not match expected "%s".', ...
                string(calibration.metadata.busId), string(expectedBusId));
        end
        if strlength(string(expectedImuUid)) > 0 && ...
                string(calibration.metadata.imuUid) ~= string(expectedImuUid)
            error('IMU:CalibrationDeviceMismatch', ...
                'Calibration IMU UID "%s" does not match expected "%s".', ...
                string(calibration.metadata.imuUid), string(expectedImuUid));
        end
    end
catch exception
    if any(strcmp(exception.identifier, {'IMU:InvalidCalibrationFile', ...
            'IMU:CalibrationBusMismatch','IMU:CalibrationDeviceMismatch'}))
        rethrow(exception);
    end
    error('IMU:InvalidCalibrationFile', 'Invalid calibration file "%s": %s', ...
        char(filename), exception.message);
end
end
