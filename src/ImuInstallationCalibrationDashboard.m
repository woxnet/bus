classdef ImuInstallationCalibrationDashboard < handle
%IMUINSTALLATIONCALIBRATIONDASHBOARD Thin, throttled controller UI.
    properties (SetAccess=private)
        Figure
        LastRenderedAt = NaT
    end
    properties (Access=private)
        Controller
        StateLabel
        MessageLabel
        ProgressGauge
        SamplesLabel
        ErrorLabel
        QualityLabel
        VerificationLabel
        StartButton
        ConfirmButton
        CancelButton
        CloseButton
        PreviousStateCallback
        PreviousProgressCallback
        PreviousMessageCallback
    end
    methods
        function obj=ImuInstallationCalibrationDashboard(controller)
            obj.Controller=controller;
            obj.Figure=uifigure('Name','IMU installation calibration', ...
                'Position',[100 100 620 430],'CloseRequestFcn',@(~,~)obj.requestClose());
            grid=uigridlayout(obj.Figure,[9 2]);
            grid.RowHeight={30,45,40,30,35,35,35,35,35};
            grid.ColumnWidth={'1x','1x'};
            obj.StateLabel=uilabel(grid,'Text','IDLE','FontWeight','bold');
            obj.StateLabel.Layout.Column=[1 2];
            obj.MessageLabel=uilabel(grid,'Text','Ready','WordWrap','on');
            obj.MessageLabel.Layout.Column=[1 2];
            obj.ProgressGauge=uigauge(grid,'linear','Limits',[0 100],'Value',0);
            obj.ProgressGauge.Layout.Column=[1 2];
            obj.SamplesLabel=uilabel(grid,'Text','Remaining samples: —'); obj.SamplesLabel.Layout.Column=[1 2];
            obj.ErrorLabel=uilabel(grid,'Text','Last error: —'); obj.ErrorLabel.Layout.Column=[1 2];
            obj.QualityLabel=uilabel(grid,'Text','Quality: —'); obj.QualityLabel.Layout.Column=[1 2];
            obj.VerificationLabel=uilabel(grid,'Text','Verification: —'); obj.VerificationLabel.Layout.Column=[1 2];
            obj.StartButton=uibutton(grid,'Text','Start','ButtonPushedFcn',@(~,~)obj.start());
            obj.ConfirmButton=uibutton(grid,'Text','Confirm','Enable','off');
            obj.CancelButton=uibutton(grid,'Text','Cancel','ButtonPushedFcn',@(~,~)controller.cancel());
            obj.CloseButton=uibutton(grid,'Text','Close','ButtonPushedFcn',@(~,~)obj.requestClose());
            obj.PreviousStateCallback=controller.OnStateChanged;
            obj.PreviousProgressCallback=controller.OnProgress;
            obj.PreviousMessageCallback=controller.OnMessage;
            controller.OnStateChanged=@(~,status)obj.dispatch(obj.PreviousStateCallback,status);
            controller.OnProgress=@(~,status)obj.dispatch(obj.PreviousProgressCallback,status);
            controller.OnMessage=@(~,status)obj.dispatch(obj.PreviousMessageCallback,status);
            obj.render(controller.getStatus(),true);
        end
        function delete(obj)
            if ~isempty(obj.Controller) && isvalid(obj.Controller)
                obj.Controller.OnStateChanged=obj.PreviousStateCallback;
                obj.Controller.OnProgress=obj.PreviousProgressCallback;
                obj.Controller.OnMessage=obj.PreviousMessageCallback;
            end
            if ~isempty(obj.Figure) && isvalid(obj.Figure), delete(obj.Figure); end
        end
    end
    methods (Access=private)
        function start(obj)
            try, obj.Controller.start(); catch exception, obj.ErrorLabel.Text=['Last error: ' exception.message]; end
        end
        function dispatch(obj,previous,status)
            obj.render(status,false);
            if ~isempty(previous)
                try, previous(obj.Controller,status); catch exception
                    warning('IMU:CalibrationCallbackFailed','Dashboard chained callback failed: %s',exception.message);
                end
            end
        end
        function render(obj,status,force)
            nowValue=datetime('now','TimeZone','UTC');
            if ~force && ~isnat(obj.LastRenderedAt) && seconds(nowValue-obj.LastRenderedAt)<0.10, return; end
            obj.LastRenderedAt=nowValue;
            obj.StateLabel.Text=char(status.state);
            obj.MessageLabel.Text=char(status.message);
            obj.ProgressGauge.Value=100*status.progress;
            obj.QualityLabel.Text=sprintf('Quality: %s',obj.number(status.quality));
            obj.VerificationLabel.Text=sprintf('Verification: %s',obj.number(status.verification));
            if isempty(status.lastError), obj.ErrorLabel.Text='Last error: —';
            else, obj.ErrorLabel.Text=['Last error: ' status.lastError.message]; end
            if status.state=="IDLE", obj.StartButton.Enable='on'; else, obj.StartButton.Enable='off'; end
            if status.isRunning, obj.CancelButton.Enable='on'; obj.CloseButton.Enable='off';
            else, obj.CancelButton.Enable='off'; obj.CloseButton.Enable='on'; end
        end
        function requestClose(obj)
            status=obj.Controller.getStatus();
            if status.isRunning
                answer=questdlg('Cancel the running calibration?','Calibration','Cancel calibration','Keep running','Keep running');
                if ~strcmp(answer,'Cancel calibration'), return; end
                obj.Controller.cancel();
            end
            if ~isempty(obj.Figure) && isvalid(obj.Figure), delete(obj.Figure); obj.Figure=[]; end
        end
    end
    methods (Static,Access=private)
        function text=number(value)
            if isnan(value), text='—'; else, text=sprintf('%.3f',value); end
        end
    end
end
