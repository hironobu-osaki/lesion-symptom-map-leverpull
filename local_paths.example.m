function P = local_paths()
% local_paths.m — machine-specific data locations.
%
% Copy this file to local_paths.m (which is ignored by git) and fill in the
% paths for your machine. Every analysis script calls local_paths() instead of
% hard-coding server addresses or folder names.

% Data server (IP or hostname) that hosts the lab share used by
% LeverPullTask_InfVsSham.m. Leave empty to be prompted once; the answer is
% remembered with setpref('LeverPullTask','DataServerAddr',...).
P.DataServerAddr = '';

% Glob that matches LesionMapAllenCCF.mat for every animal, as produced by
% AP_histology (ap_histology.annotate_lesion). 'OM*' is replaced by an animal
% ID when a single animal is requested.
%   e.g. '\\server\share\ImagingData\DAPI_Data\*\OM*\CCF\LesionMapAllenCCF.mat'
P.LesionMapGlob = '';

% Folder that contains InfarctionShamIDdata.mat and one sub-folder per animal
% (e.g. <BehaviorBase>/OM62/Irregular/ExperimentalData.xml).
P.BehaviorBase = '';

% NOIO_summary_YYYYMMDD.xlsx: animal ID, lesion location, lesion size (mm3).
P.NOIOSummary = '';
end
