function [MOpVolume_mm3, lesion_volume, FallCountper10min]=Output_histology_selectedAnimal(AnimalID)
P = local_paths();                 % machine-specific data locations (see local_paths.example.m)
CCF_Dir  = dir(P.LesionMapGlob);
BasePath = P.BehaviorBase;
OpeData = load(fullfile(BasePath, 'InfarctionShamIDdata.mat'));

if sum(strcmp(OpeData.InfarctionData.AnimalID, AnimalID))==0
    MOpVolume_mm3 = 0;
    lesion_volume = 0;
    SelID = find(strcmp({OpeData.FallCount_LeftForeF.AnimalID}, AnimalID));
    FPS = 47;
    FallCountperFrame = OpeData.FallCount_LeftForeF(SelID).FallCountCuration./OpeData.FallCount_LeftForeF(SelID).TotalFrame;
    FallCountper10min = FallCountperFrame*FPS*60*10;
else
MOpVolume_mm3 = OpeData.InfarctionData.M1_InfarcSize_mm3(strcmp(OpeData.InfarctionData.AnimalID, AnimalID));
lesion_volume = OpeData.InfarctionData.Total_InfarcSize_mm3(strcmp(OpeData.InfarctionData.AnimalID, AnimalID));


List = 1:length(OpeData.InfarctionData.AnimalID);
Selectednum = List(strcmp(OpeData.InfarctionData.AnimalID, AnimalID));

load(fullfile(CCF_Dir(Selectednum).folder, CCF_Dir(Selectednum).name))

% Calculate the center of mass of lesionArea_TopView
lesionArea = lesion_ccf.lesionArea_TopView;
center_of_mass = mean(lesionArea, 1); % Compute the mean of x and y coordinates
% disp(['Center of Mass: (' num2str(center_of_mass(1)) ', ' num2str(center_of_mass(2)) ')']);

IDacronymlist = lesion_ccf.lesion_areas.acronym;
% IDacronymlistの中の数値より前の文字列を取得
IDacronymlist = cellfun(@(x) x(1:find(isstrprop(x,'digit'),1)-1), IDacronymlist, 'UniformOutput', false);
IDacronymlist_unique = unique(IDacronymlist);
IDacronymlist_unique = IDacronymlist_unique(~cellfun('isempty', IDacronymlist_unique));
% IDacronymlistに含まれるIDacronymlist_uniqueの要素の数を数える
IDacronymlist_count = cellfun(@(x) sum(strcmp(IDacronymlist, x)), IDacronymlist_unique, 'UniformOutput', false);
% IDacronymlist_uniqueの要素の数が多い順に並び替える
[IDacronymlist_count, idx] = sort(cell2mat(IDacronymlist_count), 'descend');
IDacronymlist_unique = IDacronymlist_unique(idx);

% IDacronymlist_countの要素数の円グラフを描画
fig = figure;
t = tiledlayout(1,2);
nexttile
% subplot(1,2,1)
piechart(IDacronymlist_count, IDacronymlist_unique)
title([AnimalID ', Volume=' num2str(lesion_volume) ' mm^3']);

nexttile
% subplot(1,2,2)
imagesc(Area_mapRGB)
axis equal off
hold on
curr_lesion = 1;
patch('XData',lesion_ccf(curr_lesion).lesionArea_TopView(:,1), 'YData', lesion_ccf(curr_lesion).lesionArea_TopView(:,2), 'EdgeColor', 'r','FaceColor','r','FaceAlpha',0.3, 'LineWidth', 1)
plot(570, 540, 'r+', 'MarkerSize', 15)
plot(570, 540, 'ro', 'MarkerFaceColor', 'r')
plot([100, 200], [100, 100], 'w-', 'LineWidth', 2)
center_of_mass_BregmaOrig = round([center_of_mass(1)-570, 540-center_of_mass(2)])*10;
text(0, size(Area_mapRGB, 1)+50, ['L A = ' num2str(center_of_mass_BregmaOrig) ' (mm)'])
title([AnimalID ', MOp Volume=' num2str(MOpVolume_mm3) ' mm^3']);

disp(['Lesion of ' AnimalID ' volume: ' num2str(MOpVolume_mm3) ' mm^3' ' (' num2str(lesion_volume) ' mm^3)'])

% List = 1:length(OpeData.InfarctionData.AnimalID);
SelID = find(strcmp({OpeData.FallCount_LeftForeF.AnimalID}, AnimalID));
% SelID = List(strcmp(OpeData.InfarctionData.AnimalID, AnimalID));
FPS = 47;
FallCountperFrame = OpeData.FallCount_LeftForeF(SelID).FallCountCuration./OpeData.FallCount_LeftForeF(SelID).TotalFrame;
FallCountper10min = FallCountperFrame*FPS*60*10;
text(0, size(Area_mapRGB, 1)+150, ['FallCount/10min = ' num2str(round(mean(FallCountper10min(2:end))*10)/10)])
text(0, size(Area_mapRGB, 1)+250, [num2str(round(FallCountper10min(2:end)*10)/10)])
end
