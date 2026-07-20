# Tinkerforge MATLAB bindings

The official bindings are not distributed by this project. Download the
Tinkerforge MATLAB/Octave bindings archive and use the file:

```text
matlab/Tinkerforge.jar
```

Install that file locally at:

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

After replacing a JAR that MATLAB has already loaded, restart MATLAB before
continuing.
