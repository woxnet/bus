function commit = getImuAcceptanceCommit(commandFunction)
%GETIMUACCEPTANCECOMMIT Return the exact checkout SHA or fail closed.
if nargin < 1 || isempty(commandFunction), commandFunction = @system; end
[status, value] = commandFunction('git rev-parse HEAD');
commit = strtrim(string(value));
if status ~= 0 || ~isscalar(commit) || strlength(commit) ~= 40 || ...
        isempty(regexp(char(commit),'^[0-9a-fA-F]{40}$','once'))
    error('IMU:AcceptanceCommitUnknown', ...
        'Cannot determine the exact checkout commit for hardware acceptance.');
end
commit = lower(commit);
end
