classdef ImuSessionRecorder < handle
%IMUSESSIONRECORDER Persist calibrated FIFO samples in bounded disk chunks.
    properties (SetAccess = private)
        IsRecording = false
        SessionId = ""
        WorkingDirectory = ""
        FinalDirectory = ""
        SamplesWritten = 0
        DuplicateSamples = 0
        MissingSamples = 0
    end
    properties (Access = private)
        Imu
        Calibration
        Options
        SensorBuffer = cell(0, 1)
        VehicleBuffer = cell(0, 1)
        ChunkIndex = 0
        LastSequence = uint64(0)
        StreamSessionId = uint64(0)
        Gaps = zeros(0, 3)
        RecordingTimer = []
    end

    methods
        function obj = ImuSessionRecorder(imu, calibration, options)
            if nargin < 3, options = struct(); end
            obj.Options = obj.mergeOptions(options);
            validation = validateImuCalibration(calibration, ...
                'AllowSynthetic', obj.Options.AllowSynthetic);
            if ~validation.valid
                error('IMU:InvalidCalibrationFile', '%s', ...
                    strjoin(validation.errors, ' '));
            end
            obj.Imu = imu;
            obj.Calibration = calibration;
        end

        function start(obj)
            if obj.IsRecording, error('IMU:RecorderAlreadyStarted', 'Recorder is active.'); end
            root = resolveProjectPath(obj.Options.directory);
            if ~isfolder(root), mkdir(root); end
            stamp = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss_SSS'));
            uuid = char(javaMethod('randomUUID', 'java.util.UUID'));
            obj.SessionId = string([stamp, '_', uuid(1:8)]);
            obj.WorkingDirectory = string(fullfile(root, ...
                char(obj.SessionId) + ".inprogress"));
            obj.FinalDirectory = string(fullfile(root, char(obj.SessionId)));
            mkdir(char(obj.WorkingDirectory));
            obj.resetState();
            obj.writeMetadata("incomplete");
            obj.RecordingTimer = tic;
            obj.Imu.start(obj.Options.callbackPeriodMs);
            stats = obj.Imu.getCallbackStats();
            obj.StreamSessionId = uint64(stats.sessionId);
            obj.IsRecording = true;
        end

        function count = poll(obj)
            if ~obj.IsRecording, error('IMU:RecorderNotStarted', 'Recorder is not active.'); end
            samples = obj.Imu.drainCallbackSamples(obj.Options.maxPollSamples);
            count = 0;
            for index = 1:numel(samples)
                sample = samples{index};
                if uint64(sample.sessionId) ~= obj.StreamSessionId, continue; end
                sequence = uint64(sample.sequenceNumber);
                if obj.LastSequence > 0 && sequence <= obj.LastSequence
                    obj.DuplicateSamples = obj.DuplicateSamples + 1;
                    continue;
                end
                if obj.LastSequence > 0 && sequence > obj.LastSequence + 1
                    missing = double(sequence - obj.LastSequence - 1);
                    obj.MissingSamples = obj.MissingSamples + missing;
                    obj.Gaps(end+1, :) = [double(obj.LastSequence), ...
                        double(sequence), missing];
                end
                vehicle = applyMountCalibration(sample, obj.Calibration, ...
                    'AllowSynthetic', obj.Options.AllowSynthetic);
                obj.SensorBuffer{end+1, 1} = sample;
                obj.VehicleBuffer{end+1, 1} = vehicle;
                obj.LastSequence = sequence;
                count = count + 1;
                if numel(obj.SensorBuffer) >= obj.Options.chunkSize
                    obj.flushChunk();
                end
            end
        end

        function session = stop(obj)
            if ~obj.IsRecording, error('IMU:RecorderNotStarted', 'Recorder is not active.'); end
            obj.poll();
            obj.flushChunk();
            stats = obj.Imu.getCallbackStats();
            obj.Imu.stop();
            summary = obj.makeSummary(stats, "complete");
            obj.writeJson(fullfile(char(obj.WorkingDirectory), 'summary.json'), summary);
            obj.writeMetadata("complete");
            [success, message] = movefile(char(obj.WorkingDirectory), ...
                char(obj.FinalDirectory));
            if ~success
                error('IMU:RecorderFinalizeFailed', '%s', message);
            end
            obj.IsRecording = false;
            session = summary;
            session.directory = obj.FinalDirectory;
        end

        function delete(obj)
            if ~obj.IsRecording, return; end
            try
                stats = obj.Imu.getCallbackStats();
                obj.flushChunk();
                obj.writeJson(fullfile(char(obj.WorkingDirectory), ...
                    'summary.json'), obj.makeSummary(stats, "incomplete"));
                obj.writeMetadata("incomplete");
                obj.Imu.stop();
            catch exception
                warning('IMU:RecorderCleanupFailed', '%s', exception.message);
            end
            obj.IsRecording = false;
        end
    end

    methods (Access = private)
        function resetState(obj)
            obj.SensorBuffer = cell(0, 1); obj.VehicleBuffer = cell(0, 1);
            obj.ChunkIndex = 0; obj.LastSequence = uint64(0);
            obj.SamplesWritten = 0; obj.DuplicateSamples = 0;
            obj.MissingSamples = 0; obj.Gaps = zeros(0, 3);
        end

        function flushChunk(obj)
            if isempty(obj.SensorBuffer), return; end
            obj.ChunkIndex = obj.ChunkIndex + 1;
            sensorSamples = obj.SensorBuffer;
            vehicleSamples = obj.VehicleBuffer;
            filename = fullfile(char(obj.WorkingDirectory), ...
                sprintf('samples_%06d.mat', obj.ChunkIndex));
            save(filename, 'sensorSamples', 'vehicleSamples', '-v7');
            obj.SamplesWritten = obj.SamplesWritten + numel(obj.SensorBuffer);
            obj.SensorBuffer = cell(0, 1); obj.VehicleBuffer = cell(0, 1);
        end

        function metadata = metadata(obj, status)
            source = obj.Calibration.metadata;
            metadata = struct('sessionId', obj.SessionId, 'status', string(status), ...
                'uid', string(source.imuUid), 'busId', string(source.busId), ...
                'calibrationVersion', obj.Calibration.version, ...
                'firmwareVersion', source.firmwareVersion, ...
                'createdAt', string(datetime('now', 'TimeZone', 'UTC'), ...
                    'yyyy-MM-dd''T''HH:mm:ss.SSSXXX'));
        end

        function writeMetadata(obj, status)
            obj.writeJson(fullfile(char(obj.WorkingDirectory), ...
                'metadata.json'), obj.metadata(status));
        end

        function summary = makeSummary(obj, stats, status)
            summary = struct('sessionId', obj.SessionId, 'status', string(status), ...
                'durationSeconds', obj.recordingDuration(), ...
                'samplesWritten', obj.SamplesWritten, ...
                'duplicateSamples', obj.DuplicateSamples, ...
                'missingSamples', obj.MissingSamples, 'gaps', obj.Gaps, ...
                'received', double(stats.received), ...
                'overflowDropped', double(stats.overflowDropped), ...
                'coalesced', double(stats.coalesced), ...
                'staleSessionDropped', double(stats.staleSessionDropped), ...
                'chunkCount', obj.ChunkIndex);
        end

        function duration = recordingDuration(obj)
            if isempty(obj.RecordingTimer)
                duration = NaN;
            else
                duration = toc(obj.RecordingTimer);
            end
        end

        function writeJson(~, filename, value)
            temporary = [filename, '.tmp'];
            fileId = fopen(temporary, 'w');
            if fileId < 0, error('IMU:RecorderWriteFailed', 'Cannot write %s.', filename); end
            cleanup = onCleanup(@()fclose(fileId));
            fprintf(fileId, '%s', jsonencode(value, 'PrettyPrint', true));
            clear cleanup;
            [success, message] = movefile(temporary, filename, 'f');
            if ~success, error('IMU:RecorderWriteFailed', '%s', message); end
        end

        function options = mergeOptions(~, custom)
            config = getImuConfig();
            options = struct('directory', 'sessions', 'chunkSize', 1000, ...
                'maxPollSamples', 256, 'callbackPeriodMs', config.callbackPeriodMs, ...
                'AllowSynthetic', false);
            if ~isstruct(custom) || ~isscalar(custom)
                error('IMU:InvalidRecorderOptions', 'options must be a scalar struct.');
            end
            fields = fieldnames(custom);
            unknown = setdiff(fields, fieldnames(options));
            if ~isempty(unknown)
                error('IMU:InvalidRecorderOptions', 'Unknown option: %s.', unknown{1});
            end
            for index = 1:numel(fields), options.(fields{index}) = custom.(fields{index}); end
            validateattributes(options.chunkSize, {'numeric'}, {'scalar','integer','positive'});
            validateattributes(options.maxPollSamples, {'numeric'}, {'scalar','integer','positive'});
            validateattributes(options.callbackPeriodMs, {'numeric'}, {'scalar','positive'});
            if ~(islogical(options.AllowSynthetic) && isscalar(options.AllowSynthetic))
                error('IMU:InvalidRecorderOptions', 'AllowSynthetic must be logical.');
            end
        end
    end
end
