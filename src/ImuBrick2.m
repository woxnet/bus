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

            obj.Device.setAllDataPeriod(int64(periodMs));
            obj.IsStreaming = true;
            obj.StreamingPeriodMs = double(periodMs);
        end

        function stop(obj)
            if obj.IsConnected
                obj.Device.setAllDataPeriod(int64(0));
                obj.IsStreaming = false;
            end
        end

        function data = readOnce(obj)
            % Синхронное единичное чтение.

            obj.checkConnection();
            raw = obj.Device.getAllData();
            data = obj.decodeData(raw);
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
            % Последняя структура, полученная callback-функцией.
            if obj.CallbackRegistered
                snapshot = obj.CallbackBridge.poll();
                if ~isempty(snapshot)
                    obj.LatestData = obj.decodeData(snapshot.getData());
                    obj.LatestData.hostTimestamp = datetime( ...
                        double(snapshot.getTimestampMillis()) / 1000, ...
                        'ConvertFrom', 'posixtime');
                    obj.LatestData.timestamp = obj.LatestData.hostTimestamp;
                end
            end
            if isempty(obj.LatestData)
                error(['Данные еще не получены. ', ...
                       'Вызовите start() и дождитесь первого callback.']);
            end

            data = obj.LatestData;
        end

        function disconnect(obj)
            obj.safeDisconnect();
        end

        function delete(obj)
            obj.safeDisconnect();
        end
    end

    methods (Access = private)
        function data = decodeData(obj, raw)
            obj.SampleSequence = obj.SampleSequence + uint64(1);
            data.sequenceNumber = obj.SampleSequence;
            data.hostTimestamp = datetime('now');
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
            catch exception
                warning('IMU:StopStreamFailed', ...
                    'Не удалось остановить поток IMU при отключении: %s', ...
                    exception.message);
            end

            if obj.CallbackRegistered
                try
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
