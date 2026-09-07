
Children = uigetdir([],'Select path of .png files');
if ispc
    Paths = dir([fileparts(Children) '\*\*.png']);
elseif ismac
    Paths = dir([fileparts(Children) '/*/*.png']);
end
disp(fullfile(Paths(1).folder))
disp(fullfile(Paths(1).name))
for i = 1:length(Paths)
    copyfile(fullfile(Paths(i).folder, Paths(i).name), fileparts(Paths(i).folder))
    % copyした際にファイル名をslice_*.pngに変更
    movefile(fullfile(fileparts(Paths(i).folder), Paths(i).name), fullfile(fileparts(Paths(i).folder), ['slice_' num2str(i) '.png']))
end
disp('Done')