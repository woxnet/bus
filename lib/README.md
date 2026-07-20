# Tinkerforge MATLAB bindings

The official Tinkerforge Java/MATLAB bindings are not distributed by this
project. Obtain `Tinkerforge.jar` from Tinkerforge and install it locally at:

```text
lib/Tinkerforge.jar
```

From MATLAB, the recommended installation command is:

```matlab
startup;
setupTinkerforgeBindings("C:/path/to/Tinkerforge.jar");
```

The installer checks that the source is non-empty, has a ZIP/JAR signature,
copies it safely, adds it to the dynamic Java path, and verifies the required
Tinkerforge classes.
