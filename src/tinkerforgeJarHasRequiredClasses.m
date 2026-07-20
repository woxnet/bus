function present = tinkerforgeJarHasRequiredClasses(jarFile)
%TINKERFORGEJARHASREQUIREDCLASSES Check required entries in a JAR archive.
try
    archive = javaObject('java.util.jar.JarFile', char(jarFile));
    cleanup = onCleanup(@()archive.close());
    first = archive.getEntry('com/tinkerforge/IPConnection.class');
    second = archive.getEntry('com/tinkerforge/BrickIMUV2.class');
    present = ~isempty(first) && ~isempty(second);
    clear cleanup;
catch
    present = false;
end
end
