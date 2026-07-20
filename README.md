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

Do not commit the third-party JAR. Install an official local copy with:

```matlab
startup;
result = setupTinkerforgeBindings("C:/path/to/Tinkerforge.jar");
assert(result.success);
```

The resulting local file is `lib/Tinkerforge.jar` and is ignored by Git.

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
