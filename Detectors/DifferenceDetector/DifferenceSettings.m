function edited = DifferenceSettings(differenceDetector, varargin)
    handles.detector = differenceDetector;
    handles.reporters = differenceDetector.controller.reporters;
    
    if length(handles.reporters) < 2
        msgbox('You must annotate, detect or import other features before you can detect their differences.', 'Differenc Detector', 'warn', 'modal');
        edited = false;
    else
        editable = (nargin == 1 || (strcmp(varargin{1}, 'Editable') && varargin{2}));
        
        handles.figure = dialog(...
            'Units', 'points', ...
            'Name', 'Difference Settings', ...
            'Position', [100, 100, 350, 250], ...
            'Visible', 'off', ...
            'WindowKeyPressFcn', @(hObject, eventdata)handleEditDifferenceKeyPress(hObject, eventdata, guidata(hObject)), ...
            'Tag', 'figure');
        
        % Add pop-up menus for picking the reporters to compare.
        uicontrol(...
            'Parent', handles.figure,...
            'Units', 'points', ...
            'FontSize', 12, ...
            'HorizontalAlignment', 'right', ...
            'Position', [10 216 130 18], ...
            'String',  'Compare:', ...
            'Style', 'text');
        handles.originalReporterPopup = uicontrol(...
            'Parent', handles.figure, ...
            'Units', 'points', ...
            'Position', [146 214 200 22], ...
            'Callback', @(hObject,eventdata)handleOriginalReporterPopupChanged(hObject, eventdata, guidata(hObject)), ...
            'String', cellfun(@(x)x.name(), handles.reporters, 'UniformOutput', false), ...
            'Style', 'popupmenu', ...
            'Value', 1, ...
            'Tag', 'originalReporterPopup');
        featureTypes = handles.reporters{1}.featureTypes();
        handles.originalFeatureTypePopup = uicontrol(...
            'Parent', handles.figure, ...
            'Units', 'points', ...
            'Position', [146 188 200 22], ...
            'String', featureTypes, ...
            'Style', 'popupmenu', ...
            'Value', 1, ...
            'Tag', 'pulseFeatureTypePopup');
        % Add a pop-up menu for picking the name of pulse features.
        uicontrol(...
            'Parent', handles.figure,...
            'Units', 'points', ...
            'FontSize', 12, ...
            'HorizontalAlignment', 'right', ...
            'Position', [10 152 130 18], ...
            'String',  'to:', ...
            'Style', 'text');
        handles.newReporterPopup = uicontrol(...
            'Parent', handles.figure, ...
            'Units', 'points', ...
            'Position', [146 150 200 22], ...
            'Callback', @(hObject,eventdata)handleNewReporterPopupChanged(hObject, eventdata, guidata(hObject)), ...
            'String', cellfun(@(x)x.name(), handles.reporters, 'UniformOutput', false), ...
            'Style', 'popupmenu', ...
            'Value', 2, ...
            'Tag', 'baseReporterPopup');
        featureTypes = handles.reporters{2}.featureTypes();
        handles.newFeatureTypePopup = uicontrol(...
            'Parent', handles.figure, ...
            'Units', 'points', ...
            'Position', [146 124 200 22], ...
            'String', featureTypes, ...
            'Style', 'popupmenu', ...
            'Value', 1, ...
            'Tag', 'pulseFeatureTypePopup');
        
        % Add fields for setting the thresholds.
        uicontrol(...
            'Parent', handles.figure,...
            'Units', 'points', ...
            'FontSize', 12, ...
            'HorizontalAlignment', 'right', ...
            'Position', [10 84 130 18], ...
            'String',  'Time threshold:', ...
            'Style', 'text');
        handles.timeThresholdEdit = uicontrol(...
            'Parent', handles.figure, ...
            'Units', 'points', ...
            'FontSize', 12, ...
            'HorizontalAlignment', 'left', ...
            'Position', [150 80 50 26], ...
            'String',  num2str(handles.detector.timeThreshold),...
            'Style', 'edit', ...
            'Tag', 'timeThreshold');
        uicontrol(...
            'Parent', handles.figure,...
            'Units', 'points', ...
            'FontSize', 12, ...
            'HorizontalAlignment', 'left', ...
            'Position', [205 84 130 18], ...
            'String',  'sec', ...
            'Style', 'text');
        uicontrol(...
            'Parent', handles.figure,...
            'Units', 'points', ...
            'FontSize', 12, ...
            'HorizontalAlignment', 'right', ...
            'Position', [10 44 130 18], ...
            'String',  'Frequency threshold:', ...
            'Style', 'text');
        handles.frequencyThresholdEdit = uicontrol(...
            'Parent', handles.figure, ...
            'Units', 'points', ...
            'FontSize', 12, ...
            'HorizontalAlignment', 'left', ...
            'Position', [150 40 50 26], ...
            'String',  num2str(handles.detector.frequencyThreshold),...
            'Style', 'edit', ...
            'Tag', 'frequencyThreshold');
        uicontrol(...
            'Parent', handles.figure,...
            'Units', 'points', ...
            'FontSize', 12, ...
            'HorizontalAlignment', 'left', ...
            'Position', [205 44 40 18], ...
            'String',  'Hz', ...
            'Style', 'text');
        
        handles.cancelButton = uicontrol(...
            'Parent', handles.figure,...
            'Units', 'points', ...
            'Callback', @(hObject,eventdata)handleCancelEditSettings(hObject,eventdata,guidata(hObject)), ...
            'Position', [350 - 56 - 10 - 56 - 10 10 56 20], ...
            'String', 'Cancel', ...
            'Tag', 'cancelButton');
        
        handles.saveButton = uicontrol(...
            'Parent', handles.figure,...
            'Units', 'points', ...
            'Callback', @(hObject,eventdata)handleSaveEditSettings(hObject,eventdata,guidata(hObject)), ...
            'Position', [350 - 10 - 56 10 56 20], ...
            'String', 'Save', ...
            'Tag', 'saveButton');
        
        if ~editable
            set(handles.originalReporterPopup, 'Enable', 'off');
            set(handles.originalFeatureTypePopup, 'Enable', 'off');
            set(handles.newReporterPopup, 'Enable', 'off');
            set(handles.newFeatureTypePopup, 'Enable', 'off');
            set(handles.timeThresholdEdit, 'Enable', 'off');
            set(handles.frequencyThresholdEdit, 'Enable', 'off');
        end
        
        movegui(handles.figure, 'center');
        set(handles.figure, 'Visible', 'on');
        
        guidata(handles.figure, handles);
        
        % Wait for the user to cancel or save.
        uiwait;
        
        if ishandle(handles.figure)
            handles = guidata(handles.figure);
            edited = handles.edited;
            close(handles.figure);
        else
            edited = false;
        end
    end
end


function handleOriginalReporterPopupChanged(~, ~, handles)
    i = get(handles.originalReporterPopup, 'Value');
    featureTypes = handles.reporters{i}.featureTypes();
    set(handles.originalFeatureTypePopup, 'String', featureTypes, 'Value', 1);
end


function handleNewReporterPopupChanged(~, ~, handles)
    i = get(handles.newReporterPopup, 'Value');
    featureTypes = handles.reporters{i}.featureTypes();
    set(handles.newFeatureTypePopup, 'String', featureTypes, 'Value', 1);
end


function handleEditDifferenceKeyPress(hObject, eventdata, handles)
    if strcmp(eventdata.Key, 'return')
        handleSaveEditSettings(hObject, eventdata, handles);
    elseif strcmp(eventdata.Key, 'escape')
        handleCancelEditSettings(hObject, eventdata, handles);
    end
end


function handleCancelEditSettings(~, ~, handles)
    handles.edited = false;
    guidata(handles.figure, handles);
    uiresume;
end


function handleSaveEditSettings(~, ~, handles)
    i = get(handles.originalReporterPopup, 'Value');
    handles.detector.originalReporter = handles.reporters{i};
    featureTypes = get(handles.originalFeatureTypePopup, 'String');
    i = get(handles.originalFeatureTypePopup, 'Value');
    handles.detector.originalFeatureName = featureTypes{i};
    
    i = get(handles.newReporterPopup, 'Value');
    handles.detector.newReporter = handles.reporters{i};
    featureTypes = get(handles.newFeatureTypePopup, 'String');
    i = get(handles.newFeatureTypePopup, 'Value');
    handles.detector.newFeatureName = featureTypes{i};
    
    if strcmp(handles.detector.originalFeatureName, handles.detector.newFeatureName)
        handles.detector.name = ['Differences: ' handles.detector.originalFeatureName];
    else
        handles.detector.name = ['Differences: ' handles.detector.originalFeatureName ' vs. ' handles.detector.newFeatureName];
    end
    
    handles.detector.timeThreshold = str2double(get(handles.timeThresholdEdit, 'String'));
    handles.detector.frequencyThreshold = str2double(get(handles.frequencyThresholdEdit, 'String'));
    
    handles.edited = true;
    guidata(handles.figure, handles);
    uiresume;
end
