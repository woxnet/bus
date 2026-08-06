classdef TestAcceptanceVisualizationObserver < matlab.unittest.TestCase
    methods(TestClassSetup)
        function setup(~), root=fileparts(fileparts(mfilename('fullpath'))); addpath(fullfile(root,'src'),fullfile(root,'tests')); end
    end
    methods(Test)
        function observerReceivesAllFullAcceptanceStages(testCase)
            directory=tempname; mkdir(directory); testCase.addTeardown(@()rmdir(directory,'s'));
            probe=FullAcceptanceProbe(directory); stages=strings(0,1);
            options=struct('Dependencies',probe.dependencies(),'ArtifactDirectory',directory,'Observer',@observe);
            result=runFullImuHardwareAcceptance(options); testCase.verifyTrue(result.success);
            required=["bootstrap","class_api","commit_check","installation_calibration","runtime_fifo","realtime_monitor","summary_validation","artifact_save"];
            testCase.verifyTrue(all(ismember(required,stages)));
            function observe(event), stages(end+1,1)=event.stage; end
        end
        function observerFailureDoesNotFailAcceptance(testCase)
            directory=tempname; mkdir(directory); testCase.addTeardown(@()rmdir(directory,'s'));
            probe=FullAcceptanceProbe(directory); options=struct('Dependencies',probe.dependencies(), ...
                'ArtifactDirectory',directory,'Observer',@(~)error('Test:Observer','failure'));
            state=warning('off','IMU:AcceptanceObserverFailed'); cleanup=onCleanup(@()warning(state)); %#ok<NASGU>
            result=runFullImuHardwareAcceptance(options); testCase.verifyTrue(result.success); testCase.verifyNotEmpty(result.observerWarnings);
        end
        function childPhasesDeliverLiveProgressWithoutDuplicateBoundaries(testCase)
            directory=tempname; mkdir(directory); testCase.addTeardown(@()rmdir(directory,'s'));
            probe=FullAcceptanceProbe(directory); dependencies=probe.dependencies(); eventCells=cell(0,1);
            dependencies.runCalibration=@calibration; dependencies.runRuntime=@runtime; dependencies.runRealtime=@realtime;
            options=struct('Dependencies',dependencies,'ArtifactDirectory',directory,'Observer',@observe);
            result=runFullImuHardwareAcceptance(options); testCase.verifyTrue(result.success); events=vertcat(eventCells{:});
            for stage=["installation_calibration","runtime_fifo","realtime_monitor"]
                stageEvents=events(string({events.stage})==stage);
                testCase.verifyEqual(sum(string({stageEvents.type})=="stage_started"),1);
                testCase.verifyEqual(sum(string({stageEvents.type})=="stage_completed"),1);
            end
            runtimeEvents=events(string({events.stage})=="runtime_fifo");
            realtimeEvents=events(string({events.stage})=="realtime_monitor");
            testCase.verifyTrue(any(string({runtimeEvents.type})=="stage_progress"));
            testCase.verifyTrue(any(string({realtimeEvents.type})=="stage_progress"));
            function report=calibration(child)
                emitPhase(child,"installation_calibration"); report=probe.common();
                report.calibrationFile=string(probe.CalibrationFile); report.verification=struct('success',true);
            end
            function report=runtime(child)
                emitPhase(child,"runtime_fifo"); report=probe.common(); report.samplesReadMatchesReceived=true;
                report.stopDrainTimedOut=false; report.finalBufferedSamples=0;
            end
            function report=realtime(child), emitPhase(child,"realtime_monitor"); report=probe.common(); end
            function emitPhase(child,stage)
                child.Observer(event("stage_started",stage,0));
                child.Observer(event("stage_progress",stage,.5));
                child.Observer(event("stage_completed",stage,1));
            end
            function value=event(type,stage,progress)
                value=struct('timestamp',datetime('now','TimeZone','UTC'),'type',type,'stage',stage, ...
                    'state',"RUNNING",'progress',progress,'message',"live",'payload',struct());
            end
            function observe(value), eventCells{end+1,1}=value; end
        end
    end
end
