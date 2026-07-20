projectRoot = fileparts(mfilename('fullpath'));
jarFile = fullfile(projectRoot, 'lib', 'Tinkerforge.jar');

addpath(fullfile(projectRoot, 'src'));
addpath(fullfile(projectRoot, 'examples'));

bindingStatus = loadTinkerforgeBindings(jarFile);

clear projectRoot jarFile bindingStatus;
