classdef TestImuStartup < matlab.unittest.TestCase
%TESTIMUSTARTUP Hardware-independent Java runtime lifecycle tests.
    properties
        ProjectRoot
        TemporaryDirectory
        JarFile
        BridgeFile
    end

    methods (TestClassSetup)
        function setup(testCase)
            testCase.ProjectRoot = fileparts(fileparts(mfilename('fullpath')));
            addpath(fullfile(testCase.ProjectRoot, 'src'));
            addpath(fullfile(testCase.ProjectRoot, 'tests'));
            testCase.TemporaryDirectory = tempname;
            mkdir(testCase.TemporaryDirectory);
            testCase.addTeardown(@()rmdir(testCase.TemporaryDirectory, 's'));
            testCase.JarFile = testCase.makeStubJar();
            testCase.BridgeFile = fullfile(testCase.TemporaryDirectory, 'bridge.jar');
            testCase.writeBytes(testCase.BridgeFile, uint8([80 75 3 4]));
        end
    end

    methods (Test)
        function firstLoadAddsBothPathsOnce(testCase)
            runtime = testCase.runtime();
            status = loadTinkerforgeBindings(testCase.JarFile, runtime.dependencies());
            testCase.verifyTrue(status.available);
            testCase.verifyEqual(runtime.AddPathCalls, 1);
            testCase.verifyEqual(numel(runtime.Paths), 2);
            testCase.verifyEqual(runtime.ConstructionCount, 0);
        end

        function repeatedLoadIsIdempotent(testCase)
            runtime = testCase.runtime();
            statuses = cell(3, 1);
            lastwarn('');
            for index = 1:3
                statuses{index} = loadTinkerforgeBindings( ...
                    testCase.JarFile, runtime.dependencies());
            end
            [~, warningIdentifier] = lastwarn;
            testCase.verifyTrue(all(cellfun(@(value)value.available, statuses)));
            testCase.verifyEqual(runtime.AddPathCalls, 1);
            testCase.verifyEmpty(warningIdentifier);
            testCase.verifyFalse(statuses{3}.classpathChangeRequired);
            testCase.verifyFalse(statuses{3}.restartRequired);
        end

        function bindingCheckDoesNotConstructIPConnection(testCase)
            source = fileread(fullfile(testCase.ProjectRoot, 'src', ...
                'loadTinkerforgeBindings.m'));
            testCase.verifyFalse(contains(source, ...
                "javaObject('com.tinkerforge.IPConnection'"));
        end

        function bindingCheckDoesNotConstructBrickImu(testCase)
            source = fileread(fullfile(testCase.ProjectRoot, 'src', ...
                'loadTinkerforgeBindings.m'));
            testCase.verifyFalse(contains(source, ...
                "javaObject('com.tinkerforge.BrickIMUV2'"));
        end

        function correctPreloadedClassesRequireNoChange(testCase)
            runtime = testCase.readyRuntime();
            status = loadTinkerforgeBindings(testCase.JarFile, runtime.dependencies());
            testCase.verifyTrue(status.jarAlreadyOnPath);
            testCase.verifyTrue(status.bridgeAlreadyOnPath);
            testCase.verifyTrue(status.loadedSourcesMatch);
            testCase.verifyEqual(runtime.AddPathCalls, 0);
        end

        function wrongTinkerforgeSourceRequiresRestart(testCase)
            runtime = testCase.readyRuntime();
            runtime.JarSource = string(fullfile(testCase.TemporaryDirectory, 'old.jar'));
            status = testCase.captureWarning(@()loadTinkerforgeBindings( ...
                testCase.JarFile, runtime.dependencies()), 'IMU:JavaRestartRequired');
            testCase.verifyTrue(status.restartRequired);
            testCase.verifyFalse(status.available);
            testCase.verifyEqual(runtime.AddPathCalls, 0);
        end

        function wrongBridgeSourceRequiresRestart(testCase)
            runtime = testCase.readyRuntime();
            runtime.BridgeSource = string(fullfile(testCase.TemporaryDirectory, 'old-bridge.jar'));
            status = testCase.captureWarning(@()loadTinkerforgeBindings( ...
                testCase.JarFile, runtime.dependencies()), 'IMU:JavaRestartRequired');
            testCase.verifyTrue(status.restartRequired);
            testCase.verifyEqual(runtime.AddPathCalls, 0);
        end

        function loadedClassesAndMissingBridgePathRequireRestart(testCase)
            runtime = testCase.runtime();
            runtime.Paths = {char(runtime.ExpectedJar)};
            runtime.loadTinkerforge(runtime.ExpectedJar);
            status = testCase.captureWarning(@()loadTinkerforgeBindings( ...
                testCase.JarFile, runtime.dependencies()), 'IMU:JavaRestartRequired');
            testCase.verifyTrue(status.classpathChangeRequired);
            testCase.verifyTrue(status.restartRequired);
            testCase.verifyEqual(runtime.AddPathCalls, 0);
        end

        function oneLoadedTinkerforgeClassBlocksClasspathMutation(testCase)
            runtime = testCase.runtime();
            runtime.LoadedClasses = "com.tinkerforge.IPConnection";
            runtime.JarSource = runtime.ExpectedJar;
            status = testCase.captureWarning(@()loadTinkerforgeBindings( ...
                testCase.JarFile, runtime.dependencies()), 'IMU:JavaRestartRequired');
            testCase.verifyTrue(status.restartRequired);
            testCase.verifyEqual(runtime.AddPathCalls, 0);
        end

        function missingJarReturnsUnavailableWithoutClasspathChange(testCase)
            runtime = testCase.runtime();
            missing = fullfile(testCase.TemporaryDirectory, 'missing.jar');
            status = testCase.captureWarning(@()loadTinkerforgeBindings( ...
                missing, runtime.dependencies()), 'IMU:TinkerforgeBindingsUnavailable');
            testCase.verifyFalse(status.available);
            testCase.verifyEqual(runtime.AddPathCalls, 0);
            testCase.verifyEqual(runtime.BuildBridgeCalls, 0);
        end

        function reportContainsRequiredFields(testCase)
            runtime = testCase.readyRuntime();
            status = loadTinkerforgeBindings(testCase.JarFile, runtime.dependencies());
            fields = ["jarAlreadyOnPath", "bridgeAlreadyOnPath", ...
                "classpathChangeRequired", "tinkerforgeClassesLoaded", ...
                "bridgeClassLoaded", "ipConnectionCodeSource", ...
                "brickImuCodeSource", "bridgeCodeSource", ...
                "loadedSourcesMatch", "restartRequired"];
            testCase.verifyTrue(all(isfield(status, fields)));
        end

        function runtimeGuardAcceptsReadyRuntime(testCase)
            runtime = testCase.readyRuntime();
            status = assertImuRuntimeReady(runtime.dependencies(), testCase.JarFile);
            testCase.verifyTrue(status.available);
        end

        function runtimeGuardRejectsConflict(testCase)
            runtime = testCase.readyRuntime();
            runtime.JarSource = string(fullfile(testCase.TemporaryDirectory, 'wrong.jar'));
            warningState = warning('off', 'IMU:JavaRestartRequired');
            cleanup = onCleanup(@()warning(warningState));
            testCase.verifyError(@()assertImuRuntimeReady( ...
                runtime.dependencies(), testCase.JarFile), 'IMU:RuntimeNotReady');
        end

        function constructorGuardPrecedesJavaConstruction(testCase)
            source = fileread(fullfile(testCase.ProjectRoot, 'src', 'ImuBrick2.m'));
            guardPosition = strfind(source, 'assertImuRuntimeReady();');
            objectPosition = strfind(source, "javaObject( ...");
            testCase.verifyNotEmpty(guardPosition);
            testCase.verifyNotEmpty(objectPosition);
            testCase.verifyLessThan(guardPosition(1), objectPosition(1));
        end

        function shutdownUsesRequiredOrder(testCase)
            log = MockShutdownLog();
            imu = MockShutdownImu(log);
            shutdownImuRuntime(imu);
            testCase.verifyEqual(log.Calls, ["stop"; "clearCallbackBuffer"; ...
                "disconnect"; "delete"]);
        end

        function shutdownRejectsInvalidObject(testCase)
            testCase.verifyError(@()shutdownImuRuntime(struct()), ...
                'IMU:InvalidRuntimeObject');
        end

        function startupLeavesStatusAndUserVariable(testCase)
            userVariable = 123;
            run(fullfile(testCase.ProjectRoot, 'startup.m'));
            testCase.verifyEqual(userVariable, 123);
            testCase.verifyTrue(exist('imuStartupStatus', 'var') == 1);
            testCase.verifyTrue(isstruct(imuStartupStatus));
            testCase.verifyFalse(exist('projectRoot', 'var') == 1);
            testCase.verifyFalse(exist('jarFile', 'var') == 1);
        end
    end

    methods (Access = private)
        function runtime = runtime(testCase)
            runtime = MockJavaRuntime(testCase.JarFile, testCase.BridgeFile);
        end

        function runtime = readyRuntime(testCase)
            runtime = testCase.runtime();
            runtime.Paths = {char(runtime.ExpectedJar); char(runtime.ExpectedBridge)};
            runtime.loadTinkerforge(runtime.ExpectedJar);
            runtime.loadBridge(runtime.ExpectedBridge);
        end

        function status = captureWarning(testCase, operation, expectedIdentifier)
            lastwarn('');
            status = operation();
            [~, identifier] = lastwarn;
            testCase.verifyEqual(identifier, expectedIdentifier);
        end

        function jarFile = makeStubJar(testCase)
            staging = fullfile(testCase.TemporaryDirectory, 'jar-content');
            package = fullfile(staging, 'com', 'tinkerforge');
            mkdir(package);
            testCase.writeBytes(fullfile(package, 'IPConnection.class'), uint8(0));
            testCase.writeBytes(fullfile(package, 'BrickIMUV2.class'), uint8(0));
            jarFile = fullfile(testCase.TemporaryDirectory, 'Tinkerforge.jar');
            zipFile = fullfile(testCase.TemporaryDirectory, 'Tinkerforge.zip');
            zip(zipFile, {'com/tinkerforge/IPConnection.class', ...
                'com/tinkerforge/BrickIMUV2.class'}, staging);
            movefile(zipFile, jarFile);
        end

        function writeBytes(~, filename, bytes)
            fileId = fopen(filename, 'w');
            assert(fileId >= 0, 'Cannot create test file.');
            cleanup = onCleanup(@()fclose(fileId));
            fwrite(fileId, bytes, 'uint8');
            clear cleanup;
        end
    end
end
