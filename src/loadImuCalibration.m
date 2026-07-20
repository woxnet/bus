function calibration = loadImuCalibration(filename)
%LOADIMUCALIBRATION Load and validate an IMU installation calibration.
%   CALIBRATION = LOADIMUCALIBRATION(FILENAME) throws
%   IMU:InvalidCalibrationFile when the MAT-file is missing or invalid.

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
    report = validateImuCalibration(calibration);
    if ~report.valid
        error('%s', strjoin(report.errors, ' '));
    end
catch exception
    if strcmp(exception.identifier, 'IMU:InvalidCalibrationFile')
        rethrow(exception);
    end
    error('IMU:InvalidCalibrationFile', 'Invalid calibration file "%s": %s', ...
        char(filename), exception.message);
end
end
