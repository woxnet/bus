function warningText=notifyHardwareAcceptanceObserver(options,type,stage,state,progress,message,payload)
%NOTIFYHARDWAREACCEPTANCEOBSERVER Invoke an optional observer without affecting results.
warningText="";
if nargin<1 || ~isstruct(options) || ~isfield(options,'Observer') || isempty(options.Observer), return; end
event=struct('timestamp',datetime('now','TimeZone','UTC'),'type',string(type), ...
    'stage',string(stage),'state',string(state),'progress',double(progress), ...
    'message',string(message),'payload',payload);
try
    options.Observer(event);
catch exception
    warningText=string(exception.identifier)+": "+string(exception.message);
    warning('IMU:AcceptanceObserverFailed','Acceptance observer failed: %s',exception.message);
end
end
