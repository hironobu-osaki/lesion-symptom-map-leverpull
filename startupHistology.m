%% Set path

% Add MVGC root directory and appropriate subdirectories to path

location = which('startupHistology.m');
Histology_root = fullfile(fileparts(location), 'AP_histology-master');

% essentials
addpath(Histology_root);
addpath(fullfile(Histology_root,'+ap_histology'));
addpath(fullfile(Histology_root,'allenCCF_repo_functions'));
addpath(fullfile(fileparts(Histology_root), 'AllenCCF'));

AP_histology

