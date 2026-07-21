function comparison=compareRealtimeAndOfflineEvents(realtimeEvents,offlineEvents,varargin)
%COMPAREREALTIMEANDOFFLINEEVENTS Match events by type and nearest start.
parser=inputParser;
parser.addParameter('StartEndToleranceSamples',10,@validNonnegativeScalar);
parser.addParameter('PeakAccelerationTolerance',0.75,@validNonnegativeScalar);
parser.addParameter('DurationToleranceSeconds',0.30,@validNonnegativeScalar);
if isscalar(varargin) && isnumeric(varargin{1})
    varargin={'StartEndToleranceSamples',varargin{1}};
end
parser.parse(varargin{:}); limits=parser.Results;
realtimeEvents=realtimeEvents(:); offlineEvents=offlineEvents(:);
used=false(numel(offlineEvents),1);
template=struct('realtimeIndex',NaN,'offlineIndex',NaN,'typeMatch',false, ...
    'startDifferenceSamples',NaN,'endDifferenceSamples',NaN, ...
    'peakAccelerationDifference',NaN,'durationDifferenceSeconds',NaN, ...
    'withinStartEndTolerance',false,'withinLatency',false,'withinPeakTolerance',false, ...
    'withinDurationTolerance',false,'withinTolerance',false);
details=repmat(template,numel(realtimeEvents),1);
for index=1:numel(realtimeEvents)
    realtime=realtimeEvents(index); details(index).realtimeIndex=index;
    candidates=find(~used & arrayfun(@(event)string(event.type)==string(realtime.type),offlineEvents));
    if isempty(candidates), continue; end
    [~,nearest]=min(abs(arrayfun(@(candidate)double(offlineEvents(candidate).startSequence)- ...
        double(realtime.startSequence),candidates)));
    offlineIndex=candidates(nearest); offline=offlineEvents(offlineIndex); used(offlineIndex)=true;
    details(index).offlineIndex=offlineIndex; details(index).typeMatch=true;
    details(index).startDifferenceSamples=double(realtime.startSequence)-double(offline.startSequence);
    details(index).endDifferenceSamples=double(realtime.endSequence)-double(offline.endSequence);
    details(index).peakAccelerationDifference=realtime.peakAcceleration-offline.peakAcceleration;
    details(index).durationDifferenceSeconds=realtime.durationSeconds-offline.durationSeconds;
    details(index).withinStartEndTolerance= ...
        abs(details(index).startDifferenceSamples)<=limits.StartEndToleranceSamples && ...
        abs(details(index).endDifferenceSamples)<=limits.StartEndToleranceSamples;
    details(index).withinLatency=details(index).typeMatch && ...
        details(index).withinStartEndTolerance;
    details(index).withinPeakTolerance= ...
        abs(details(index).peakAccelerationDifference)<=limits.PeakAccelerationTolerance;
    details(index).withinDurationTolerance= ...
        abs(details(index).durationDifferenceSeconds)<=limits.DurationToleranceSeconds;
    details(index).withinTolerance=details(index).typeMatch && ...
        details(index).withinStartEndTolerance && details(index).withinPeakTolerance && ...
        details(index).withinDurationTolerance;
end
countMatch=numel(realtimeEvents)==numel(offlineEvents);
allWithinLatency=countMatch && all(used) && all([details.withinLatency]);
allWithin=countMatch && all(used) && all([details.withinTolerance]);
comparison=struct('realtimeCount',numel(realtimeEvents),'offlineCount',numel(offlineEvents), ...
    'countMatch',countMatch,'details',details,'unmatchedOfflineIndices',find(~used), ...
    'tolerances',limits,'allWithinTolerance',allWithin,'allWithinLatency',allWithinLatency);
end

function valid=validNonnegativeScalar(value)
valid=isnumeric(value)&&isscalar(value)&&isreal(value)&&isfinite(value)&&value>=0;
end
