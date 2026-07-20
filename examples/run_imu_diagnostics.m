projectRoot = fileparts(fileparts(mfilename('fullpath')));
run(fullfile(projectRoot, 'startup.m'));

report = diagnoseImuBrick2();
disp(report);

if ~report.success
    fprintf("\nОшибки диагностики:\n");

    for index = 1:numel(report.errors)
        fprintf("  - %s\n", report.errors(index));
    end

    error( ...
        "IMU:DiagnosticsFailed", ...
        "Диагностика IMU Brick 2.0 не пройдена.");
end

fprintf("\nДиагностика IMU успешно пройдена.\n");
fprintf("UID: %s\n", report.uid);
fprintf("Получено отсчётов: %d\n", report.samplesRead);
fprintf("Частота: %.2f Гц\n", report.averageReadFrequencyHz);
fprintf("Гравитация: %.3f м/с²\n", report.meanGravityMagnitude);
fprintf("Температура: %.1f °C\n", report.meanTemperature);

clear projectRoot;
