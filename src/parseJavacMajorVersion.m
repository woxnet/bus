function major = parseJavacMajorVersion(output)
%PARSEJAVACMAJORVERSION Parse both legacy 1.8 and modern javac versions.
token = regexp(char(output), 'javac\s+([^\s]+)', 'tokens', 'once');
if isempty(token)
    error('IMU:JavaCompilerUnavailable', ...
        'Unable to determine javac version from: %s', output);
end
parts = split(string(token{1}), '.');
first = str2double(parts(1));
if first == 1 && numel(parts) >= 2
    major = str2double(parts(2));
else
    major = first;
end
if ~isfinite(major) || major < 8
    error('IMU:JavaCompilerUnavailable', 'JDK 8 or newer is required.');
end
end
