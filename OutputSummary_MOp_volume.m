
OutputGIF = 0;
P = local_paths();                 % machine-specific data locations (see local_paths.example.m)
CCF_Dir  = dir(P.LesionMapGlob);   % .../<animal>/CCF/LesionMapAllenCCF.mat for every animal
BasePath = P.BehaviorBase;         % folder containing InfarctionShamIDdata.mat
OpeData = load(fullfile(BasePath, 'InfarctionShamIDdata.mat'));

figure('Name','Lesion function map')

for i = 1:length(CCF_Dir)
    load(fullfile(CCF_Dir(i).folder, CCF_Dir(i).name))
    [~, ID] = fileparts(fileparts(CCF_Dir(i).folder));
    lesion_ccf_all(i).lesion_ccf = lesion_ccf;
    lesion_ccf_all(i).ID = ID;
    if i == 1
        imagesc(Area_mapRGB)
    end
    axis equal off
    hold on
    curr_lesion = 1;
    patch('XData',lesion_ccf(curr_lesion).lesionArea_TopView(:,1), 'YData', lesion_ccf(curr_lesion).lesionArea_TopView(:,2), 'EdgeColor', 'none','FaceColor','r','FaceAlpha',0.3, 'LineWidth', 1)
    plot(570, 540, 'r+', 'MarkerSize', 15)
    plot(570, 540, 'ro', 'MarkerFaceColor', 'r')
    plot([100, 200], [100, 100], 'w-', 'LineWidth', 2)
    % title(ID)


end

% Small_M1_Infarc = [];
% Large_M1_Infarc = [];
% Large_Infarc = [];
% Small_M1_Infarc_mm3 = [];
% Large_M1_Infarc_mm3 = [];
% Large_Infarc_mm3 = [];

Total_InfarcSize_mm3 = [];
M1_InfarcSize_mm3 = [];
AnimalID = [];

for i = 1:length(CCF_Dir)
    lesion_ccf = lesion_ccf_all(i).lesion_ccf;
    ID = lesion_ccf_all(i).ID;


    slice_width = 50*0.001;
    lesion_volume = sum(lesion_ccf(curr_lesion).lesion_area_size)*0.010*0.010*slice_width; % 1 voxel = 10x10um = 0.01mm*0.01mm in CCF v3


    LesionInd = lesion_ccf(curr_lesion).lesion_areas.index;
    [sortidx] = sortrows(lesion_ccf(curr_lesion).lesion_areas);
    IDindexlist = unique(lesion_ccf(curr_lesion).lesion_areas.index);
    IDacronymlist = lesion_ccf(curr_lesion).lesion_areas.acronym;
    % IDacronymlistの中の数値より前の文字列を取得
    IDacronymlist = cellfun(@(x) x(1:find(isstrprop(x,'digit'),1)-1), IDacronymlist, 'UniformOutput', false);
    IDacronymlist_unique = unique(IDacronymlist);
    IDacronymlist_unique = IDacronymlist_unique(~cellfun('isempty', IDacronymlist_unique));
    % IDacronymlistに含まれるIDacronymlist_uniqueの要素の数を数える
    IDacronymlist_count = cellfun(@(x) sum(strcmp(IDacronymlist, x)), IDacronymlist_unique, 'UniformOutput', false);
    % IDacronymlist_uniqueの要素の数が多い順に並び替える
    [IDacronymlist_count, idx] = sort(cell2mat(IDacronymlist_count), 'descend');
    IDacronymlist_unique = IDacronymlist_unique(idx);
    IDacronymlist_volume_mm3 = IDacronymlist_count/sum(IDacronymlist_count)*lesion_volume;
    % IDacronymlist_countの要素数の円グラフを描画
    fig = figure;
    t = tiledlayout(1,2);
    nexttile
    % subplot(1,2,1)
    piechart(IDacronymlist_count, IDacronymlist_unique)
    title([ID ', Volume=' num2str(lesion_volume) ' mm^3']);
    if sum(strcmp(IDacronymlist_unique, 'MOp'))
        MOpVolume_mm3 = lesion_volume*IDacronymlist_count(strcmp(IDacronymlist_unique, 'MOp'))/sum(IDacronymlist_count);
        lesion_ccf_all(i).MOpVolume_mm3 = MOpVolume_mm3;
        lesion_ccf_all(i).MOpVolume_ratio = IDacronymlist_count(strcmp(IDacronymlist_unique, 'MOp'))/sum(IDacronymlist_count);
    end
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
    title([ID ', MOp Volume=' num2str(MOpVolume_mm3) ' mm^3']);
    
    AnimalID{end+1} = ID;
    M1_InfarcSize_mm3(end+1) = MOpVolume_mm3;
    Total_InfarcSize_mm3(end+1) = lesion_volume;
    disp(['Lesion of ' ID ' volume: ' num2str(MOpVolume_mm3) ' mm^3' ' (' num2str(lesion_volume) ' mm^3)'])
    % save('figure_handle.mat', 'fig', 't'); % ハンドルを保存
    % FigAppend = 1;
    % close(fig)

    % ForeLimb_Zdistance_fromPole(OpeData, ID, getfield(OpeData.OpeType, ID), 'LeftForeF');
    % ForeLimb_Zdistance_fromPole(OpeData, ID, getfield(OpeData.OpeType, ID), 'RightForeF');
    % ForeLimb_Zdistance_fromPole(OpeData, ID, getfield(OpeData.OpeType, ID), 'LeftHindF');
    % ForeLimb_Zdistance_fromPole(OpeData, ID, getfield(OpeData.OpeType, ID), 'RightHindF');


end
InfarctionData.AnimalID = AnimalID;
InfarctionData.M1_InfarcSize_mm3 = M1_InfarcSize_mm3;
InfarctionData.Total_InfarcSize_mm3 = Total_InfarcSize_mm3;
save(fullfile(BasePath, 'InfarctionShamIDdata.mat'), '-append', 'InfarctionData');


if OutputGIF
    SelectAnimalID = 'OM40';
    CCF_Dir = dir(strrep(P.LesionMapGlob, 'OM*', SelectAnimalID));
    filename = fullfile(CCF_Dir(1).folder, [SelectAnimalID 'TestGIF.gif']);
    sizen= 256;
    load(fullfile(CCF_Dir(1).folder, CCF_Dir(1).name))
    % Plot lesion areas
    h = figure('Name','lesion 3D');
    axes_atlas = axes;
    [~, brain_outline] = plotBrainGrid([],axes_atlas);
    set(axes_atlas,'ZDir','reverse');
    hold(axes_atlas,'on');
    axis vis3d equal off manual
    % view([-30,25]);
    view([200,30]);

    drawnow  % figureを更新する
    % Capture the plot as an image
    frame = getframe(h);
    im = frame2im(frame);

    [imind,cm] = rgb2ind(im,sizen);

    delaytime = 2;
    % Write to the GIF File
    imwrite(imind,cm,filename,'gif', 'Loopcount',1,'DelayTime',delaytime);

    plot3(540, 570, 70, 'ro', 'MarkerFaceColor', 'r')
    plot3(540, 570, 70, 'r+', 'MarkerSize', 15)
    plot3([100, 200], [100, 100], [100, 100], 'r-', 'LineWidth', 2)
    plot3([100, 100], [100, 100], [100, 200], 'r-', 'LineWidth', 2)
    plot3([100, 100], [100, 200], [100, 100], 'r-', 'LineWidth', 2)

    drawnow  % figureを更新する
    % Capture the plot as an image
    frame = getframe(h);
    im = frame2im(frame);

    [imind,cm] = rgb2ind(im,sizen);

    pause(2);
    delaytime = 0.1;
    % Write to the GIF File
    imwrite(imind,cm,filename,'gif','WriteMode','append','DelayTime',delaytime);

    for curr_lesion = 1:length(lesion_ccf)

        AP = lesion_ccf(curr_lesion).points(:,1);
        AP_unique = unique(AP);
        for currAP = 1:length(AP_unique)
            idx = find(AP == AP_unique(currAP));
            DV = lesion_ccf(curr_lesion).points(idx,2);
            ML = lesion_ccf(curr_lesion).points(idx,3);
            AZZ = ones(length(DV),1)*AP_unique(currAP);
            patch('XData',AZZ,'YData',ML, 'ZData', DV,  'EdgeColor', 'b','FaceColor','b','FaceAlpha',0.3, 'LineWidth', 1)
        end

    end

    for i = 1:40+71
        view([200+5*i,30]);
        drawnow  % figureを更新する
        % Capture the plot as an image
        frame = getframe(h);
        im = frame2im(frame);
        [imind,cm] = rgb2ind(im,sizen);
        pause(1)
        imwrite(imind,cm,filename,'gif','WriteMode','append','DelayTime',delaytime);
    end

    for i = 1:10
        view([400+5*i,30+6*i]);
        drawnow  % figureを更新する
        % Capture the plot as an image
        frame = getframe(h);
        im = frame2im(frame);
        [imind,cm] = rgb2ind(im,sizen);
        pause(1)
        imwrite(imind,cm,filename,'gif','WriteMode','append','DelayTime',delaytime);
    end
    disp(['GIF file was saved at ' filename])

    %%
    filename = fullfile(CCF_Dir(1).folder, [SelectAnimalID 'TestGIFloop.gif']);
    sizen= 256;
    load(fullfile(CCF_Dir(1).folder, CCF_Dir(1).name))
    % Plot lesion areas
    h = figure('Name','lesion 3D');
    axes_atlas = axes;
    [~, brain_outline] = plotBrainGrid([],axes_atlas);
    set(axes_atlas,'ZDir','reverse');
    hold(axes_atlas,'on');
    axis vis3d equal off manual
    % view([-30,25]);
    view([200,30]);

    drawnow  % figureを更新する
    % Capture the plot as an image
    frame = getframe(h);
    im = frame2im(frame);

    [imind,cm] = rgb2ind(im,sizen);

    delaytime = 2;
    % Write to the GIF File

    plot3(540, 570, 70, 'ro', 'MarkerFaceColor', 'r')
    plot3(540, 570, 70, 'r+', 'MarkerSize', 15)
    plot3([100, 200], [100, 100], [100, 100], 'r-', 'LineWidth', 2)
    plot3([100, 100], [100, 100], [100, 200], 'r-', 'LineWidth', 2)
    plot3([100, 100], [100, 200], [100, 100], 'r-', 'LineWidth', 2)

    drawnow  % figureを更新する
    % Capture the plot as an image
    frame = getframe(h);
    im = frame2im(frame);

    [imind,cm] = rgb2ind(im,sizen);

    pause(2);
    delaytime = 0.1;
    % Write to the GIF File


    plot3(540, 570, 70, 'ro', 'MarkerFaceColor', 'r')
    plot3(540, 570, 70, 'r+', 'MarkerSize', 15)
    plot3([100, 200], [100, 100], [100, 100], 'r-', 'LineWidth', 2)
    plot3([100, 100], [100, 100], [100, 200], 'r-', 'LineWidth', 2)
    plot3([100, 100], [100, 200], [100, 100], 'r-', 'LineWidth', 2)

    drawnow  % figureを更新する
    % Capture the plot as an image
    frame = getframe(h);
    im = frame2im(frame);

    [imind,cm] = rgb2ind(im,sizen);

    pause(2);
    delaytime = 0.1;
    % Write to the GIF File
    imwrite(imind,cm,filename,'gif', 'Loopcount',inf,'DelayTime',delaytime);


    for curr_lesion = 1:length(lesion_ccf)

        AP = lesion_ccf(curr_lesion).points(:,1);
        AP_unique = unique(AP);
        for currAP = 1:length(AP_unique)
            idx = find(AP == AP_unique(currAP));
            DV = lesion_ccf(curr_lesion).points(idx,2);
            ML = lesion_ccf(curr_lesion).points(idx,3);
            AZZ = ones(length(DV),1)*AP_unique(currAP);
            patch('XData',AZZ,'YData',ML, 'ZData', DV,  'EdgeColor', 'b','FaceColor','b','FaceAlpha',0.3, 'LineWidth', 1)
        end

    end

    for i = 1:71
        view([200+5*i,30]);
        drawnow  % figureを更新する
        % Capture the plot as an image
        frame = getframe(h);
        im = frame2im(frame);
        [imind,cm] = rgb2ind(im,sizen);
        pause(1)
        imwrite(imind,cm,filename,'gif','WriteMode','append','DelayTime',delaytime);
    end
end