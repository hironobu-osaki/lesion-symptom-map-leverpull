function annotate_lesion(~,~,histology_toolbar_gui)
% Part of AP_histology toolbox
%
% Annotate Neuropixels tracts on slices and get CCF positions/regions

% Initialize guidata
gui_data = struct;

% Store toolbar handle
gui_data.histology_toolbar_gui = histology_toolbar_gui;

% Load atlas
allen_atlas_path = fileparts(which('template_volume_10um.npy'));
if isempty(allen_atlas_path)
    error('No CCF atlas found (add CCF atlas to path)')
end
disp('Loading Allen CCF atlas...')
gui_data.tv = readNPY(fullfile(allen_atlas_path,'template_volume_10um.npy'));
gui_data.av = readNPY(fullfile(allen_atlas_path,'annotation_volume_10um_by_index.npy'));
gui_data.st = ap_histology.loadStructureTree(fullfile(allen_atlas_path,'structure_tree_safe_2017.csv'));
disp('Done.')



% Get images (from path in toolbar GUI)
histology_toolbar_guidata = guidata(histology_toolbar_gui);
gui_data.save_path = histology_toolbar_guidata.save_path;

slice_dir = dir(fullfile(gui_data.save_path,'*.tif'));
slice_fn = natsortfiles(cellfun(@(path,fn) fullfile(path,fn), ...
    {slice_dir.folder},{slice_dir.name},'uni',false));

gui_data.slice_im = cell(length(slice_fn),1);
for curr_slice = 1:length(slice_fn)
    gui_data.slice_im{curr_slice} = imread(slice_fn{curr_slice});
end

% Load corresponding CCF slices
ccf_slice_fn = fullfile(gui_data.save_path,'histology_ccf.mat');
load(ccf_slice_fn);
gui_data.histology_ccf = histology_ccf;



% Load histology/CCF alignment
ccf_alignment_fn = fullfile(gui_data.save_path,'atlas2histology_tform.mat');
load(ccf_alignment_fn);
gui_data.histology_ccf_alignment = atlas2histology_tform;

% Warp area labels by histology alignment
gui_data.histology_aligned_av_slices = cell(length(gui_data.slice_im),1);
for curr_slice = 1:length(gui_data.slice_im)
    curr_av_slice = gui_data.histology_ccf(curr_slice).av_slices;
    curr_av_slice(isnan(curr_av_slice)) = 1;
    curr_slice_im = gui_data.slice_im{curr_slice};

    tform = affine2d;
    tform.T = gui_data.histology_ccf_alignment{curr_slice};
    tform_size = imref2d([size(curr_slice_im,1),size(curr_slice_im,2)]);
    gui_data.histology_aligned_av_slices{curr_slice} = ...
        imwarp(curr_av_slice,tform,'nearest','OutputView',tform_size);
end

% Create figure, set button functions
screen_size_px = get(0,'screensize');
gui_aspect_ratio = 1.7; % width/length
gui_width_fraction = 0.6; % fraction of screen width to occupy
gui_width_px = screen_size_px(3).*gui_width_fraction;
gui_position = [...
    (screen_size_px(3)-gui_width_px)/2, ... % left x
    (screen_size_px(4)-gui_width_px/gui_aspect_ratio)/2, ... % bottom y
    gui_width_px,gui_width_px/gui_aspect_ratio]; % width, height

gui_fig = figure('KeyPressFcn',@keypress, ...
    'Toolbar','none','Menubar','none','color','w', ...
    'Units','pixels','Position',gui_position, ...
    'CloseRequestFcn',@close_gui);
gui_data.curr_slice = 1;

% Set up axis for histology image
gui_data.histology_ax = axes('YDir','reverse');
hold on; colormap(gray); axis image off;
gui_data.histology_im_h = image(gui_data.slice_im{1}, ...
    'Parent',gui_data.histology_ax);

% Create title to write area in
gui_data.histology_ax_title = title(gui_data.histology_ax,'','FontSize',14);

% Initialize lesion points
lines_colormap = lines(7);
lesion_colormap = [lines_colormap;lines_colormap(:,[2,3,1]);lines_colormap(:,[3,1,2])];

gui_data.lesion_color = lesion_colormap;
gui_data.lesion_points_histology = cell(length(gui_data.slice_im),1);
% Check existance of lesion_ccf.mat
ccf_lesion_fn = fullfile(gui_data.save_path,'lesion_ccf.mat');
if exist(ccf_lesion_fn, "file")
    load(ccf_lesion_fn);
    gui_data.lesion_points_histology = lesion_ccf.lesion_points_histology;
end
gui_data.lesion_area = gobjects(1);

% Upload gui data
guidata(gui_fig,gui_data);

% Update the slice
update_slice(gui_fig);

end

function keypress(gui_fig,eventdata)

% Get guidata
gui_data = guidata(gui_fig);

switch eventdata.Key

    % left/right: move slice
    case 'leftarrow'
        gui_data.curr_slice = max(gui_data.curr_slice - 1,1);
        guidata(gui_fig,gui_data);
        update_slice(gui_fig);

    case 'rightarrow'
        gui_data.curr_slice = ...
            min(gui_data.curr_slice + 1,length(gui_data.slice_im));
        guidata(gui_fig,gui_data);
        update_slice(gui_fig);

        % Number: add coordinates for the numbered lesion
    case [cellfun(@num2str,num2cell(0:9),'uni',false),cellfun(@(x) ['numpad' num2str(x)],num2cell(1:9),'uni',false)]

        curr_lesion = str2num(eventdata.Key(end));

        % 0 key: lesion 10
        if curr_lesion == 0
            curr_lesion = 10;
        end

        % Shift key: +10
        if any(strcmp(eventdata.Modifier,'shift'))
            curr_lesion = curr_lesion + 10;
        end

        set(gui_data.histology_ax_title,'String',['Draw lesion ' num2str(curr_lesion)]);
        curr_poly = drawpolygon;
        % If the line is just a click, don't include
        curr_poly_length = sqrt(sum(abs(diff(curr_poly.Position,[],1)).^2));
        if curr_poly_length == 0
            return
        end
        gui_data.lesion_points_histology{gui_data.curr_slice,curr_lesion} = ...
            curr_poly.Position;
        set(gui_data.histology_ax_title,'String', ...
            {'Arrows: change slice','Number (shift, +10): draw lesion '});

        % Delete movable line, draw line object
        curr_poly.delete;
        gui_data.lesion_area(curr_lesion) = ...
            line(gui_data.lesion_points_histology{gui_data.curr_slice,curr_lesion}(:,1), ...
            gui_data.lesion_points_histology{gui_data.curr_slice,curr_lesion}(:,2), ...
            'linewidth',3,'color',gui_data.lesion_color(curr_lesion,:));

        % Upload gui data
        guidata(gui_fig,gui_data);
        
    case 'c'
        % Get guidata
        gui_data = guidata(gui_fig);

        opts.Default = 'Yes';
        opts.Interpreter = 'tex';
        user_confirm = questdlg('\fontsize{14} Clear current roi?','Confirm exit',opts);
        switch user_confirm
            case 'Yes'
                % Delete movable line, draw line object
                curr_lesion = 1;
                gui_data.lesion_points_histology{gui_data.curr_slice,curr_lesion} = [];
                % Upload gui data
                guidata(gui_fig,gui_data);
            case 'No'
        end

end

end


function update_slice(gui_fig)
% Draw histology and CCF slice

% Get guidata
gui_data = guidata(gui_fig);

% Set next histology slice
set(gui_data.histology_im_h,'CData',gui_data.slice_im{gui_data.curr_slice})

% Clear any current lines, draw lesion areas
gui_data.lesion_area.delete;
for curr_lesion = find(~cellfun(@isempty,gui_data.lesion_points_histology(gui_data.curr_slice,:)))
    gui_data.lesion_area(curr_lesion) = ...
        line(gui_data.lesion_points_histology{gui_data.curr_slice,curr_lesion}(:,1), ...
        gui_data.lesion_points_histology{gui_data.curr_slice,curr_lesion}(:,2), ...
        'linewidth',3,'color',gui_data.lesion_color(curr_lesion,:));
end

set(gui_data.histology_ax_title,'String', ...
            {'Arrows: change slice','Number (shift, +10): draw lesion X '});

% Upload gui data
guidata(gui_fig, gui_data);

end

function plot_lesion(gui_data,lesion_ccf)

% Plot lesion areas
figure('Name','lesion areas');
axes_atlas = axes;
[~, brain_outline] = plotBrainGrid([],axes_atlas);
set(axes_atlas,'ZDir','reverse');
hold(axes_atlas,'on');
axis vis3d equal off manual
view([-30,25]);

[ap_max,dv_max,ml_max] = size(gui_data.tv);
xlim([-10,ap_max+10])
ylim([-10,ml_max+10])
zlim([-10,dv_max+10])
h = rotate3d(gca);
h.Enable = 'on';

plot3(540, 570, 70, 'ro', 'MarkerFaceColor', 'r')
plot3(540, 570, 70, 'r+', 'MarkerSize', 15)
plot3([100, 200], [100, 100], [100, 100], 'r-', 'LineWidth', 2)
plot3([100, 100], [100, 100], [100, 200], 'r-', 'LineWidth', 2)
plot3([100, 100], [100, 200], [100, 100], 'r-', 'LineWidth', 2)
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
for curr_lesion = 1:length(lesion_ccf)
    patch('XData',lesion_ccf(curr_lesion).lesionArea_TopView(:,2), 'YData', lesion_ccf(curr_lesion).lesionArea_TopView(:,1), 'ZData', repmat(70, size(lesion_ccf(curr_lesion).lesionArea_TopView(:,1))), 'EdgeColor', 'none','FaceColor','b','FaceAlpha',0.3)
end
view([90,90]);
% save PDF
saveas(gcf,fullfile(gui_data.save_path,'lesion_areas90_90.pdf'));
view([-90,0]);
saveas(gcf,fullfile(gui_data.save_path,'lesion_areas-90_0.pdf'));
view([0,0]);
saveas(gcf,fullfile(gui_data.save_path,'lesion_areas0_0.pdf'));
view([-40,40]);
saveas(gcf,fullfile(gui_data.save_path,'lesion_areas-40_40.pdf'));
view([-150,40]);
saveas(gcf,fullfile(gui_data.save_path,'lesion_areas-150_40.pdf'));



figure('Name','Lesion function map')
Area_mapRGB = AllenMapTopView;
imagesc(Area_mapRGB)
axis equal off
hold on
for curr_lesion = 1:length(lesion_ccf)
    patch('XData',lesion_ccf(curr_lesion).lesionArea_TopView(:,1), 'YData', lesion_ccf(curr_lesion).lesionArea_TopView(:,2), 'FaceColor','none','FaceAlpha',0.3, 'LineWidth', 1)
end
plot(570, 540, 'r+', 'MarkerSize', 15)
plot(570, 540, 'ro', 'MarkerFaceColor', 'r')
plot([100, 200], [100, 100], 'w-', 'LineWidth', 2)
saveas(gcf,fullfile(gui_data.save_path,'lesion_areas_overlay.pdf'));

% Plot lesion areas
figure('Name','Lesion areas');
for curr_lesion = 1:length(lesion_ccf)

    curr_axes = subplot(1,length(lesion_ccf),curr_lesion);

    lesion_areas_rgb = permute(cell2mat(cellfun(@(x) hex2dec({x(1:2),x(3:4),x(5:6)})'./255, ...
        lesion_ccf(curr_lesion).lesion_areas.color_hex_triplet,'uni',false)),[1,3,2]);

    % Calculate the volume of the lesion
    % slice widthを尋ねるdialogを表示
    prompt = {'Enter the slice width (um):'};
    dlgtitle = 'Slice width';
    dims = [1 35];
    definput = {'50'};
    answer = inputdlg(prompt,dlgtitle,dims,definput);
    slice_width = str2double(answer{1})*0.001;
    % slice_width = (max(AP_unique)-min(AP_unique))/length(AP_unique)*10*0.001;
    % 取得に失敗した切片（lesion_area_size=0）は前後の値の平均値で補完する（2026/01/15追加）。
    % 0のインデックスを取得
    LesionSize = lesion_ccf(curr_lesion).lesion_area_size;
    zeroIdx = find(LesionSize == 0);
    
    for i = 1:length(zeroIdx)
        idx = zeroIdx(i);
        
        % 配列の端でないことを確認
        if idx > 1 && idx < length(LesionSize)
            % 前後が両方とも0より大きいか確認
            if LesionSize(idx-1) > 0 && LesionSize(idx+1) > 0
                LesionSize(idx) = (LesionSize(idx-1) + LesionSize(idx+1)) / 2;
            end
        end
    end

    lesion_volume = sum(lesion_ccf(curr_lesion).lesion_area_size)*0.010*0.010*slice_width; % 1 voxel = 10x10um = 0.01mm*0.01mm in CCF v3
    lesion_volume_correct_lostsection = sum(LesionSize)*0.010*0.010*slice_width; % 1 voxel = 10x10um = 0.01mm*0.01mm in CCF v3
    disp(['Lesion ' num2str(curr_lesion) ' volume: ' num2str(lesion_volume) ' mm^3'])
    disp(['Lesion ' num2str(curr_lesion) ' volume (correction of the lost sections): ' num2str(lesion_volume_correct_lostsection) ' mm^3'])

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
    IDacronymlist_volume_mm3 = IDacronymlist_count/sum(IDacronymlist_count)*lesion_volume;
    % IDacronymlist_countの要素数の円グラフを描画
    piechart(IDacronymlist_count, IDacronymlist_unique)
    title(['Lesion ' num2str(curr_lesion) ' volume: ' num2str(lesion_volume) ', corrected of lost sections (' num2str(lesion_volume_correct_lostsection) ') mm^3']);

    

end
% save PDF
saveas(gcf,fullfile(gui_data.save_path,'Lesion_Piechart.pdf'));

% save volume data to ExperimentalData.xml <SizeMM2>section
opts.Default = 'Yes';
opts.Interpreter = 'tex';
user_confirm = questdlg('\fontsize{14} Does ExperimentalData.xml exist?','Confirm exit',opts);
switch user_confirm
    case 'Yes'
        
        if ismac
            OM = strfind(gui_data.save_path,'OM');
            if length(OM)>1
                OM = OM(2);
            end
            Slash = strfind(gui_data.save_path(OM:OM+4),'/');
            P = local_paths();   % see local_paths.example.m
            pathname = fullfile(P.BehaviorBase, gui_data.save_path(OM:OM+Slash-2), 'Irregular');
            filename = 'ExperimentalData.xml';
            % e.g. <BehaviorBase>/OM62/Irregular/ExperimentalData.xml
        else
            [filename, pathname] = uigetfile('*ExperimentalData.xml', 'Select the ExperimentalData.xml file');
        end
        
        % read the file
        S = readstruct(fullfile(pathname, filename));
        S.Operation.SizeMM2 = lesion_volume_correct_lostsection;
        S.Operation.SizeMM2_each = IDacronymlist_volume_mm3;
        S.Operation.SizeMM2_eachname = IDacronymlist_unique;
        S.Operation.SizeMM2_MOp = IDacronymlist_volume_mm3(ismember(IDacronymlist_unique, 'MOp'));
        if isscalar(lesion_ccf)
            bregma = allenCCFbregma;
            S.Operation.Area_bregmaOrigML_um = round((lesion_ccf(1).lesionArea_TopView(:,1) - bregma(3))*10);
            S.Operation.Area_bregmaOrigAP_um = round((lesion_ccf(1).lesionArea_TopView(:,2) - bregma(1))*10);
        end
        % write the file
        writestruct(S,fullfile(pathname, filename), 'AttributeSuffix', '_attr');

        save(fullfile(pathname, 'LesionMapAllenCCF.mat'), 'Area_mapRGB', 'lesion_ccf')
        disp(['Data was saved at ' fullfile(pathname, 'LesionMapAllenCCF.mat')])
        save(fullfile(gui_data.save_path, 'LesionMapAllenCCF.mat'), 'Area_mapRGB', 'lesion_ccf')
        disp(['Data was saved at ' fullfile(gui_data.save_path, 'LesionMapAllenCCF.mat')])

    case 'No'
        save(fullfile(gui_data.save_path, 'LesionMapAllenCCF.mat'), 'Area_mapRGB', 'lesion_ccf')
        disp(['Data was saved at ' fullfile(gui_data.save_path, 'LesionMapAllenCCF.mat')])

    case 'Cancel'
        % Do nothing

end


end



function close_gui(gui_fig,~)

% Get guidata
gui_data = guidata(gui_fig);

opts.Default = 'Yes';
opts.Interpreter = 'tex';
user_confirm = questdlg('\fontsize{14} Save?','Confirm exit',opts);
switch user_confirm
    case 'Yes'
        % Save and close

        % Get number of lesions
        n_lesions = size(gui_data.lesion_points_histology,2);

        % Initialize structure to save
        lesion_ccf = struct( ...
            'points',cell(n_lesions,1), ...
            'lesion_areas',cell(n_lesions,1), ...
            'lesion_points_histology',cell(n_lesions,1));

        % Convert lesion points to CCF points by alignment and save
        for curr_lesion = 1:n_lesions
            lesionArea_TopView_medial = zeros(length(find(~cellfun(@isempty,gui_data.lesion_points_histology(:,curr_lesion)'))),2);
            lesionArea_TopView_lateral = zeros(length(find(~cellfun(@isempty,gui_data.lesion_points_histology(:,curr_lesion)'))),2);
            for curr_slice = find(~cellfun(@isempty,gui_data.lesion_points_histology(:,curr_lesion)'))
                curr_lesion_id = find(find(~cellfun(@isempty,gui_data.lesion_points_histology(:,curr_lesion)'))==curr_slice);

                % Transform histology to atlas slice
                tform = affine2d;
                tform.T = gui_data.histology_ccf_alignment{curr_slice};
                % (transform is CCF -> histology, invert for other direction)
                tform = invert(tform);

                % Transform and round to nearest index
                [lesion_points_atlas_x,lesion_points_atlas_y] = ...
                    transformPointsForward(tform, ...
                    gui_data.lesion_points_histology{curr_slice,curr_lesion}(:,1), ...
                    gui_data.lesion_points_histology{curr_slice,curr_lesion}(:,2));

                lesion_points_atlas_x = round(lesion_points_atlas_x);
                lesion_points_atlas_y = round(lesion_points_atlas_y);

                mask = poly2mask(lesion_points_atlas_x, lesion_points_atlas_y, size(gui_data.tv, 3), size(gui_data.tv, 2));
                lesion_ccf(curr_lesion).lesion_area_size(curr_slice)= bwarea(mask);
                % lesion_ccf(curr_lesion).lesion_area_ml(curr_slice)= [min(lesion_points_atlas_x), max(lesion_points_atlas_x)];


                % Get the indices of the pixels inside the polygon
                [lesion_points_atlas_y, lesion_points_atlas_x] = find(mask);

                % Get CCF coordinates corresponding to atlas slice points
                % (CCF coordinates are in [AP,DV,ML])
                use_points = find(~isnan(lesion_points_atlas_x) & ~isnan(lesion_points_atlas_y));
                for curr_point = 1:length(use_points)
                    ccf_ap = gui_data.histology_ccf(curr_slice). ...
                        plane_ap(lesion_points_atlas_y(curr_point), ...
                        lesion_points_atlas_x(curr_point));
                    ccf_ml = gui_data.histology_ccf(curr_slice). ...
                        plane_ml(lesion_points_atlas_y(curr_point), ...
                        lesion_points_atlas_x(curr_point));
                    ccf_dv = gui_data.histology_ccf(curr_slice). ...
                        plane_dv(lesion_points_atlas_y(curr_point), ...
                        lesion_points_atlas_x(curr_point));
                    lesion_ccf(curr_lesion).points = ...
                        vertcat(lesion_ccf(curr_lesion).points,[ccf_ap,ccf_dv,ccf_ml]);
                end
                curr_lesion_points = lesion_ccf(curr_lesion).points;
                lesionArea_TopView_medial(curr_lesion_id,1) = min(lesion_points_atlas_x);
                lesionArea_TopView_medial(curr_lesion_id,2) = ccf_ap;
                lesionArea_TopView_lateral(curr_lesion_id,2) = ccf_ap;
                lesionArea_TopView_lateral(curr_lesion_id,1) = max(lesion_points_atlas_x);
                

            end
            lesionArea_TopView_lateral = flipud(lesionArea_TopView_lateral);
            lesion_ccf(curr_lesion).lesionArea_TopView = [lesionArea_TopView_medial;lesionArea_TopView_lateral];

            lesion_ccf(curr_lesion).points = lesion_ccf(curr_lesion).points;

        end

        
 

        % Get areas inside lesion
        for curr_lesion = 1:n_lesions

            [lesion_ap_ccf,lesion_dv_ccf,lesion_ml_ccf] = deal( ...
                lesion_ccf(curr_lesion).points(:,1)', ...
                lesion_ccf(curr_lesion).points(:,2)', ...
                lesion_ccf(curr_lesion).points(:,3)');

            lesion_coords_outofbounds = ...
                any([lesion_ap_ccf;lesion_dv_ccf;lesion_ml_ccf] < 1,1) | ...
                any([lesion_ap_ccf;lesion_dv_ccf;lesion_ml_ccf] > size(gui_data.av)',1);

            lesion_coords_sample = ...
                [lesion_ap_ccf(~lesion_coords_outofbounds)' ...
                lesion_dv_ccf(~lesion_coords_outofbounds)', ...
                lesion_ml_ccf(~lesion_coords_outofbounds)'];

            lesion_idx_sample = sub2ind(size(gui_data.av), ...
                lesion_coords_sample(:,1), ...
                lesion_coords_sample(:,2), ...
                lesion_coords_sample(:,3));

            lesion_area_idx_sampled = gui_data.av(round(lesion_idx_sample));
            lesion_area_bins = [1;(find(diff(double(lesion_area_idx_sampled))~= 0)+1);length(lesion_idx_sample)];
            lesion_area_boundaries = [lesion_area_bins(1:end-1),lesion_area_bins(2:end)];

            lesion_area_idx = lesion_area_idx_sampled(lesion_area_boundaries(:,1));
            store_areas_idx = lesion_area_idx > 1; % only use areas in brain (idx > 1)

            % Store row from structure tree and depths for each area
            % (normalize depth to first brain boundary)
            lesion_areas = gui_data.st(lesion_area_idx(store_areas_idx),:);
            lesion_areas.lesion_depth = (lesion_area_boundaries(store_areas_idx,:) - ...
                lesion_area_boundaries(find(store_areas_idx,1),1));

            % Store CCF coordinates for lesion beginning/end
            lesion_coords = lesion_coords_sample( ...
                [lesion_area_boundaries(find(store_areas_idx,1,'first'),1)
                lesion_area_boundaries(find(store_areas_idx,1,'last'),end)],:);

            lesion_points_histology = gui_data.lesion_points_histology;

            % Package
            lesion_ccf(curr_lesion).lesion_areas = lesion_areas;
            lesion_ccf(curr_lesion).lesion_coords = lesion_coords;
            lesion_ccf(curr_lesion).lesion_points_histology = lesion_points_histology;

        end

        % Save lesion CCF points
        save_fn = fullfile(gui_data.save_path,'lesion_ccf.mat');
        save(save_fn,'lesion_ccf');
        disp(['Saved lesion locations in ' save_fn])

        % Close GUI
        delete(gui_fig)

        % Plot lesion trajectories
        plot_lesion(gui_data,lesion_ccf);

    case 'No'
        % Close without saving
        delete(gui_fig);

    case 'Cancel'
        % Do nothing

end

% Update toolbar GUI
ap_histology.update_toolbar_gui(gui_data.histology_toolbar_gui);

end












