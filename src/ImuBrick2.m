classdef ImuBrick2 < handle
    properties (SetAccess = private)
        IPConnection
        Device
        LatestData
        IsConnected = false
        IsStreaming = false
        UID
        Host
        Port
        StreamingPeriodMs = NaN
        SampleSequence = uint64(0)
    end

    properties (Access = private)
        CallbackRegistered = false
        CallbackBridge
    end

    properties (Dependent, SetAccess = private)
        CallbackReceivedCount
        CallbackDroppedCount
        CallbackBufferedCount
        LastCallbackSequence
    end

    methods
        function obj = ImuBrick2(uid, host, port)
            if nargin < 2 || isempty(host)
                host = 'localhost';
            end

            if nargin < 3 || isempty(port)
                port = 4223;
            end

            if isempty(uid)
                error('Необходимо указать UID IMU Brick 2.0.');
            end
            obj.UID = string(uid);
            obj.Host = string(host);
            obj.Port = double(port);

            % Создание объектов Tinkerforge.
            obj.IPConnection = javaObject( ...
                'com.tinkerforge.IPConnection');

            rawDevice = javaObject( ...
                'com.tinkerforge.BrickIMUV2', ...
                char(uid), ...
                obj.IPConnection);

            % Обертка handle нужна для MATLAB callbacks.
            obj.Device = handle(rawDevice, 'CallbackProperties');

            try
                obj.IPConnection.connect(char(host), port);
                obj.IsConnected = true;

            catch exception
                obj.safeDisconnect();
                rethrow(exception);
            end
        end

        function start(obj, periodMs)
            % START Запускает периодическую передачу данных.
            %
            % Пример:
            %   imu.start(20); % приблизительно 50 вызовов в секунду

            if nargin < 2
                periodMs = 20;
            end

            validateattributes(periodMs, {'numeric'}, ...
                {'scalar', 'integer', 'positive'});

            obj.checkConnection();
            if ~obj.CallbackRegistered
                obj.CallbackBridge = ensureImuCallbackBridge();
                obj.Device.addAllDataListener(obj.CallbackBridge);
                obj.CallbackRegistered = true;
            end
            if obj.IsStreaming, obj.Device.setAllDataPeriod(int64(0)); end
            obj.clearCallbackBuffer();
            obj.Device.setAllDataPeriod(int64(periodMs));
            obj.IsStreaming = true;
            obj.StreamingPeriodMs = double(periodMs);
        end

        function stop(obj)
            if obj.IsConnected
                obj.Device.setAllDataPeriod(int64(0));
                obj.IsStreaming = false;
                obj.clearCallbackBuffer();
            end
        end

        function data = readOnce(obj)
            % Синхронное единичное чтение.

            obj.checkConnection();
            raw = obj.Device.getAllData();
            obj.SampleSequence = obj.SampleSequence + uint64(1);
            data = obj.decodeData(raw, "synchronous", obj.SampleSequence, ...
                datetime('now'), uint64(0));
        end

        function mode = getSensorFusionMode(obj)
            %GETSENSORFUSIONMODE Return the active Tinkerforge fusion mode.
            obj.checkConnection();
            mode = double(obj.Device.getSensorFusionMode());
        end

        function setSensorFusionMode(obj, mode)
            %SETSENSORFUSIONMODE Set fusion mode and verify the value.
            validateattributes(mode, {'numeric'}, ...
                {'scalar','integer','>=',0,'<=',2});
            obj.checkConnection();
            obj.Device.setSensorFusionMode(int16(mode));
            applied = obj.getSensorFusionMode();
            if applied ~= double(mode)
                error('IMU:SensorFusionModeMismatch', ...
                    'Requested fusion mode %d, device reports %d.', mode, applied);
            end
        end

        function identity = getIdentity(obj)
            %GETIDENTITY Return normalized Tinkerforge device identity data.
            obj.checkConnection();
            raw = obj.Device.getIdentity();
            identity = struct();
            identity.uid = string(obj.identityField(raw, 'uid'));
            identity.connectedUid = string(obj.identityField(raw, 'connectedUid'));
            identity.position = string(obj.identityField(raw, 'position'));
            identity.hardwareVersion = double( ...
                obj.identityField(raw, 'hardwareVersion')).';
            identity.firmwareVersion = double( ...
                obj.identityField(raw, 'firmwareVersion')).';
            identity.deviceIdentifier = double( ...
                obj.identityField(raw, 'deviceIdentifier'));
        end

        function data = latest(obj)
            %LATEST Return the newest callback sample and discard backlog.
            if obj.CallbackRegistered
                snapshot = obj.CallbackBridge.pollLatest();
                if ~isempty(snapshot), obj.LatestData = obj.decodeSnapshot(snapshot); end
            end
            if isempty(obj.LatestData)
                error('IMU:CallbackNotReady', ...
                    'No callback data is available. Call start() and wait.');
            end
            data = obj.LatestData;
        end

        function data = nextCallbackSample(obj)
            %NEXTCALLBACKSAMPLE Remove and return the oldest buffered sample.
            data = [];
            if ~obj.CallbackRegistered, return; end
            snapshot = obj.CallbackBridge.poll();
            if ~isempty(snapshot), data = obj.decodeSnapshot(snapshot); end
        end

        function metadata = nextCallbackMetadata(obj)
            %NEXTCALLBACKMETADATA Poll sequence/timing without payload decoding.
            metadata = [];
            if ~obj.CallbackRegistered, return; end
            snapshot = obj.CallbackBridge.poll();
            if isempty(snapshot), return; end
            metadata = struct('sequenceNumber', uint64(snapshot.getSequence()), ...
                'timestampMillis', double(snapshot.getTimestampMillis()), ...
                'callbackDroppedBeforeSample', obj.CallbackDroppedCount);
        end

        function samples = drainCallbackSamples(obj, maxCount)
            %DRAINCALLBACKSAMPLES Return up to MAXCOUNT sequential samples.
            if nargin < 2, maxCount = Inf; end
            validateattributes(maxCount, {'numeric'}, {'scalar','positive'});
            samples = cell(0, 1);
            while numel(samples) < maxCount
                sample = obj.nextCallbackSample();
                if isempty(sample), break; end
                samples{end+1, 1} = sample; %#ok<AGROW>
            end
        end

        function clearCallbackBuffer(obj)
            %CLEARCALLBACKBUFFER Reset buffered data and per-session counters.
            obj.LatestData = [];
            if obj.CallbackRegistered, obj.CallbackBridge.clear(); end
        end

        function stats = getCallbackStats(obj)
            stats = struct('received', obj.CallbackReceivedCount, ...
                'dropped', obj.CallbackDroppedCount, ...
                'buffered', obj.CallbackBufferedCount, ...
                'lastSequence', obj.LastCallbackSequence, ...
                'streamingPeriodMs', obj.StreamingPeriodMs);
        end

        function value = get.CallbackReceivedCount(obj)
            value = obj.bridgeMetric('getReceivedCount');
        end

        function value = get.CallbackDroppedCount(obj)
            value = obj.bridgeMetric('getDroppedCount');
        end

        function value = get.CallbackBufferedCount(obj)
            value = obj.bridgeMetric('size');
        end

        function value = get.LastCallbackSequence(obj)
            value = obj.bridgeMetric('getLastSequence');
        end

        function disconnect(obj)
            obj.safeDisconnect();
        end

        function delete(obj)
            obj.safeDisconnect();
        end
    end

    methods (Access = private)
        function data = decodeData(~, raw, source, sequence, timestamp, dropped)
            data.source = string(source);
            data.sequenceNumber = uint64(sequence);
            data.callbackDroppedBeforeSample = uint64(dropped);
            data.hostTimestamp = timestamp;
            data.timestamp = data.hostTimestamp;

            % Ускорение акселерометра, включая гравитацию, м/с^2.
            data.acceleration = ...
                double(raw.acceleration(:)).' / 100.0;

            % Линейное ускорение без гравитации, м/с^2.
            data.linearAcceleration = ...
                double(raw.linearAcceleration(:)).' / 100.0;

            % Вектор гравитации, м/с^2.
            data.gravity = ...
                double(raw.gravityVector(:)).' / 100.0;

            % Угловая скорость, град/с.
            data.angularVelocity = ...
                double(raw.angularVelocity(:)).' / 16.0;

            % Магнитное поле, мкТл.
            data.magneticField = ...
                double(raw.magneticField(:)).' / 16.0;

            % heading, roll, pitch, градусы.
            data.euler = ...
                double(raw.eulerAngle(:)).' / 16.0;

            % Порядок компонентов: w, x, y, z.
            data.quaternion = ...
                double(raw.quaternion(:)).' / 16383.0;

            data.temperature = double(raw.temperature);

            calibrationByte = uint8( ...
                mod(double(raw.calibrationStatus), 256));

            data.calibration.magnetometer = double( ...
                bitand(calibrationByte, uint8(3)));

            data.calibration.accelerometer = double( ...
                bitand(bitshift(calibrationByte, -2), uint8(3)));

            data.calibration.gyroscope = double( ...
                bitand(bitshift(calibrationByte, -4), uint8(3)));

            data.calibration.system = double( ...
                bitand(bitshift(calibrationByte, -6), uint8(3)));
        end

        function data = decodeSnapshot(obj, snapshot)
            timestamp = datetime(double(snapshot.getTimestampMillis()) / 1000, ...
                'ConvertFrom', 'posixtime', 'TimeZone', 'UTC');
            data = obj.decodeData(snapshot.getData(), "callback", ...
                uint64(snapshot.getSequence()), timestamp, ...
                obj.CallbackDroppedCount);
        end

        function value = bridgeMetric(obj, methodName)
            if ~obj.CallbackRegistered || isempty(obj.CallbackBridge)
                value = uint64(0);
                return;
            end
            switch methodName
                case 'getReceivedCount', raw = obj.CallbackBridge.getReceivedCount();
                case 'getDroppedCount', raw = obj.CallbackBridge.getDroppedCount();
                case 'size', raw = obj.CallbackBridge.size();
                case 'getLastSequence', raw = obj.CallbackBridge.getLastSequence();
                otherwise, error('IMU:InternalError', 'Unknown bridge metric.');
            end
            value = uint64(raw);
        end

        function checkConnection(obj)
            if ~obj.IsConnected
                error('Соединение с IMU Brick 2.0 не установлено.');
            end
        end

        function value = identityField(~, raw, name)
            field = raw.getClass().getField(name);
            value = field.get(raw);
        end

        function safeDisconnect(obj)
            if ~obj.IsConnected
                return;
            end

            try
                obj.Device.setAllDataPeriod(int64(0));
                obj.clearCallbackBuffer();
            catch exception
                warning('IMU:StopStreamFailed', ...
                    'Не удалось остановить поток IMU при отключении: %s', ...
                    exception.message);
            end

            if obj.CallbackRegistered
                try
                    obj.clearCallbackBuffer();
                    obj.Device.removeAllDataListener(obj.CallbackBridge);
                    obj.CallbackRegistered = false;
                catch exception
                    warning('IMU:CallbackCleanupFailed', ...
                        'Не удалось снять callback IMU при отключении: %s', ...
                        exception.message);
                end
            end

            try
                obj.IPConnection.disconnect();
            catch exception
                warning('IMU:DisconnectFailed', ...
                    'Не удалось отключиться от Brick Daemon: %s', ...
                    exception.message);
            end

            obj.IsConnected = false;
            obj.IsStreaming = false;
        end
    end
end
