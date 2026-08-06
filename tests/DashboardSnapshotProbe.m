classdef DashboardSnapshotProbe < handle
    properties
        TelemetryHub
        FullSnapshotCalls=0
        SummarySnapshotCalls=0
        Closed=false
    end
    methods
        function obj=DashboardSnapshotProbe(config)
            if nargin<1, config=getBusDrivingSystemDashboardConfig(); end
            obj.TelemetryHub=BusDrivingSystemTelemetryHub(config);
        end
        function value=getSummarySnapshot(obj)
            obj.SummarySnapshotCalls=obj.SummarySnapshotCalls+1; value=obj.TelemetryHub.getSummarySnapshot();
            status=obj.getStatus(); value.actions=status.actions;
        end
        function value=getTelemetrySnapshot(obj)
            obj.FullSnapshotCalls=obj.FullSnapshotCalls+1; value=obj.TelemetryHub.getSnapshot();
        end
        function value=getStatus(obj)
            actions=struct('canStartSystem',true,'canRunPreflight',false,'canStartCalibration',false, ...
                'canConfirmCalibration',false,'canRejectCalibration',false,'canStartRealtime',false, ...
                'canStopRealtime',false,'canRunAcceptance',true,'canSaveSnapshot',true,'canClose',~obj.Closed);
            value=struct('lifecycleState',"IDLE",'currentStage',"",'stageProgress',0,'message',"", ...
                'mode',"test",'isRealtimeRunning',false,'isCalibrationRunning',false, ...
                'isAcceptanceRunning',false,'actions',actions);
        end
        function close(obj), obj.Closed=true; end
        function startSystem(~), end
        function runPreflight(~), end
        function startCalibration(~), end
        function confirmCurrentStep(~), end
        function rejectCurrentStep(~), end
        function startRealtime(~), end
        function stopRealtime(~), end
        function runFullAcceptance(~), end
    end
end
