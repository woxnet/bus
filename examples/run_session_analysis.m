projectRoot = fileparts(fileparts(mfilename('fullpath')));
run(fullfile(projectRoot, 'startup.m'));

sessionDirectory = "sessions/<session-id>";
result = analyzeImuSession(sessionDirectory, struct('SavePlots', true));
assert(result.success, strjoin(result.errors, ' '));

disp(result.eventCounts);
disp(result.events);

clear projectRoot;
