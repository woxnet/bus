userSentinel = 12345;
acceptanceProjectRoot = fileparts(fileparts(mfilename('fullpath')));

run(fullfile(acceptanceProjectRoot, 'startup.m'));
first = imuStartupStatus;

run(fullfile(acceptanceProjectRoot, 'startup.m'));
second = imuStartupStatus;

run(fullfile(acceptanceProjectRoot, 'startup.m'));
third = imuStartupStatus;

assert(userSentinel == 12345);
assert(first.available);
assert(second.available);
assert(third.available);
assert(~first.restartRequired);
assert(~second.restartRequired);
assert(~third.restartRequired);
assert(first.loadedSourcesMatch);
assert(second.loadedSourcesMatch);
assert(third.loadedSourcesMatch);
assert(~second.javaAddPathCalled);
assert(~third.javaAddPathCalled);
assert(isempty(second.pathsAdded));
assert(isempty(third.pathsAdded));

disp(first);
disp(second);
disp(third);

clear acceptanceProjectRoot;
