classdef ImuBrick2 < handle
    properties (SetAccess = private)
        IPConnection
        Device
        LatestData
        IsConnected = false
        IsStreaming = false
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

                % Регистрация callback для всех данных IMU.
                set(obj.Device, ...
                    'AllDataCallback', ...
                    @(~, event)obj.onAllData(event));

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
            obj.Device.setAllDataPeriod(int64(periodMs));
            obj.IsStreaming = true;
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

        function data = latest(obj)
            % Последняя структура, полученная callback-функцией.

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
        function onAllData(obj, event)
            obj.LatestData = obj.decodeData(event);
        end

        function data = decodeData(~, raw)
            data.timestamp = datetime('now');

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

        function safeDisconnect(obj)
            if ~obj.IsConnected
                return;
            end

            try
                obj.Device.setAllDataPeriod(int64(0));
            catch
            end

            try
                obj.IPConnection.disconnect();
            catch
            end

            obj.IsConnected = false;
            obj.IsStreaming = false;
        end
    end
end
