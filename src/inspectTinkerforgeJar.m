function info = inspectTinkerforgeJar(filename)
%INSPECTTINKERFORGEJAR Inspect existence, size and ZIP/JAR signature.
%   INFO = INSPECTTINKERFORGEJAR(FILENAME) returns INFO.exists,
%   INFO.fileSizeBytes and INFO.signatureValid without throwing for a
%   missing, empty or malformed file.

info = struct('exists', false, 'fileSizeBytes', 0, 'signatureValid', false);
if ~(ischar(filename) || (isstring(filename) && isscalar(filename)))
    return;
end
filename = char(filename);
if ~isfile(filename), return; end
details = dir(filename);
if isempty(details), return; end
info.exists = true;
info.fileSizeBytes = double(details(1).bytes);
if info.fileSizeBytes < 2, return; end

fileId = fopen(filename, 'rb');
if fileId < 0, return; end
cleanup = onCleanup(@()fclose(fileId));
signature = fread(fileId, 2, '*uint8');
info.signatureValid = numel(signature) == 2 && ...
    signature(1) == uint8('P') && signature(2) == uint8('K');
clear cleanup;
end
