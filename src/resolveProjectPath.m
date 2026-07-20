function path = resolveProjectPath(pathValue)
%RESOLVEPROJECTPATH Resolve a relative path against the repository root.
%   Absolute paths are returned unchanged. The result does not depend on pwd.

validateattributes(pathValue, {'char','string'}, {'scalartext'});
pathValue = char(pathValue);
file = javaObject('java.io.File', pathValue);
if file.isAbsolute()
    path = string(file.getCanonicalPath());
else
    projectRoot = fileparts(fileparts(mfilename('fullpath')));
    path = string(javaObject('java.io.File', projectRoot, pathValue).getCanonicalPath());
end
end
