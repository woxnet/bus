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
Callback sequence and received/dropped counters are monotonic only within one
callback session. Clearing the queue or restarting the stream calls
`beginSession`, which resets that session's sequence and counters.

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
run("examples/run_interactive_imu_installation_calibration.m");
```

The workflow explicitly performs hardware preflight, two operator-confirmed
manoeuvres, quality validation, an independent verification pass, a verified
working-file reload, and atomic activation. Calibration is never started by
`startup.m`, `ImuBrick2`, `RealtimeDrivingMonitor`, or because a file is
missing. A running callback stream must be stopped explicitly before starting.

The candidate is first written as
`calibration/<bus-id>_imu_mount.inprogress.mat`. A valid existing final file
remains active until the candidate passes verification. Successful replacement
copies the previous file to `calibration/archive/` with a UTC timestamp. Failed
and cancelled workflows remove the working file by default and preserve the
old final calibration.

Activation is not considered successful until the final MAT-file is reloaded,
validated against bus ID and IMU UID, and compared with the verified candidate
rotation, biases, and quality score. If activation fails after a backup was
created, the controller restores and validates that backup. A rollback failure
preserves both the backup and working candidate for manual recovery.

Recalibration is mandatory after moving or replacing the IMU, loosening its
mount, changing enclosure orientation, repairing the mounting surface, or a
material degradation of verification metrics.

Verification checks level stationary gravity, stationary linear acceleration
and angular rate, then a separate smooth straight-forward acceleration. It
only applies the candidate transform and never recalculates the rotation.
Because this is IMU-only, the operator must perform an actual forward
acceleration rather than backward braking; without CAN or GNSS the system
cannot independently prove the direction of travel. A negative longitudinal
verification result is rejected rather than silently flipping the matrix.

With physical hardware and a prepared vehicle, run the non-CI acceptance:

```matlab
run("examples/run_installation_calibration_hardware_acceptance.m");
```

To run installation calibration, the standalone IMU acceptance, and the
real-time monitor acceptance with one combined MAT/JSON summary, use:

```matlab
run("examples/run_full_imu_hardware_acceptance.m");
```

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

## Real-time driving-event monitor

Run `startup`, complete the hardware preflight, and create a real (not
synthetic) installation calibration before starting the online monitor:

```matlab
run("examples/run_realtime_driving_monitor.m");
```

`RealtimeDrivingMonitor` is the only consumer of the IMU callback FIFO. It
drains samples in sequence order, applies the mount calibration, and updates
bounded causal EMA filters and stateful candidate detectors. This differs
intentionally from the offline zero-phase filter, which can use future samples;
online event boundaries can therefore lag the offline result slightly.

The monitor reports braking, acceleration, left/right turn, and vertical-shock
candidates through `OnEventStarted` and `OnEventCompleted`. `OnSample`,
`OnWarning`, `OnError`, and `OnStopped` support other integrations. The live
dashboard is throttled independently of detection. Optional session recording
uses the recorder's external mode, so it receives each already-drained sample
without reading the FIFO a second time. Stop a running instance with
`summary = monitor.stop()`.

This mode is IMU-only: it does not determine speed, trip boundaries, traffic
context, or whether a maneuver is caused by the driver or the road. It produces
candidate events and data-quality diagnostics, not a driving-quality score.
