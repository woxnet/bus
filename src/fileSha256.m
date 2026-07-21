function value = fileSha256(filename)
%FILESHA256 Return the lowercase SHA-256 digest of a file.

fileId = fopen(filename, 'rb');
if fileId < 0, error('IMU:HashInputMissing', 'Cannot read %s.', filename); end
cleanup = onCleanup(@()fclose(fileId));
bytes = fread(fileId, Inf, '*uint8');
clear cleanup;
digest = javaMethod('getInstance', 'java.security.MessageDigest', 'SHA-256');
digest.update(typecast(bytes(:), 'int8'));
raw = typecast(digest.digest(), 'uint8');
value = lower(reshape(dec2hex(raw, 2).', 1, []));
end
