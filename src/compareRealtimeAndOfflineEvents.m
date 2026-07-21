function comparison=compareRealtimeAndOfflineEvents(realtimeEvents,offlineEvents,filterLatencySamples)
%COMPAREREALTIMEANDOFFLINEEVENTS Compare ordered candidate events by type.
if nargin<3, filterLatencySamples=10; end
validateattributes(filterLatencySamples,{'numeric'},{'scalar','integer','nonnegative'});
realtimeEvents=realtimeEvents(:); offlineEvents=offlineEvents(:);
count=min(numel(realtimeEvents),numel(offlineEvents));
details=repmat(struct('typeMatch',false,'startDifferenceSamples',NaN, ...
    'endDifferenceSamples',NaN,'peakAccelerationDifference',NaN, ...
    'durationDifferenceSeconds',NaN,'withinLatency',false),count,1);
for index=1:count
    rt=realtimeEvents(index); off=offlineEvents(index);
    details(index).typeMatch=string(rt.type)==string(off.type);
    details(index).startDifferenceSamples=double(rt.startSequence)-double(off.startSequence);
    details(index).endDifferenceSamples=double(rt.endSequence)-double(off.endSequence);
    details(index).peakAccelerationDifference=rt.peakAcceleration-off.peakAcceleration;
    details(index).durationDifferenceSeconds=rt.durationSeconds-off.durationSeconds;
    details(index).withinLatency=details(index).typeMatch && ...
        abs(details(index).startDifferenceSamples)<=filterLatencySamples && ...
        abs(details(index).endDifferenceSamples)<=filterLatencySamples;
end
comparison=struct('realtimeCount',numel(realtimeEvents),'offlineCount',numel(offlineEvents), ...
    'countMatch',numel(realtimeEvents)==numel(offlineEvents),'details',details, ...
    'allWithinLatency',numel(realtimeEvents)==numel(offlineEvents)&& ...
    all([details.withinLatency]));
end
