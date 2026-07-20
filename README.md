# Bus driving quality — IMU Brick 2.0

MATLAB project for collecting Tinkerforge IMU Brick 2.0 data, validating the
hardware connection, calibrating the installed sensor orientation, and
transforming measurements into bus coordinates: X forward, Y left, Z up.

## Requirements

- MATLAB R2021b or newer;
- JDK 8 or newer with `javac` available on `PATH` (the callback bridge is
  compiled to Java 8 bytecode on first use);
- Tinkerforge Brick Daemon running locally;
- official Tinkerforge Java/MATLAB bindings;
- Tinkerforge IMU Brick 2.0 with UID `6dKiM3`.

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
backlog and returns the newest sample; use `nextCallbackSample()` or
`drainCallbackSamples(maxCount)` when every sequential sample is required.

## Installation calibration

Only after successful hardware diagnostics, place the stationary bus on a
level surface and run calibration explicitly:

```matlab
run("examples/run_imu_installation_calibration.m");
```

Calibration is never started by `startup.m`.
