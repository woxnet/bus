projectRoot = fileparts(fileparts(mfilename('fullpath')));
run(fullfile(projectRoot, 'startup.m'));

report = diagnoseImuBrick2();
disp(report);

if ~report.success
    error("IMU:DiagnosticsFailed", ...
        "Диагностика IMU не пройдена.");
end

clear projectRoot;
