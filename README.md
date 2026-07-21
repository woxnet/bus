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

## Offline driving-event analysis

Recorded `ImuSessionRecorder` directories can be analyzed without access to
the IMU or Brick Daemon. The loader reads `metadata.json`, `summary.json`, and
the ordered `samples_*.mat` chunks, and rejects incomplete, inconsistent, or
gapped sessions by default. Missing-sample sessions may be inspected only with
an explicit option; processing then creates independent continuous segments so
filtering, derivatives, and event merging never cross a sequence gap.

New recordings use session format version 2. Both metadata and summary store
the actual `sampleRateHz` and `callbackPeriodMs`; these values must agree, and
the analysis refuses a rate outside `sampleRateToleranceHz` instead of silently
resampling. Version 1 recordings have no rate provenance and are rejected by
default. A known legacy rate must be supplied explicitly:

```matlab
options = struct("AllowLegacySession", true, "LegacySampleRateHz", 50);
result = analyzeImuSession("sessions/<legacy-session-id>", options);
```

Legacy identity comes from metadata and is reported as not verified per
sample. Format version 2 requires matching UID and bus ID in every sample.
Metadata and summary statuses must also agree. Consistent `incomplete`
sessions require the explicit `AllowIncomplete=true` option.
The loader preallocates numeric arrays, does not retain raw cell structures by
default, and supports `MaximumSamplesInMemory` as an explicit safety limit.
Loader callers may provide `ExpectedSampleRateHz` and
`SampleRateToleranceHz`; without an expected rate the match field is `NaN`.
Host timestamps remain diagnostic only: backwards and duplicate timestamps
are counted and warned about, while computational time remains sequence-based.
The separate 500,000-sample integration test is available with:

```matlab
startup;
addpath("tests");
memoryReport = runImuSessionLoaderMemoryTest();
assert(memoryReport.success);
```

```matlab
startup;
result = analyzeImuSession("sessions/<session-id>", struct("SavePlots", true));
assert(result.success, strjoin(result.errors, " "));
```

The analysis first writes and verifies `analysis.inprogress/`, then replaces
the final directory transactionally. A failed write returns `success=false`,
removes the staging directory, and never exposes a partial successful result.
The final output contains `analysis/result.mat`, `analysis/events.json`, and
`analysis/summary.json` inside the session directory. Diagnostic plots are
written as `analysis/diagnostic_plots.png` and `.fig`. Source recordings are
never modified. To exercise the pipeline without hardware, tests must opt in
to a session produced by `createSyntheticDrivingSession` using
`AllowSynthetic=true`.

Thresholds in `getDrivingAnalysisConfig` are preliminary engineering values:
longitudinal acceleration starts at -1.5/1.2 m/s^2 for braking/acceleration,
lateral acceleration at 1.5 m/s^2 with an 8 deg/s yaw-rate confirmation, and
vertical shocks at 2.0 m/s^2 or 2.5 m/s^3 jerk. Each detector has weaker stop
thresholds or explicit duration/merge rules to provide hysteresis.

This is an IMU-only candidate-event detector, not a final driving-quality
score. Without CAN or GNSS, it cannot reliably distinguish a stationary bus
from one moving at constant speed. Consequently, this pipeline detects dynamic
maneuvers but does not determine trip boundaries, distance travelled, events
per kilometre, or vehicle speed. It also cannot reliably distinguish driver
behavior from road geometry, potholes, vehicle vibration, sensor mounting
errors, payload, or traffic context. Thresholds require validation against
labeled real bus runs before operational use; detected events must not be
treated as safety, disciplinary, or performance conclusions.
