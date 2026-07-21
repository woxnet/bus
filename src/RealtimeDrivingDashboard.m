classdef RealtimeDrivingDashboard < handle
%REALTIMEDRIVINGDASHBOARD Throttled diagnostic UI; never affects detection.
    properties (SetAccess = private)
        IsOpen = false
    end
    properties (Access = private)
        Monitor
        Figure
        Axes
        Lines
        StatusText
        LastRefresh
        Time = zeros(0,1)
        Values = zeros(0,4)
    end
    methods
        function obj=RealtimeDrivingDashboard(monitor), obj.Monitor=monitor; end
        function open(obj)
            if obj.IsOpen, return; end
            obj.Figure=figure('Name','Real-time IMU driving monitor','Color','w', ...
                'CloseRequestFcn',@(~,~)obj.close());
            layout=tiledlayout(obj.Figure,4,1,'TileSpacing','compact');
            labels={'Longitudinal m/s^2','Lateral m/s^2','Yaw deg/s','Vertical m/s^2'};
            obj.Axes=gobjects(4,1); obj.Lines=gobjects(4,1);
            for index=1:4
                obj.Axes(index)=nexttile(layout); obj.Lines(index)=plot(obj.Axes(index),NaN,NaN);
                ylabel(obj.Axes(index),labels{index}); grid(obj.Axes(index),'on');
            end
            xlabel(obj.Axes(4),'Elapsed seconds');
            obj.StatusText=annotation(obj.Figure,'textbox',[0.72 0.94 0.27 0.05], ...
                'String','running','EdgeColor','none');
            obj.LastRefresh=tic; obj.IsOpen=true;
        end
        function update(obj,p)
            if ~obj.IsOpen || ~isgraphics(obj.Figure), return; end
            obj.Time(end+1,1)=p.elapsedSeconds;
            obj.Values(end+1,:)=[p.longitudinalFiltered,p.lateralFiltered, ...
                p.yawRateFiltered,p.verticalFiltered];
            capacity=max(1,ceil(obj.Monitor.Config.historySeconds*obj.Monitor.Config.sampleRateHz));
            if numel(obj.Time)>capacity
                obj.Time=obj.Time(end-capacity+1:end); obj.Values=obj.Values(end-capacity+1:end,:);
            end
            if toc(obj.LastRefresh)<1/obj.Monitor.Config.plotRefreshHz, return; end
            for index=1:4, set(obj.Lines(index),'XData',obj.Time,'YData',obj.Values(:,index)); end
            stats=obj.Monitor.getStats(); latest="none";
            if ~isempty(obj.Monitor.LatestEvent), latest=string(obj.Monitor.LatestEvent.type); end
            obj.StatusText.String=sprintf('samples=%d events=%d missing=%d overflow=%d latest=%s', ...
                stats.samplesProcessed,stats.eventsDetected,stats.missingSamples, ...
                stats.overflowDropped,latest);
            drawnow limitrate; obj.LastRefresh=tic;
        end
        function close(obj)
            if ~isempty(obj.Figure)&&isgraphics(obj.Figure)
                set(obj.Figure,'CloseRequestFcn',[]); delete(obj.Figure);
            end
            obj.IsOpen=false;
        end
        function delete(obj), obj.close(); end
    end
end
