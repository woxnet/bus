classdef TestImuMountCalibrator < matlab.unittest.TestCase
%TESTIMUMOUNTCALIBRATOR Hardware-independent installation calibration tests.
    methods (TestClassSetup)
        function addSourcePath(testCase)
            root = fileparts(fileparts(mfilename('fullpath')));
            addpath(fullfile(root, 'src'));
            testCase.addTeardown(@()rmpath(fullfile(root, 'src')));
        end
    end

    methods (Test)
        function identityInstallation(testCase)
            [calibration, ~] = testCase.runSuccessful(eye(3));
            testCase.verifyLessThan(norm(calibration.rotationVehicleFromSensor - eye(3), 'fro'), 0.03);
            transformed = applyMountCalibration(struct( ...
                'gravity', [0 0 -9.81], 'linearAcceleration', [1 0 0], ...
                'angularVelocity', [0 0 0]), calibration);
            testCase.verifyEqual(transformed.gravity, [0;0;-9.81], 'AbsTol', 1e-10);
            testCase.verifyGreaterThan(transformed.longitudinalAcceleration, 0.9);
        end

        function yawInstallation(testCase)
            angle = 90;
            expected = [cosd(angle) -sind(angle) 0; sind(angle) cosd(angle) 0; 0 0 1];
            calibration = testCase.runSuccessful(expected);
            testCase.verifyLessThan(norm(calibration.rotationVehicleFromSensor - expected, 'fro'), 0.03);
        end

        function rollPitchInstallation(testCase)
            roll = 17; pitch = -11; yaw = 23;
            Rx = [1 0 0; 0 cosd(roll) -sind(roll); 0 sind(roll) cosd(roll)];
            Ry = [cosd(pitch) 0 sind(pitch); 0 1 0; -sind(pitch) 0 cosd(pitch)];
            Rz = [cosd(yaw) -sind(yaw) 0; sind(yaw) cosd(yaw) 0; 0 0 1];
            expected = Rz * Ry * Rx;
            calibration = testCase.runSuccessful(expected);
            testCase.verifyLessThan(norm(calibration.rotationVehicleFromSensor - expected, 'fro'), 0.03);
        end

        function stationaryWindowResets(testCase)
            config = testCase.fastConfig();
            good = MockImuBrick2.createStationarySequence(4, eye(3));
            moving = MockImuBrick2.makeSample([0 0 -9.81], [1 0 0], [0 0 0]);
            rest = MockImuBrick2.createStationarySequence(8, eye(3));
            forward = MockImuBrick2.createForwardAccelerationSequence(8, eye(3), 1);
            imu = MockImuBrick2([good; moving; rest; forward]);
            calibration = ImuMountCalibrator(imu, config).run();
            testCase.verifyTrue(calibration.quality.valid);
            testCase.verifyGreaterThan(imu.ReadCount, 15);
        end

        function turningSegmentResets(testCase)
            config = testCase.fastConfig();
            stationary = MockImuBrick2.createStationarySequence(9, eye(3));
            first = MockImuBrick2.createForwardAccelerationSequence(3, eye(3), 1);
            turn = MockImuBrick2.createTurningSequence(1, eye(3), 1);
            forward = MockImuBrick2.createForwardAccelerationSequence(8, eye(3), 1);
            imu = MockImuBrick2([stationary; first; turn; forward]);
            calibration = ImuMountCalibrator(imu, config).run();
            testCase.verifyTrue(calibration.quality.valid);
            testCase.verifyGreaterThanOrEqual(imu.ReadCount, 20);
        end

        function lowCoherenceRejected(testCase)
            config = testCase.fastConfig();
            config.maxForwardDirectionDeviationDeg = 180;
            config.minForwardCoherence = 0.9;
            stationary = MockImuBrick2.createStationarySequence(9, eye(3));
            directions = [60 -60 60 -60 60 -60 60 -60];
            forward = repmat(MockImuBrick2.makeSample([0 0 -9.81], [1 0 0], [0 0 0]), 8, 1);
            for index = 1:8
                forward(index).linearAcceleration = [cosd(directions(index)) sind(directions(index)) 0];
            end
            calibrator = ImuMountCalibrator(MockImuBrick2([stationary; forward]), config);
            testCase.verifyError(@()calibrator.run(), 'IMU:CalibrationRejected');
        end

        function stationaryTimeout(testCase)
            config = testCase.fastConfig(); config.stationaryTimeout = 0.05;
            moving = MockImuBrick2.makeSample([0 0 -9.81], [1 0 0], [0 0 0]);
            calibrator = ImuMountCalibrator(MockImuBrick2(moving), config);
            testCase.verifyError(@()calibrator.run(), 'IMU:StationaryTimeout');
            testCase.verifyEqual(calibrator.State, "FAILED");
            testCase.verifyTrue(contains(calibrator.LastMessage, ...
                "continuous stationary interval"));
        end

        function forwardTimeout(testCase)
            config = testCase.fastConfig(); config.forwardTimeout = 0.05;
            stationary = MockImuBrick2.createStationarySequence(20, eye(3));
            calibrator = ImuMountCalibrator(MockImuBrick2(stationary), config);
            testCase.verifyError(@()calibrator.run(), 'IMU:ForwardTimeout');
        end

        function cancellation(testCase)
            config = testCase.fastConfig();
            imu = MockImuBrick2(MockImuBrick2.makeSample([0 0 -9.81], [1 0 0], [0 0 0]));
            calibrator = ImuMountCalibrator(imu, config);
            imu.OnRead = @(count)cancelAt(count, calibrator);
            testCase.verifyError(@()calibrator.run(), 'IMU:CalibrationCancelled');
            testCase.verifyEqual(calibrator.State, "CANCELLED");

            function cancelAt(count, target)
                if count == 3, target.cancel(); end
            end
        end

        function saveLoadAndCorruptFile(testCase)
            directory = tempname; mkdir(directory);
            cleanup = onCleanup(@()rmdir(directory, 's'));
            file = fullfile(directory, 'calibration.mat');
            [calibration, ~] = testCase.runSuccessful(eye(3), file);
            loaded = loadImuCalibration(file);
            testCase.verifyEqual(loaded.rotationVehicleFromSensor, ...
                calibration.rotationVehicleFromSensor, 'AbsTol', 1e-12);
            corrupt = fullfile(directory, 'corrupt.mat');
            unrelated = 1; save(corrupt, 'unrelated');
            testCase.verifyError(@()loadImuCalibration(corrupt), 'IMU:InvalidCalibrationFile');
        end

        function invalidConfigurationAndReadRetries(testCase)
            testCase.verifyError(@()ImuMountCalibrator(MockImuBrick2(), ...
                struct('unknownOption', 1)), 'IMU:InvalidConfiguration');
            config = testCase.fastConfig();
            stationary = MockImuBrick2.createStationarySequence(9, eye(3));
            forward = MockImuBrick2.createForwardAccelerationSequence(8, eye(3), 1);
            imu = MockImuBrick2([stationary; forward]); imu.FailureReads = [1 2];
            calibration = ImuMountCalibrator(imu, config).run();
            testCase.verifyTrue(calibration.quality.valid);
        end

        function calibrationVersionTwoMetadata(testCase)
            calibration = testCase.runSuccessful(eye(3));
            testCase.verifyEqual(calibration.version, 2);
            testCase.verifyTrue(isfield(calibration, 'metadata'));
            testCase.verifyEqual(calibration.metadata.algorithmVersion, "2.0");
        end

        function calibrationMismatchRejected(testCase)
            directory = tempname; mkdir(directory);
            cleanup = onCleanup(@()rmdir(directory, 's'));
            calibration = testCase.runSuccessful(eye(3));
            calibration.metadata.busId = "bus_a";
            calibration.metadata.imuUid = "imu_a";
            file = fullfile(directory, 'bound.mat');
            save(file, 'calibration');
            testCase.verifyError(@()loadImuCalibration(file, "bus_b", "imu_a"), ...
                'IMU:CalibrationBusMismatch');
            testCase.verifyError(@()loadImuCalibration(file, "bus_a", "imu_b"), ...
                'IMU:CalibrationDeviceMismatch');
            clear cleanup;
        end

        function legacyCalibrationRequiresExplicitPermission(testCase)
            directory = tempname; mkdir(directory);
            cleanup = onCleanup(@()rmdir(directory, 's'));
            calibration = testCase.runSuccessful(eye(3));
            calibration.version = 1;
            calibration = rmfield(calibration, 'metadata');
            file = fullfile(directory, 'legacy.mat');
            save(file, 'calibration');
            testCase.verifyError(@()loadImuCalibration(file), ...
                'IMU:InvalidCalibrationFile');
            loaded = loadImuCalibration(file, 'AllowLegacy', true);
            testCase.verifyEqual(loaded.version, 1);
            clear cleanup;
        end

        function projectPathIndependentOfPwd(testCase)
            original = pwd;
            directory = tempname; mkdir(directory);
            cleanup = onCleanup(@()restore(original, directory));
            cd(directory);
            resolved = resolveProjectPath('calibration');
            root = fileparts(fileparts(mfilename('fullpath')));
            testCase.verifyEqual(resolved, string(fullfile(root, 'calibration')));
            clear cleanup;

            function restore(folder, temporary)
                cd(folder); rmdir(temporary, 's');
            end
        end

        function orientationFieldsAreExplicit(testCase)
            calibration = testCase.runSuccessful(eye(3));
            data = struct('linearAcceleration',[0 0 0], ...
                'angularVelocity',[0 0 0], 'euler',[1 2 3], ...
                'quaternion',[1 0 0 0]);
            transformed = applyMountCalibration(data, calibration);
            testCase.verifyFalse(isfield(transformed, 'euler'));
            testCase.verifyFalse(isfield(transformed, 'quaternion'));
            testCase.verifyEqual(transformed.sensorEuler, [1 2 3]);
            testCase.verifyEqual(transformed.sensorQuaternion, [1 0 0 0]);
        end

        function calibrationRateUsesProjectConfig(testCase)
            project = getImuConfig();
            calibration = getImuCalibrationConfig();
            testCase.verifyEqual(calibration.sampleRate, project.sampleRateHz);
        end
    end

    methods (Access = private)
        function [calibration, imu] = runSuccessful(testCase, rotation, saveFile)
            if nargin < 3, saveFile = ''; end
            config = testCase.fastConfig();
            linearBias = [0.02;-0.01;0.01]; gyroBias = [0.05;-0.03;0.02];
            stationary = MockImuBrick2.createStationarySequence(9, rotation, linearBias, gyroBias);
            forward = MockImuBrick2.createForwardAccelerationSequence(8, rotation, 1, linearBias, gyroBias);
            imu = MockImuBrick2([stationary; forward]);
            calibration = ImuMountCalibrator(imu, config).run(saveFile);
        end

        function config = fastConfig(~)
            config = ImuMountCalibrator.defaultConfig();
            config.sampleRate = 200;
            config.stationaryDuration = 0.04;
            config.stationaryTimeout = 0.4;
            config.forwardAccelerationDuration = 0.04;
            config.forwardTimeout = 0.4;
            config.maximumForwardSampleGap = 0.01;
            config.readRetryDelay = 0.001;
        end
    end
end
