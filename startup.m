projectRoot = fileparts(mfilename('fullpath'));
jarFile = fullfile(projectRoot, 'lib', 'Tinkerforge.jar');

if ~isfile(jarFile)
    error('Не найден файл Tinkerforge.jar: %s', jarFile);
end

dynamicJavaPath = javaclasspath('-dynamic');

if ~any(strcmp(dynamicJavaPath, jarFile))
    javaaddpath(jarFile);
end

addpath(fullfile(projectRoot, 'src'));

clear projectRoot jarFile dynamicJavaPath;
