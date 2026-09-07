function [Area_mapRGB] = AllenMapTopView
mf = mfilename('fullpath');

load(fullfile(fileparts(fileparts(mf)), 'AP_histology-master', 'allenCCF_repo_functions', 'allen_ccf_colormap_2017.mat'))
AV_index = readNPY(fullfile(fileparts(fileparts(mf)), 'AllenCCF', 'annotation_volume_10um_by_index.npy'));
structureTreeTable = loadStructureTree(fullfile(fileparts(fileparts(mf)), 'AllenCCF', 'structure_tree_safe_2017.csv'));
AVindex = double(AV_index);

IDacronymlistAll = structureTreeTable.acronym;
% Extract ID without layer info
IDacronymlist_Extract = cellfun(@(x) x(1:find(isstrprop(x,'digit'),1)-1), IDacronymlistAll, 'UniformOutput', false);
IDacronymlist_min = unique(IDacronymlist_Extract);
IDnumAllbase = structureTreeTable.index;
IDnumAll = IDnumAllbase;
% Convert ID with layer info into ID of surface (layer1)
for cll = 1:length(unique(IDacronymlist_Extract))
    IDnum = IDnumAll(cellfun(@(x) strcmp(x, IDacronymlist_min{cll}), IDacronymlist_Extract));
    if IDnum(1)==0
    else
        for dll = 2:length(IDnum)
            IDnumAll(IDnumAll == IDnum(dll))=IDnum(1);
        end
    end
end


APx = 1:1320;
MLy = 1:1080;

% find ID of brain surface from top view
% use cmap of Allen CCF
Area_mapRGB = zeros(length(APx), length(MLy), 3);
Area_mapIndex = zeros(length(APx), length(MLy));
k = 1;
for i = 1:length(APx)
    for j = 1:length(MLy)
        Zindex = AVindex(APx(i),10:300,MLy(j));
        if find(Zindex>1, 1)
            index = AVindex(APx(i),find(Zindex>1, 1)+50,MLy(j));
            Area_mapIndex(i, j) = IDnumAll(index)+1;

            Area_mapRGB(i, j, 1) = cmap(IDnumAll(index)+1,1);
            Area_mapRGB(i, j, 2) = cmap(IDnumAll(index)+1,2);
            Area_mapRGB(i, j, 3) = cmap(IDnumAll(index)+1,3);

        else
            Area_mapRGB(i, j, 1) = 0;
            Area_mapRGB(i, j, 2) = 0;
            Area_mapRGB(i, j, 3) = 0;
        end
        k = k + 1;
    end
end

% Area_mapIndex
% Draw boundary lines where adjacent values in Area_mapIndex are different
boundary_map = zeros(size(Area_mapIndex));
for i = 1:size(Area_mapIndex, 1)-1
    for j = 1:size(Area_mapIndex, 2)-1
        if Area_mapIndex(i, j) ~= Area_mapIndex(i+1, j) || Area_mapIndex(i, j) ~= Area_mapIndex(i, j+1)
            boundary_map(i, j) = 1;
        end
    end
end

% Overlay boundary lines on the RGB map
for i = 1:size(boundary_map, 1)
    for j = 1:size(boundary_map, 2)
        if boundary_map(i, j) == 1
            Area_mapRGB(i, j, :) = [0, 0, 0]; % black for boundaries
        end
    end
end

% figure, imagesc(Area_mapRGB)
% axis equal off
