classdef TestImuAcquisition < matlab.unittest.TestCase
%TESTIMUACQUISITION Hardware-independent acquisition and persistence tests.
    properties
        TemporaryDirectory
    end

    methods (TestClassSetup)
        function setup(testCase)
            root = fileparts(fileparts(mfilename('fullpath')));
            addpath(fullfile(root, 'src'));
            testCase.TemporaryDirectory = tempname;
            mkdir(testCase.TemporaryDirectory);
            testCase.addTeardown(@()rmdir(testCase.TemporaryDirectory, 's'));
        end
    end

    methods (Test)
        function syntheticCalibrationRejectedByDefault(testCase)
            calibration = testCase.calibration(true);
            sample = MockImuBrick2.makeSample([0 0 -9.81], [0 0 0], [0 0 0]);
            testCase.verifyFalse(validateImuCalibration(calibration).valid);
            testCase.verifyError(@()applyMountCalibration(sample, calibration), ...
                'IMU:InvalidCalibrationFile');
            testCase.verifyError(@()ImuSessionRecorder( ...
                MockImuBrick2(), calibration), 'IMU:InvalidCalibrationFile');
            accepted = validateImuCalibration(calibration, ...
                'AllowSynthetic', true);
            testCase.verifyTrue(accepted.valid);
        end

        function calibrationRequiresSuccessfulPreflight(testCase)
            testCase.verifyError(@()runImuInstallationCalibration( ...
                MockImuBrick2(), "bus", testCase.TemporaryDirectory), ...
                'IMU:PreflightRequired');
        end

        function calibrationRejectsWrongOrExpiredPreflight(testCase)
            config = getImuConfig();
            report = struct('success', true, 'uid', "wrong", ...
                'generatedAt', datetime('now', 'TimeZone', 'UTC'));
            testCase.verifyError(@()runImuInstallationCalibration( ...
                MockImuBrick2(), config.busId, testCase.TemporaryDirectory, report), ...
                'IMU:PreflightDeviceMismatch');
            report.uid = config.uid;
            report.generatedAt = datetime('now', 'TimeZone', 'UTC') - minutes(6);
            testCase.verifyError(@()runImuInstallationCalibration( ...
                MockImuBrick2(), config.busId, testCase.TemporaryDirectory, report), ...
                'IMU:PreflightExpired');
        end

        function syntheticCalibrationLoadRequiresPermission(testCase)
            calibration = testCase.calibration(true);
            filename = fullfile(testCase.TemporaryDirectory, 'synthetic.mat');
            save(filename, 'calibration');
            testCase.verifyError(@()loadImuCalibration(filename), ...
                'IMU:InvalidCalibrationFile');
            loaded = loadImuCalibration(filename, 'AllowSynthetic', true);
            testCase.verifyTrue(loaded.metadata.synthetic);
        end

        function recorderWritesBoundedChunksWithoutDuplicates(testCase)
            imu = MockImuBrick2();
            imu.DuplicateCallbackAt = 3;
            options = struct('directory', testCase.TemporaryDirectory, ...
                'chunkSize', 3, 'maxPollSamples', 32, 'callbackPeriodMs', 1);
            recorder = ImuSessionRecorder(imu, testCase.calibration(false), options);
            recorder.start(); pause(0.012); recorder.poll();
            session = recorder.stop();
            testCase.verifyGreaterThan(session.samplesWritten, 3);
            testCase.verifyEqual(session.duplicateSamples, 1);
            chunks = dir(fullfile(char(session.directory), 'samples_*.mat'));
            testCase.verifyGreaterThan(numel(chunks), 1);
            metadata = jsondecode(fileread(fullfile(char(session.directory), ...
                'metadata.json')));
            summary = jsondecode(fileread(fullfile(char(session.directory), ...
                'summary.json')));
            testCase.verifyEqual(metadata.sessionFormatVersion, 2);
            testCase.verifyEqual(summary.sessionFormatVersion, 2);
            testCase.verifyEqual(metadata.sampleRateHz, 1000 / options.callbackPeriodMs);
            testCase.verifyEqual(metadata.callbackPeriodMs, options.callbackPeriodMs);
            testCase.verifyEqual(summary.sampleRateHz, metadata.sampleRateHz);
            for index = 1:numel(chunks)
                contents = load(fullfile(chunks(index).folder, chunks(index).name));
                testCase.verifyLessThanOrEqual(numel(contents.sensorSamples), 3);
                sequences = cellfun(@(sample)double(sample.sequenceNumber), ...
                    contents.sensorSamples);
                testCase.verifyEqual(numel(unique(sequences)), numel(sequences));
            end
        end

        function recorderRecordsSequenceGaps(testCase)
            imu = MockImuBrick2(); imu.CallbackSequenceStep = 2;
            options = struct('directory', testCase.TemporaryDirectory, ...
                'chunkSize', 4, 'maxPollSamples', 32, 'callbackPeriodMs', 1);
            recorder = ImuSessionRecorder(imu, testCase.calibration(false), options);
            recorder.start(); pause(0.008); recorder.poll();
            session = recorder.stop();
            testCase.verifyGreaterThan(session.missingSamples, 0);
            testCase.verifyNotEmpty(session.gaps);
        end

        function abandonedRecorderRemainsMarkedIncomplete(testCase)
            imu = MockImuBrick2();
            options = struct('directory', testCase.TemporaryDirectory, ...
                'chunkSize', 3, 'maxPollSamples', 32, 'callbackPeriodMs', 1);
            recorder = ImuSessionRecorder(imu, testCase.calibration(false), options);
            recorder.start(); pause(0.004); recorder.poll();
            working = recorder.WorkingDirectory;
            delete(recorder);
            metadata = jsondecode(fileread(fullfile(char(working), 'metadata.json')));
            testCase.verifyEqual(string(metadata.status), "incomplete");
            testCase.verifyTrue(isfolder(working));
        end

        function shortAcceptanceSavesReports(testCase)
            report = runImuHardwareAcceptance(MockImuBrick2(), 0.3, ...
                testCase.TemporaryDirectory);
            testCase.verifyTrue(report.success);
            testCase.verifyEqual(report.missing, 0);
            testCase.verifyEqual(report.overflowDropped, 0);
            testCase.verifyTrue(isfile(report.matFile));
            testCase.verifyTrue(isfile(report.jsonFile));
        end
    end

    methods (Access = private)
        function calibration = calibration(~, synthetic)
            config = getImuConfig();
            quality = struct('valid', true, 'score', 1, ...
                'gravityMagnitude', 9.81, 'gravityDirectionStdDeg', 0, ...
                'forwardCoherence', 1, 'forwardAccelerationMean', 1, ...
                'forwardAccelerationStd', 0, 'orthogonalityError', 0, ...
                'determinant', 1, 'stationarySampleCount', 10, ...
                'forwardSampleCount', 10);
            metadata = struct('busId', config.busId, 'imuUid', config.uid, ...
                'deviceIdentifier', 18, 'firmwareVersion', [2 0 15], ...
                'sensorFusionMode', config.sensorFusionMode, ...
                'sampleRateHz', config.sampleRateHz, ...
                'algorithmVersion', "2.0", 'synthetic', logical(synthetic));
            calibration = struct('version', 2, ...
                'createdAt', datetime('now', 'TimeZone', 'UTC'), ...
                'axisConvention', 'X forward, Y left, Z up', ...
                'rotationVehicleFromSensor', eye(3), ...
                'bias', struct('linearAccelerationSensor', zeros(3,1), ...
                    'angularVelocitySensor', zeros(3,1)), ...
                'sensorAxes', struct('forward', [1;0;0], ...
                    'left', [0;1;0], 'up', [0;0;1]), ...
                'quality', quality, 'configuration', struct(), ...
                'metadata', metadata);
        end
    end
end
