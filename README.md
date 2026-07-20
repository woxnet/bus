# Bus driving quality — IMU Brick 2.0

MATLAB project for collecting Tinkerforge IMU Brick 2.0 data, validating the
hardware connection, calibrating the installed sensor orientation, and
transforming measurements into bus coordinates: X forward, Y left, Z up.

## Requirements

- MATLAB R2021b or newer;
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

## Installation calibration

Only after successful hardware diagnostics, place the stationary bus on a
level surface and run calibration explicitly:

```matlab
run("examples/run_imu_installation_calibration.m");
```

Calibration is never started by `startup.m`.
