classdef TestImuCallbackBuild < matlab.unittest.TestCase
%TESTIMUCALLBACKBUILD Hardware-independent compiler and build-cache tests.
    properties
        ProjectRoot
        TemporaryDirectory
    end

    methods (TestClassSetup)
        function setup(testCase)
            testCase.ProjectRoot = fileparts(fileparts(mfilename('fullpath')));
            addpath(fullfile(testCase.ProjectRoot, 'src'));
            testCase.TemporaryDirectory = tempname;
            mkdir(testCase.TemporaryDirectory);
            testCase.addTeardown(@()rmdir(testCase.TemporaryDirectory, 's'));
        end
    end

    methods (Test)
        function jdkEightUsesSourceTarget(testCase)
            testCase.verifyEqual(selectJava8CompilerFlags(8), ...
                '-source 1.8 -target 1.8');
        end

        function modernJdkUsesRelease(testCase)
            testCase.verifyEqual(selectJava8CompilerFlags(9), '--release 8');
            testCase.verifyEqual(parseJavacMajorVersion('javac 1.8.0_402'), 8);
            testCase.verifyEqual(parseJavacMajorVersion('javac 21.0.2'), 21);
        end

        function missingCompilerHasClearIdentifier(testCase)
            options = testCase.options();
            options.commandRunner = @missingCompiler;
            testCase.verifyError(@()buildImuCallbackBridge(options), ...
                'IMU:JavaCompilerUnavailable');
        end

        function runtimeUsesShippedBridgeWithoutCompilation(testCase)
            bridgePath = getImuCallbackBridgePath();
            expected = fullfile(testCase.ProjectRoot, 'lib-generated', ...
                'imu-callback-bridge.jar');
            testCase.verifyEqual(bridgePath, expected);
            testCase.verifyTrue(isfile(bridgePath));
        end

        function jarTimestampInvalidatesBuild(testCase)
            options = testCase.options();
            [~, first] = buildImuCallbackBridge(options);
            testCase.verifyTrue(first.rebuilt);
            [~, cached] = buildImuCallbackBridge(options);
            testCase.verifyFalse(cached.rebuilt);
            pause(1.1);
            marker = fullfile(testCase.TemporaryDirectory, 'changed.txt');
            fileId = fopen(marker, 'w'); fprintf(fileId, 'changed'); fclose(fileId);
            [status, output] = system(sprintf('jar uf "%s" -C "%s" changed.txt', ...
                options.jarFile, testCase.TemporaryDirectory));
            assert(status == 0, output);
            [~, changed] = buildImuCallbackBridge(options);
            testCase.verifyTrue(changed.rebuilt);
        end
    end

    methods (Access = private)
        function options = options(testCase)
            source = fullfile(testCase.ProjectRoot, 'java', 'bus', 'imu', ...
                'ImuAllDataBuffer.java');
            jar = fullfile(testCase.TemporaryDirectory, 'Tinkerforge.jar');
            if ~isfile(jar)
                stub = fullfile(testCase.ProjectRoot, 'java', 'test', ...
                    'com', 'tinkerforge', 'BrickIMUV2.java');
                stubClasses = fullfile(testCase.TemporaryDirectory, 'stub-classes');
                mkdir(stubClasses);
                [compileStatus, compileOutput] = system(sprintf( ...
                    'javac --release 8 -d "%s" "%s"', stubClasses, stub));
                assert(compileStatus == 0, compileOutput);
                [jarStatus, jarOutput] = system(sprintf( ...
                    'jar cf "%s" -C "%s" .', jar, stubClasses));
                assert(jarStatus == 0, jarOutput);
            end
            options = struct('sourceFile', source, 'jarFile', jar, ...
                'outputDirectory', fullfile(testCase.TemporaryDirectory, 'classes'));
        end
    end
end

function [status, output] = missingCompiler(~)
status = 1;
output = 'javac not found';
end
