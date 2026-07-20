function flags = selectJava8CompilerFlags(javacMajorVersion)
%SELECTJAVA8COMPILERFLAGS Select Java 8 bytecode flags for the active JDK.
validateattributes(javacMajorVersion, {'numeric'}, ...
    {'scalar','integer','>=',8});
if javacMajorVersion == 8
    flags = '-source 1.8 -target 1.8';
else
    flags = '--release 8';
end
end
