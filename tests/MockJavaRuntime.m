classdef MockJavaRuntime < handle
    properties
        Paths = cell(0, 1)
        AddPathCalls = 0
        BuildBridgeCalls = 0
        LoadedClasses = strings(0, 1)
        JarSource = ""
        BridgeSource = ""
        ExpectedJar = ""
        ExpectedBridge = ""
        ConstructionCount = 0
    end

    methods
        function obj = MockJavaRuntime(jarFile, bridgeFile)
            obj.ExpectedJar = string(MockJavaRuntime.canonical(jarFile));
            obj.ExpectedBridge = string(MockJavaRuntime.canonical(bridgeFile));
            obj.JarSource = obj.ExpectedJar;
            obj.BridgeSource = obj.ExpectedBridge;
        end

        function dependencies = dependencies(obj)
            dependencies = struct( ...
                'javaClassPath', @()obj.getPaths(), ...
                'javaAddPath', @(paths)obj.addPaths(paths), ...
                'classForName', @(name)obj.findClass(name), ...
                'classCodeSource', @(reference)obj.codeSource(reference), ...
                'buildBridge', @()obj.getBridge());
        end

        function paths = getPaths(obj)
            paths = obj.Paths;
        end

        function path = getBridge(obj)
            obj.BuildBridgeCalls = obj.BuildBridgeCalls + 1;
            path = char(obj.ExpectedBridge);
        end

        function addPaths(obj, paths)
            obj.AddPathCalls = obj.AddPathCalls + 1;
            for index = 1:numel(paths)
                path = string(MockJavaRuntime.canonical(paths{index}));
                if ~any(strcmpi(obj.Paths, path)), obj.Paths{end+1, 1} = char(path); end
                if strcmpi(path, obj.ExpectedJar)
                    obj.loadTinkerforge(obj.ExpectedJar);
                elseif strcmpi(path, obj.ExpectedBridge)
                    obj.loadBridge(obj.ExpectedBridge);
                end
            end
        end

        function reference = findClass(obj, name)
            name = string(name);
            if ~any(obj.LoadedClasses == name)
                error('java:lang:ClassNotFoundException', ...
                    'ClassNotFoundException: %s', name);
            end
            reference = name;
        end

        function source = codeSource(obj, reference)
            switch string(reference)
                case {"com.tinkerforge.IPConnection", "com.tinkerforge.BrickIMUV2"}
                    source = char(obj.JarSource);
                case "bus.imu.ImuAllDataBuffer"
                    source = char(obj.BridgeSource);
                otherwise
                    error('IMU:UnknownMockClass', 'Unknown mock class.');
            end
        end

        function loadTinkerforge(obj, source)
            obj.LoadedClasses = union(obj.LoadedClasses, [ ...
                "com.tinkerforge.IPConnection"; "com.tinkerforge.BrickIMUV2"]);
            obj.JarSource = string(source);
        end

        function loadBridge(obj, source)
            obj.LoadedClasses = union(obj.LoadedClasses, "bus.imu.ImuAllDataBuffer");
            obj.BridgeSource = string(source);
        end
    end

    methods (Static)
        function value = canonical(path)
            value = char(javaObject('java.io.File', char(path)).getCanonicalPath());
        end
    end
end
