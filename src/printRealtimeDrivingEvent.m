function printRealtimeDrivingEvent(event)
%PRINTREALTIMEDRIVINGEVENT Print a completed online candidate event.
required={'eventId','type','durationSeconds','peakAcceleration','peakJerk','dataQuality'};
if ~isstruct(event)||~isscalar(event)||~all(isfield(event,required))
    error('IMU:InvalidRealtimeEvent','A completed realtime event is required.');
end
fprintf('%s\nType: %s\nDuration: %.2f s\nPeak acceleration: %.2f m/s^2\n', ...
    event.eventId,event.type,event.durationSeconds,event.peakAcceleration);
fprintf('Peak jerk: %.2f m/s^3\nData quality: %.2f\n',event.peakJerk,event.dataQuality);
end
