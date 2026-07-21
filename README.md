# Bus driving quality — IMU Brick 2.0

MATLAB project for collecting Tinkerforge IMU Brick 2.0 data, validating the
hardware connection, calibrating the installed sensor orientation, and
transforming measurements into bus coordinates: X forward, Y left, Z up.

## Requirements

- MATLAB R2021b or newer;
- the JVM bundled with MATLAB (no JDK is required for normal runtime);
- Tinkerforge Brick Daemon running locally;
- official Tinkerforge Java/MATLAB bindings;
- the configured Tinkerforge IMU Brick 2.0.

The UID and all runtime settings are defined only by `src/getImuConfig.m`.

## Install Tinkerforge bindings

Do not commit the third-party JAR. From the official Tinkerforge MATLAB/Octave
bindings archive, use exactly `matlab/Tinkerforge.jar` and install it with:

```matlab
startup;
result = setupTinkerforgeBindings("C:/path/to/Tinkerforge.jar");
assert(result.success);
```

The resulting local file is `lib/Tinkerforge.jar` and is ignored by Git.
After replacing a JAR that MATLAB has already loaded, restart MATLAB before
continuing.

## Повторный запуск startup

Run `startup` before creating `ImuBrick2`. It is idempotent, may be called
repeatedly, leaves the diagnostic structure `imuStartupStatus` in the caller
workspace, and never creates an `IPConnection` or `BrickIMUV2` object. It
verifies the code source of every required Java class. If a class is already
loaded from a different JAR, it sets
`imuStartupStatus.restartRequired = true` and does not modify the Java
classpath; close IMU objects and restart MATLAB before connecting again.
After replacing any loaded JAR, a MATLAB restart is required. A MATLAB
`not clearing java` warning means that the current process is still using
previously loaded Java classes.

Applications can enforce this precondition with `assertImuRuntimeReady()`.
Before replacing a loaded JAR, release an active acquisition object with:

```matlab
shutdownImuRuntime(imu);
clear imu;
clear java; % or restart MATLAB
```

`shutdownImuRuntime` stops acquisition, clears the callback buffer,
disconnects, and deletes the MATLAB handle. It does not clear Java itself.

## Unit tests

The tests use a mock IMU and do not require Brick Daemon or physical hardware:

```matlab
startup;
results = runtests("tests");
assertSuccess(results);
```

## Hardware diagnostics

Run diagnostics before calibration:

```matlab
startup;
report = diagnoseImuBrick2();
disp(report);
assert(report.success);
```

The IMU Brick 2.0 must run firmware 2.0.12 or newer. Firmware 2.0.11 has
an upstream callback timing bug and produces about 30 Hz when 20 ms is
configured; update it with Brick Viewer before attempting calibration. The
threshold is based on the official Tinkerforge IMU Brick 2.0 changelog:
https://raw.githubusercontent.com/Tinkerforge/imu-v2-brick/master/software/changelog

The callback bridge uses a bounded 256-sample buffer. `latest()` drops stale
backlog and returns the newest unread sample; it raises
`IMU:NoNewCallbackSample` instead of repeating an old sample. Use
`nextCallbackSample()` or
`drainCallbackSamples(maxCount)` when every sequential sample is required.
Callback sequence and received/dropped counters remain monotonic when the
queue is cleared or the stream is restarted.

Normal runtime loads `lib-generated/imu-callback-bridge-v2.jar`. Developers only
need JDK 8 or newer when rebuilding it reproducibly:

```matlab
addpath("src");
buildImuCallbackBridgeJar();
```

Each `start()` creates an isolated stream session. Statistics distinguish
buffer overflow, intentional `latest()` coalescing, and stale-session callback
drops. Diagnostic frequency and age calculations use Java monotonic time, and
the callback phase validates decoded sensor payloads rather than metadata only.

## Hardware acceptance

With the physical IMU connected, run the controlled 60-second FIFO test:

```matlab
run("examples/run_imu_hardware_acceptance.m");
```

Reports are written to ignored `artifacts/` MAT and JSON files. Long raw
sessions can be recorded with `ImuSessionRecorder`; it writes bounded MAT
chunks under ignored `sessions/` and marks interrupted sessions as incomplete.
Synthetic calibration files are rejected by validation, loading, application,
and recording unless an explicit test-only permission is supplied.

## Installation calibration

Only after successful hardware diagnostics, place the stationary bus on a
level surface and run calibration explicitly:

```matlab
run("examples/run_imu_installation_calibration.m");
```

Calibration is never started by `startup.m`.
