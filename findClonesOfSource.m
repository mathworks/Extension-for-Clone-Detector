% Copyright 2023 The MathWorks, Inc.

function [cloneResults, status] = findClonesOfSource(sourceBlocksPath, targetScopeList)
    status = 1;
    if isempty(sourceBlocksPath)
        status = -1; %#ok
        error('%s: %s\n', "Invalid input", "Provide a block pattern to find clones.");
    end

    if isempty(targetScopeList)
        status = -1; %#ok
        error('%s: %s\n', "Invalid input", "Provide a target scope to find clones.");
    end

    fprintf('### %s: %s\n', "Clone Detection", "Starting Clone Detection");

    % Create a temporary library with a unique name
    [~, tempLibraryName] = createTempLibraryAndSubsys(sourceBlocksPath);
    
    % Detect Clones with Clone Detection APIs - MATLAB R2021a or later
    % Performing a library based clone detection.
    cloneSettings = Simulink.CloneDetection.Settings();
    cloneSettings.addLibraries(tempLibraryName);
    cloneResults.Source = sourceBlocksPath;
    cloneResults.Clones = 0;
    cloneResults.BlocksInAllClones = 0;
    clonePatterns = struct('ModelName', {}, 'ClonePattern', {});
    targetScopeModelList = [];
    
    % onCleanup callback to remove added folders from path:
    cleanupObjects = cell(1, length(targetScopeList));
    % Get the current MATLAB search path
    searchPath = matlabpath;
    
    % Convert the search path to a cell array of strings
    pathList = strsplit(searchPath, pathsep);
    
    % Get all the models in the target search scope:
    for index = 1 : length(targetScopeList)
        fprintf('### %s: %s\n', "Clone Detection", "Collecting list of models from the target scope.");
        try
            targetScopeModelFilesLocal = [];
            if isfolder(targetScopeList{index})
                folderPath = targetScopeList{index};
                % Check if the folder path is in the search path
                isInSearchPath = ismember(folderPath, pathList);
                if ~(isInSearchPath) % When the folder path is not already in the search path
                    addpath(folderPath);
                    cleanupObjects{index} = onCleanup(@() rmpath(folderPath));
                end
                
                dirData = dir(folderPath);
                for i=1:length(dirData)
                    if strcmp(dirData(i).name,'.') || strcmp(dirData(i).name,'..')
                        continue;
                    end
                    if isfile([folderPath filesep dirData(i).name])
                        [~, ~, ext] = fileparts(dirData(i).name);
    
                        if ((strcmp(ext,'.slx') ||  strcmp(ext,'.mdl')) &&...
                                                    ~(Simulink.MDLInfo([folderPath filesep dirData(i).name]).IsLibrary))
                             targetScopeModelFilesLocal = [targetScopeModelFilesLocal; {[folderPath filesep dirData(i).name]}];
                        end
                    end
                end
            elseif isfile(targetScopeList{index})
                targetScopeModelFilesLocal =[targetScopeModelFilesLocal; {targetScopeList{index}}];
            end
            targetScopeModelList = unique([targetScopeModelList; targetScopeModelFilesLocal]);
        catch exception
            status = 0; 
            warning('### %s: %s\n', "Clone Detection",...
                sprintf("Target Scope information is incorrect."));
            warning('### %s: %s\n', "Clone Detection",...
                exception.message);
        end
    end

    % Do a library clone detection looping over all models and compile the
    % results
    indexModelForClones = 1;
    for index = 1 : length(targetScopeModelList)
        try
            fprintf('### %s: %s\n', "Clone Detection",...
                sprintf("Detecting clones in %s model", targetScopeModelList{index}));

            cloneResultsPerModel = Simulink.CloneDetection.findClones(targetScopeModelList{index}, cloneSettings);
        catch ex
            status = 0;
            warning('### %s: %s\n', "Clone Detection",...
                sprintf("Error during clone detection for model %s", targetScopeModelList{index}));
            warning(ex.message);
            continue;
        end
        if ~isempty(cloneResultsPerModel.Clones)
            clonePatterns(indexModelForClones).ModelName = targetScopeModelList{index};
            cloneResults.Clones = cloneResults.Clones + cloneResultsPerModel.Clones.Summary.Clones;
            cloneResults.BlocksInAllClones = cloneResults.BlocksInAllClones + (cloneResultsPerModel.Clones.CloneGroups.Summary.Clones * cloneResultsPerModel.Clones.CloneGroups.Summary.BlocksPerClone);
            for len = 1 : length(cloneResultsPerModel.Clones.CloneGroups.CloneList)
                clonePatterns(indexModelForClones).ClonePattern{len} = cloneResultsPerModel.Clones.CloneGroups.CloneList{len}.PatternBlocks;
            end
            indexModelForClones = indexModelForClones + 1;
        end
    end

    cloneResults.CloneList = clonePatterns;
    % Remove the temporary library
    bdclose(tempLibraryName);
    delete([tempLibraryName, '.slx']);

    fprintf('### %s: %s\n', "Clone Detection", "Clone Detection is complete.");
end

function [tempSubsysFullPath, tempLibraryName] = createTempLibraryAndSubsys(blockList)
    % Create a temporary library tempLibraryName
    % Copy the contents of a subsystem sourceModel/xyz from sourceModel
    % model to the tempLibraryName
    % Create a subsystem tempChildSubsysFullPath in the temp library 
    % selecting the list of blocks blockList, then move that to 
    % the top level remove the library link.
    % Delete the tempChildSubsysFullPath.

    % Create a temporary library
    datetimeStr = string(datetime('now','TimeZone','local','Format', 'yyyy_MM_dd_hh_mm_ss_SSS'));
    tempLibraryName = char(strcat('tempLibrary_', datetimeStr));
    new_system(tempLibraryName, 'Library');

    % Derive the subsystem name from blocks list:
    if isempty(blockList)
        return
    end

    firstBlock = blockList{1};
    
    % loading the block diagram if not loaded
    bdName = strtok(firstBlock, '/');
    if ~bdIsLoaded(bdName)
        load_system(bdName)
    end
    sourceSubsysPath = get_param(firstBlock, 'parent');
    sourceSubsysName = get_param(sourceSubsysPath, 'name');
    tempSubsystemPath = [tempLibraryName, '/', sourceSubsysName];
    if strcmp(sourceSubsysPath, sourceSubsysName)
        add_block('built-in/Subsystem', tempSubsystemPath);
        Simulink.BlockDiagram.copyContentsToSubsystem(sourceSubsysPath, tempSubsystemPath);
    else
        add_block(sourceSubsysPath, tempSubsystemPath);
    end

    try
        save_system(tempLibraryName);
    catch
        error('You do not have write permission in the current working directory.');
    end

    % Find the block handles of the blocks to be included in the new subsystem
    blockHandles = [];
    for i = 1:length(blockList)
        blockName = get_param(blockList{i}, 'name');
        blockPath = [tempSubsystemPath, '/', blockName];
        if ~isempty(find_system(tempLibraryName, 'SearchDepth', 2, 'LookUnderMasks','on','FollowLinks','on', 'Name', blockName)) % should look under mask g3001076
            blockHandles = [blockHandles, get_param(blockPath, 'Handle')];
        else
            error(['Block "', blockName, '" not found in the source subsystem.']);
        end
    end

    % Create the new subsystem in the tempLibraryName with the selected blocks
    tempSubsysName = char(strcat('tempSubsys_', datetimeStr));
    Simulink.BlockDiagram.createSubsystem(blockHandles, 'MakeNameUnique', 'on', 'Name', tempSubsysName);
    tempChildSubsysFullPath = [tempSubsystemPath '/' tempSubsysName];
    tempSubsysFullPath = [tempLibraryName, '/', tempSubsysName];

    % Copy the subsystem from the subsystem to the top level in the
    % library.
    add_block(tempChildSubsysFullPath, tempSubsysFullPath);
    set_param(tempSubsysFullPath, 'LinkStatus', 'none');

    % Remove the draft subsystem which was copied from the model
    delete_block(tempSubsystemPath);
    
    save_system(tempLibraryName);
end

