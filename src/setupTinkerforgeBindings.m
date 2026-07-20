function result = setupTinkerforgeBindings(sourceFile)
%SETUPTINKERFORGEBINDINGS Safely install local Tinkerforge Java bindings.
%   RESULT = SETUPTINKERFORGEBINDINGS(SOURCEFILE) validates a non-empty
%   ZIP/JAR file, atomically installs it as lib/Tinkerforge.jar, adds it to
%   the Java path and verifies IPConnection and BrickIMUV2. Expected setup
%   failures are returned in RESULT.errors.

projectRoot = fileparts(fileparts(mfilename('fullpath')));
destinationFile = fullfile(projectRoot, 'lib', 'Tinkerforge.jar');
if nargin < 1, sourceFile = ""; end
result = struct('success', false, 'sourceFile', string(sourceFile), ...
    'destinationFile', string(destinationFile), 'fileSizeBytes', 0, ...
    'jarSignatureValid', false, 'javaBindingsAvailable', false, ...
    'errors', strings(0, 1));

try
    validateattributes(sourceFile, {'char','string'}, {'scalartext'});
    sourceFile = char(sourceFile);
    sourceInfo = inspectTinkerforgeJar(sourceFile);
    result.fileSizeBytes = sourceInfo.fileSizeBytes;
    result.jarSignatureValid = sourceInfo.signatureValid;
    if ~sourceInfo.exists
        result.errors(end+1, 1) = "Исходный JAR не найден: " + string(sourceFile);
        return;
    end
    if sourceInfo.fileSizeBytes <= 0
        result.errors(end+1, 1) = "Исходный JAR пуст: " + string(sourceFile);
        return;
    end
    if ~sourceInfo.signatureValid
        result.errors(end+1, 1) = "Исходный файл не имеет ZIP/JAR-сигнатуры PK.";
        return;
    end
    if ~tinkerforgeJarHasRequiredClasses(sourceFile)
        result.errors(end+1, 1) = ...
            "Исходный JAR не содержит требуемые классы Tinkerforge.";
        return;
    end

    destinationDirectory = fileparts(destinationFile);
    if ~isfolder(destinationDirectory), mkdir(destinationDirectory); end
    sameFile = strcmpi(canonicalPath(sourceFile), canonicalPath(destinationFile));
    if ~sameFile
        temporaryFile = [tempname(destinationDirectory), '.jar'];
        cleanup = onCleanup(@()deleteIfPresent(temporaryFile));
        [copied, copyMessage] = copyfile(sourceFile, temporaryFile, 'f');
        if ~copied, error('IMU:BindingsCopyFailed', '%s', copyMessage); end
        copiedInfo = inspectTinkerforgeJar(temporaryFile);
        if copiedInfo.fileSizeBytes ~= sourceInfo.fileSizeBytes || ...
                ~copiedInfo.signatureValid
            error('IMU:BindingsCopyFailed', 'Проверка временной копии JAR не пройдена.');
        end
        [moved, moveMessage] = movefile(temporaryFile, destinationFile, 'f');
        if ~moved, error('IMU:BindingsCopyFailed', '%s', moveMessage); end
        clear cleanup;
    end

    loadStatus = loadTinkerforgeBindings(destinationFile);
    result.javaBindingsAvailable = loadStatus.available;
    if ~loadStatus.available
        result.errors = [result.errors; loadStatus.errors];
    end
    result.success = result.jarSignatureValid && result.javaBindingsAvailable;
catch exception
    result.errors(end+1, 1) = string(exception.message);
end
end

function path = canonicalPath(path)
path = char(javaObject('java.io.File', path).getCanonicalPath());
end

function deleteIfPresent(filename)
if isfile(filename), delete(filename); end
end
