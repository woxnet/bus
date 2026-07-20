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

Normal runtime loads `lib-generated/imu-callback-bridge.jar`. Developers only
need JDK 8 or newer when rebuilding it reproducibly:

```matlab
startup;
buildImuCallbackBridgeJar();
```

## Installation calibration

Only after successful hardware diagnostics, place the stationary bus on a
level surface and run calibration explicitly:

```matlab
run("examples/run_imu_installation_calibration.m");
```

Calibration is never started by `startup.m`.
