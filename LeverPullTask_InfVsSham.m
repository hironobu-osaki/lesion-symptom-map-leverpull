
% LeverPullTask_InfVsSham.m
% Compares lever pull behavioral metrics (FallTime, RegularHoldTime, CrossCount)
% between Infarction and Sham groups.
%
% Data source: individual session *_FallCount.mat files in each animal's Movie folder.
%   Each file contains: List = [FallTime_10min, RegularHoldTime_10min, CrossCount_10min]
%     FallTime_10min       : time (min/10min) forelimb was >7.5mm from lever  (fall)
%     RegularHoldTime_10min: time (min/10min) forelimb was <5mm from lever    (regular hold)
%     CrossCount_10min     : number of 7.5mm threshold crossings per 10min    (fall count)
%
% Group assignment: NOIO_summary Excel (LesionLocation == 'sham' -> Sham)

%% 1. Load animal summary (NOIOData struct array)
scriptDir = fileparts(mfilename('fullpath'));
run(fullfile(scriptDir, 'Read_NOIO_summary.m'));

%% 2. Configuration

% Movie subfolders to search
%   Iwai: YY-MM-DD HH-MM-SS_FallCount.mat (2-digit year, space between date/time)
MovieRoots = { ...
    fullfile(getDataServerRoot(), 'Movie\Iwai')};

% Standard POD timepoints for alignment
% -1: pre-surgery baseline (average of ALL pre-surgery sessions)
%  3, 7, 10, 14, 17, 21, 24, 28: post-surgery sessions
StdPOD    = [-1, 3, 7, 10, 14, 17, 21, 24, 28];
Tolerance = 2;   % days: match a session to StdPOD if within ±Tolerance

%% 3. Load session data
BehData = struct('ID', {}, 'Group', {}, 'LesionLocation', {}, ...
    'FallTime_10min', {}, 'RegHoldTime_10min', {}, 'CrossCount_10min', {}, ...
    'SurgDate', {}, ...
    'POD_sess', {}, 'FT_sess', {}, 'RHT_sess', {}, 'CC_sess', {}, ...
    'CaseHold_sess', {}, 'Release_sess', {}, ...
    'FT_dv_sess', {}, 'CC_dv_sess', {}, 'FT_gmm_sess', {}, 'CC_gmm_sess', {}, ...
    'hasM1', {}, 'hasM2', {}, 'hasS1', {}, ...
    'volM1', {}, 'volM2', {}, 'volS1', {}, ...
    'MovieFolder', {});

CCF_root_beh = fullfile(getDataServerRoot(), 'ImagingData\Iwai\DAPI_Data');

allIDs       = {NOIOData.ID};
allLocs      = {NOIOData.LesionLocation};
allSurgDates = arrayfun(@(x) x.SessionDates(6), NOIOData);

% Animals excluded from population analysis
% excludeIDs = {'NO7', 'NO8'};   % failed to control motivation
excludeIDs = {};   % failed to control motivation


for i = 1:length(allIDs)
    animalID  = allIDs{i};
    lesionLoc = allLocs{i};
    surgDate  = allSurgDates(i);

    if ismember(animalID, excludeIDs)
        fprintf('Excluding %s: motivation control failure\n', animalID)
        continue
    end

    % --- Surgery date ---
    if isnat(surgDate)
        fprintf('Excluding %s: surgery date not found\n', animalID)
        continue
    end

    % --- Find animal folder in either MovieRoot ---
    % Try exact ID first, then zero-padded / zero-stripped variants
    % e.g. 'NO4' <-> 'NO04' refer to the same animal
    animalFolder = '';
    isIwai = false;
    idCandidates = animalIDVariants(animalID);
    for rootIdx = 1:length(MovieRoots)
        for ci = 1:length(idCandidates)
            candidate = fullfile(MovieRoots{rootIdx}, idCandidates{ci});
            if isfolder(candidate)
                animalFolder = candidate;
                isIwai = contains(MovieRoots{rootIdx}, 'Iwai');
                break
            end
        end
        if ~isempty(animalFolder), break; end
    end
    if isempty(animalFolder)
        fprintf('Excluding %s: folder not found in any MovieRoot\n', animalID)
        continue
    end

    % --- Count raw session mp4s (exclude DLC-processed / labeled / trimmed) ---
    allMp4 = dir(fullfile(animalFolder, '*.mp4'));
    isDLC  = contains({allMp4.name}, 'DLC_') | ...
             contains({allMp4.name}, '_labeled') | ...
             contains({allMp4.name}, '_output_video') | ...
             contains({allMp4.name}, '_Trimmed');
    nMp4   = sum(~isDLC);

    % --- Find session FallCount.mat files ---
    sessionFiles = dir(fullfile(animalFolder, '*_FallCount.mat'));
    fprintf('%s: nMp4=%d, nMat=%d\n', animalID, nMp4, length(sessionFiles))
    needGen = isempty(sessionFiles) || (nMp4 > 0 && length(sessionFiles) < nMp4);

    if needGen
        fprintf('%s: %d mp4(s), %d *_FallCount.mat — running GenerateFallCount.py ...\n', ...
            animalID, nMp4, length(sessionFiles))
        pyScript = fullfile(scriptDir, 'GenerateFallCount.py');
        pyExe = getDeepLabCutPython();   % resolves across machines (was hardcoded)
        if isempty(pyExe)
            fprintf(['  Cannot locate the DEEPLABCUT conda env python.exe — skipping %s.\n' ...
                '  Point at it once via the file picker, or set it with\n' ...
                '  setpref(''LeverPullTask'',''DeepLabCutPython'',''<path-to-python.exe>'').\n'], animalID)
            continue
        end
        [pyStatus, pyOut] = system(sprintf('"%s" "%s" "%s" 2>&1', pyExe, pyScript, animalFolder));
        if pyStatus ~= 0
            fprintf('  GenerateFallCount.py failed for %s:\n%s\n', animalID, pyOut)
            continue
        end
        fprintf('%s\n', pyOut)
        sessionFiles = dir(fullfile(animalFolder, '*_FallCount.mat'));
        if isempty(sessionFiles)
            fprintf('Excluding %s: GenerateFallCount produced no .mat files\n', animalID)
            continue
        end
    end

    % --- Parse date from filename and load metrics ---
    % Nakashima: 'YYYY-M-D-HH-MM_FallCount.mat'  (4-digit year, no space)
    % Iwai     : 'YY-MM-DD HH-MM-SS_FallCount.mat' (2-digit year, space separator)
    nSess     = length(sessionFiles);
    sessDates = NaT(nSess, 1);
    FallTime  = NaN(nSess, 1);
    RegHold   = NaN(nSess, 1);
    Cross     = NaN(nSess, 1);
    FT_dv     = NaN(nSess, 1);
    CC_dv     = NaN(nSess, 1);
    FT_gmm    = NaN(nSess, 1);
    CC_gmm    = NaN(nSess, 1);
    CaseHoldCount = zeros(nSess, 1);   % number of Case Holding correction segments
    nFramesArr    = zeros(nSess, 1);   % frame count — used to pick longest when same day
    hasCorrArr    = false(nSess, 1);   % whether a _corrections.mat exists for this file —
                                        % used to break exact same-day frame-count ties (see below)
    FT_L   = NaN(nSess, 1);
    RHT_L  = NaN(nSess, 1);
    CC_L   = NaN(nSess, 1);
    nValid = 0;

    for j = 1:nSess
        fname      = sessionFiles(j).name;
        fnameTrim  = strtrim(fname);   % remove leading/trailing spaces from filename
        try
            % Detect format per-file by year-part length, not by folder.
            %   Nakashima: YYYY-M-D-HH-MM[[-SS]]_FallCount.mat  (4-digit year, no space)
            %   Iwai     :  YY-MM-DD HH-MM-SS_FallCount.mat     (2-digit year, leading space)
            p1 = strsplit(fnameTrim, '-');   % first split on '-'
            if length(p1{1}) == 4
                % Nakashima: tokens are YYYY, M, D, ...
                p  = p1;
                yr = str2double(p{1});
                mo = str2double(p{2});
                dy = str2double(p{3});
            else
                % Iwai: date part is before the first space
                datePart = strtrim(extractBefore(fnameTrim, ' '));
                p  = strsplit(datePart, '-');
                yr = str2double(p{1}) + 2000;
                mo = str2double(p{2});
                dy = str2double(p{3});
            end
            if any(isnan([yr, mo, dy])) || yr < 2020 || yr > 2100
                fprintf('  SKIP date parse: %s (yr=%.0f mo=%.0f dy=%.0f)\n', fnameTrim, yr, mo, dy)
                continue
            end
            sessDate = datetime(yr, mo, dy);
        catch ME
            fprintf('  SKIP date error: %s (%s)\n', fnameTrim, ME.message)
            continue
        end

        try
            s = load(fullfile(animalFolder, fname));
        catch ME
            fprintf('  SKIP load error: %s (%s)\n', fname, ME.message)
            continue
        end
        if ~isfield(s, 'List') || numel(s.List) < 3
            fprintf('  SKIP no List: %s (fields: %s)\n', fname, strjoin(fieldnames(s)', ','))
            continue
        end

        nValid = nValid + 1;
        sessDates(nValid) = sessDate;
        FallTime(nValid)  = s.List(1);
        RegHold(nValid)   = s.List(2);
        Cross(nValid)     = s.List(3);
        if isfield(s, 'distance_mm_filtered')
            nFramesArr(nValid) = numel(s.distance_mm_filtered);
        elseif isfield(s, 'distance_mm')
            nFramesArr(nValid) = numel(s.distance_mm);
        end
        if isfield(s, 'FallTime_10min_dv'),    FT_dv(nValid)  = double(s.FallTime_10min_dv);    end
        if isfield(s, 'CrossCount_10min_dv'),  CC_dv(nValid)  = double(s.CrossCount_10min_dv);  end
        if isfield(s, 'FallTime_10min_gmm'),   FT_gmm(nValid) = double(s.FallTime_10min_gmm);   end
        if isfield(s, 'CrossCount_10min_gmm'), CC_gmm(nValid) = double(s.CrossCount_10min_gmm); end
        if isfield(s, 'FallTime_10min_L'),        FT_L(nValid)  = double(s.FallTime_10min_L);        end
        if isfield(s, 'RegularHoldTime_10min_L'), RHT_L(nValid) = double(s.RegularHoldTime_10min_L); end
        if isfield(s, 'CrossCount_10min_L'),      CC_L(nValid)  = double(s.CrossCount_10min_L);      end
        % Apply corrections: recompute FT/RHT/CC and count Case Holding
        corrFname = strrep(fname, '_FallCount.mat', '_corrections.mat');
        corrPath  = fullfile(animalFolder, corrFname);
        hasCorrArr(nValid) = exist(corrPath, 'file') > 0;
        if exist(corrPath, 'file')
            try
                Sc2 = load(corrPath, 'corrections');
                if isfield(Sc2, 'corrections') && ~isempty(Sc2.corrections)
                    % Apply legacy label rename in-place
                    LEGACY_MERGE = {'HoldCaseEgde','HoldCaseEdge'};
                    for kk = 1:length(Sc2.corrections)
                        if any(strcmp(Sc2.corrections(kk).label, LEGACY_MERGE))
                            Sc2.corrections(kk).label = 'Case Holding';
                        end
                    end
                    [FallTime(nValid), RegHold(nValid), Cross(nValid), ...
                     CaseHoldCount(nValid)] = computeCorrectedMetrics(s, Sc2.corrections);
                end
            catch ME
                fprintf('  corrections apply failed for %s: %s\n', fname, ME.message);
            end
        end
    end

    if nValid == 0
        fprintf('Excluding %s: no parseable session files\n', animalID)
        continue
    end
    sessDates = sessDates(1:nValid);
    FallTime  = FallTime(1:nValid);
    RegHold   = RegHold(1:nValid);
    Cross     = Cross(1:nValid);
    FT_dv     = FT_dv(1:nValid);
    CC_dv     = CC_dv(1:nValid);
    FT_gmm        = FT_gmm(1:nValid);
    CC_gmm        = CC_gmm(1:nValid);
    CaseHoldCount = CaseHoldCount(1:nValid);
    nFramesArr    = nFramesArr(1:nValid);
    hasCorrArr    = hasCorrArr(1:nValid);
    FT_L   = FT_L(1:nValid);
    RHT_L  = RHT_L(1:nValid);
    CC_L   = CC_L(1:nValid);

    % Sort chronologically (dir() returns lexicographic order; non-zero-padded
    % dates like 2024-10-4 sort after 2024-10-18 without this step)
    [sessDates, sortIdx] = sort(sessDates);
    FallTime = FallTime(sortIdx);
    RegHold  = RegHold(sortIdx);
    Cross    = Cross(sortIdx);
    FT_dv    = FT_dv(sortIdx);
    CC_dv    = CC_dv(sortIdx);
    FT_gmm        = FT_gmm(sortIdx);
    CC_gmm        = CC_gmm(sortIdx);
    CaseHoldCount = CaseHoldCount(sortIdx);
    nFramesArr    = nFramesArr(sortIdx);
    hasCorrArr    = hasCorrArr(sortIdx);
    FT_L   = FT_L(sortIdx);
    RHT_L  = RHT_L(sortIdx);
    CC_L   = CC_L(sortIdx);

    % Multiple recordings per day -> use the longest recording
    fprintf('%s: surgDate=%s, sessions %s to %s (%d days)\n', animalID, ...
        datestr(surgDate,'yyyy-mm-dd'), datestr(min(sessDates),'yyyy-mm-dd'), ...
        datestr(max(sessDates),'yyyy-mm-dd'), days(max(sessDates)-min(sessDates)))
    POD_raw    = days(sessDates - surgDate);
    fprintf('  %s: %d sessions, POD_raw=[%s]\n', animalID, nValid, num2str(POD_raw'))
    uniquePODs = unique(POD_raw);
    nU      = length(uniquePODs);
    POD     = NaN(nU, 1);
    FT_day  = NaN(nU, 1);
    RHT_day = NaN(nU, 1);
    CC_day  = NaN(nU, 1);
    FTdv_day  = NaN(nU, 1);
    CCdv_day  = NaN(nU, 1);
    FTgmm_day = NaN(nU, 1);
    CCgmm_day = NaN(nU, 1);
    CH_day    = zeros(nU, 1);
    FT_day_L  = NaN(nU, 1);
    RHT_day_L = NaN(nU, 1);
    CC_day_L  = NaN(nU, 1);
    for d = 1:nU
        mask    = POD_raw == uniquePODs(d);
        maskIdx = find(mask);
        if numel(maskIdx) > 1
            % Multiple recordings on same day — pick the one with most frames.
            % When two duplicates tie exactly on frame count (e.g. a file
            % re-exported under a near-identical name, differing only by
            % whitespace, that byte-for-byte duplicates an earlier one),
            % prefer whichever of the tied files has a saved _corrections.mat
            % — a reviewed/corrected duplicate should win over an identical
            % but never-opened one, otherwise dir()'s (often alphabetical,
            % so a leading-space filename sorts first) ordering silently
            % picks the uncorrected copy every time BehData is rebuilt.
            maxFrames = max(nFramesArr(maskIdx));
            tiedIdx   = maskIdx(nFramesArr(maskIdx) == maxFrames);
            if numel(tiedIdx) > 1 && any(hasCorrArr(tiedIdx))
                sel = tiedIdx(find(hasCorrArr(tiedIdx), 1));
            else
                sel = tiedIdx(1);
            end
            fprintf('  %s POD%d: %d recordings, using longest (%d frames: %s)%s\n', ...
                animalID, uniquePODs(d), numel(maskIdx), nFramesArr(sel), ...
                datestr(sessDates(sel), 'yyyy-mm-dd HH:MM'), ...
                repmat(' [tie broken by corrections.mat]', 1, numel(tiedIdx) > 1 && any(hasCorrArr(tiedIdx))));
        else
            sel = maskIdx;
        end
        POD(d)       = uniquePODs(d);
        FT_day(d)    = FallTime(sel);
        RHT_day(d)   = RegHold(sel);
        CC_day(d)    = Cross(sel);
        FTdv_day(d)  = FT_dv(sel);
        CCdv_day(d)  = CC_dv(sel);
        FTgmm_day(d) = FT_gmm(sel);
        CCgmm_day(d) = CC_gmm(sel);
        CH_day(d)    = CaseHoldCount(sel);
        FT_day_L(d)  = FT_L(sel);
        RHT_day_L(d) = RHT_L(sel);
        CC_day_L(d)  = CC_L(sel);
    end

    % Align to standard timepoints
    FallTime_aligned = NaN(1, length(StdPOD));
    RegHold_aligned  = NaN(1, length(StdPOD));
    Cross_aligned    = NaN(1, length(StdPOD));
    FT_dv_aligned    = NaN(1, length(StdPOD));
    CC_dv_aligned    = NaN(1, length(StdPOD));
    FT_gmm_aligned   = NaN(1, length(StdPOD));
    CC_gmm_aligned   = NaN(1, length(StdPOD));

    % Baseline (StdPOD = -1): average the 2 pre-surgery days closest to surgery
    % to reduce variance from very early sessions
    preMask = POD < 0;
    if any(preMask)
        preFT   = FT_day(preMask);
        preRHT  = RHT_day(preMask);
        preCC   = CC_day(preMask);
        [~, idx] = sort(POD(preMask), 'descend');   % closest to surgery first
        nUse    = min(2, length(idx));
        FallTime_aligned(1) = mean(preFT(idx(1:nUse)));
        RegHold_aligned(1)  = mean(preRHT(idx(1:nUse)));
        Cross_aligned(1)    = mean(preCC(idx(1:nUse)));
        FT_dv_aligned(1)    = mean(FTdv_day(preMask));
        CC_dv_aligned(1)    = mean(CCdv_day(preMask));
        FT_gmm_aligned(1)   = mean(FTgmm_day(preMask));
        CC_gmm_aligned(1)   = mean(CCgmm_day(preMask));
    end

    for t = 2:length(StdPOD)
        [minDiff, closest] = min(abs(POD - StdPOD(t)));
        if minDiff <= Tolerance
            FallTime_aligned(t) = FT_day(closest);
            RegHold_aligned(t)  = RHT_day(closest);
            Cross_aligned(t)    = CC_day(closest);
            FT_dv_aligned(t)    = FTdv_day(closest);
            CC_dv_aligned(t)    = CCdv_day(closest);
            FT_gmm_aligned(t)   = FTgmm_day(closest);
            CC_gmm_aligned(t)   = CCgmm_day(closest);
        end
    end

    if strcmpi(lesionLoc, 'sham')
        group = 'Sham';
    else
        group = 'Infarction';
    end

    % --- Compute per-region lesion volumes from CCF data (MOp=M1, MOs=M2, SSp*=S1) ---
    volM1 = 0;  volM2 = 0;  volS1 = 0;
    if ~strcmpi(lesionLoc, 'sham')
        ccfF = findCCFFiles(CCF_root_beh, animalID);
        if ~isempty(ccfF)
            try
                Sc = load(fullfile(ccfF(1).folder, ccfF(1).name), 'lesion_ccf');
                slice_width_mm = 50 * 0.001;   % 50 µm slice spacing
                for lsn = 1:length(Sc.lesion_ccf)
                    total_vol = sum(Sc.lesion_ccf(lsn).lesion_area_size) ...
                                * 0.010 * 0.010 * slice_width_mm;
                    acr = Sc.lesion_ccf(lsn).lesion_areas.acronym;
                    acr = cellfun(@stripLayerSuffix, acr, 'UniformOutput', false);
                    n_total = numel(acr);
                    if n_total > 0
                        volM1 = volM1 + total_vol * sum(strcmp(acr,'MOp'))             / n_total;
                        volM2 = volM2 + total_vol * sum(strcmp(acr,'MOs'))             / n_total;
                        volS1 = volS1 + total_vol * sum(cellfun(@(x) startsWith(x,'SSp'), acr)) / n_total;
                    end
                end
            catch e
                fprintf('  CCF region volume failed for %s: %s\n', animalID, e.message);
            end
        end
    end
    hasM1 = volM1 > 0;  hasM2 = volM2 > 0;  hasS1 = volS1 > 0;

    BehData(end+1).ID              = animalID;
    BehData(end).Group             = group;
    BehData(end).LesionLocation    = lesionLoc;
    BehData(end).FallTime_10min    = FallTime_aligned;
    BehData(end).RegHoldTime_10min = RegHold_aligned;
    BehData(end).CrossCount_10min  = Cross_aligned;
    BehData(end).FallTime_10min_dv    = FT_dv_aligned;
    BehData(end).CrossCount_10min_dv  = CC_dv_aligned;
    BehData(end).FallTime_10min_gmm   = FT_gmm_aligned;
    BehData(end).CrossCount_10min_gmm = CC_gmm_aligned;
    BehData(end).SurgDate          = surgDate;
    BehData(end).POD_sess          = POD;
    BehData(end).FT_sess           = FT_day;
    BehData(end).RHT_sess          = RHT_day;
    BehData(end).CC_sess           = CC_day;
    BehData(end).CaseHold_sess     = CH_day;
    BehData(end).Release_sess      = CC_day + CH_day;
    BehData(end).FT_dv_sess        = FTdv_day;
    BehData(end).CC_dv_sess        = CCdv_day;
    BehData(end).FT_gmm_sess       = FTgmm_day;
    BehData(end).CC_gmm_sess       = CCgmm_day;
    BehData(end).FT_sess_L         = FT_day_L;
    BehData(end).RHT_sess_L        = RHT_day_L;
    BehData(end).CC_sess_L         = CC_day_L;
    BehData(end).MovieFolder       = animalFolder;
    BehData(end).hasM1             = hasM1;
    BehData(end).hasM2             = hasM2;
    BehData(end).hasS1             = hasS1;
    BehData(end).volM1             = volM1;
    BehData(end).volM2             = volM2;
    BehData(end).volS1             = volS1;
    fprintf('  %s: M1=%.3f mm³  M2=%.3f mm³  S1=%.3f mm³\n', animalID, volM1, volM2, volS1);
end

if isempty(BehData)
    error('No animals loaded. Check MovieRoot paths and NOIOData.');
end

nInf  = sum(strcmp({BehData.Group}, 'Infarction'));
nSham = sum(strcmp({BehData.Group}, 'Sham'));
fprintf('Loaded %d animals: %d Infarction, %d Sham\n', length(BehData), nInf, nSham);
disp('Infarction:'); disp({BehData(strcmp({BehData.Group}, 'Infarction')).ID}');
disp('Sham:');       disp({BehData(strcmp({BehData.Group}, 'Sham')).ID}');

%% 3b. Load per-event data for population scatter figure
fprintf('Loading event data for population scatter...\n');
%% 4-6. Population figure — created lazily by the Population button
% (updatePopulationFromFig7 builds the figure on first click; we just stash
%  an empty placeholder so it doesn't open at startup).
figPop = [];

%% 7. Single-animal interactive figure (listbox on left to select animal)
allIDs_beh = {BehData.ID};
defID      = 'IO22';
defIdx     = find(strcmp(allIDs_beh, defID), 1);
if isempty(defIdx), defIdx = 1; end

fig7 = figure('Name', 'Single Animal — Lever Pull Task', ...
    'Position', [60 60 1500 940]);

% Store shared data in fig7 appdata for use by Population button
setappdata(fig7, 'BehData',      BehData);
setappdata(fig7, 'figPop',       figPop);
setappdata(fig7, 'StdPOD',       StdPOD);
setappdata(fig7, 'CCF_root_beh', CCF_root_beh);

% Listbox on the left
uicontrol(fig7, 'Style',    'listbox', ...
                'String',   allIDs_beh, ...
                'Value',    defIdx, ...
                'Units',    'normalized', ...
                'Position', [0.01 0.03 0.07 0.93], ...
                'FontSize', 10, ...
                'Tag',      'listboxAnimals', ...
                'Callback', @(src,~) plotSingleAnimal(src.Value, getappdata(fig7,'BehData'), fig7));

% --- Behavioral axes (left-center, 4 rows: FT / CC / RHT / Release) ---
axLeft = 0.10;  axW = 0.38;
sW = axW * 0.8;
sH = 0.155;
sL = axLeft + (axW - sW) / 2;
% Distribute 4 axes evenly within [0.12, 0.92]
topEdge = 0.92;  botEdge = 0.12;
gap4 = (topEdge - botEdge - 4*sH) / 3;
sBottoms = topEdge - sH - (0:3)*(sH + gap4);
for sp = 1:4
    axes('Parent', fig7, ...
         'Position', [sL, sBottoms(sp), sW, sH], ...
         'Tag',      sprintf('singleAx%d', sp));
end

% --- Lesion map (top-right left, scaled to 80%, shifted up) ---
hLM = axes('Parent', fig7, ...
     'Position', [0.542, 0.52, 0.176, 0.40], ...
     'Tag', 'singleAxLesionMap');
setappdata(fig7, 'lesionMapHandle', hLM);

% --- Slice viewer axes (top-right right) ---
hLS = axes('Parent', fig7, ...
     'Position', [0.76, 0.47, 0.22, 0.45], ...
     'Tag', 'singleAxSlice');
setappdata(fig7, 'sliceAxHandle', hLS);

% Back / Next buttons (below slice axes) — created once, enabled/disabled per animal
uicontrol(fig7, 'Style', 'pushbutton', 'String', '◀ Back', ...
    'Units', 'normalized', 'Position', [0.76, 0.42, 0.10, 0.04], ...
    'FontSize', 9, 'Tag', 'btnSliceBack', 'Enable', 'off', ...
    'Callback', @(~,~) drawSlice(fig7, getappdata(fig7,'sliceIdx')-1));
uicontrol(fig7, 'Style', 'pushbutton', 'String', 'Next ▶', ...
    'Units', 'normalized', 'Position', [0.88, 0.42, 0.10, 0.04], ...
    'FontSize', 9, 'Tag', 'btnSliceNext', 'Enable', 'off', ...
    'Callback', @(~,~) drawSlice(fig7, getappdata(fig7,'sliceIdx')+1));
% Overlay toggle buttons — independent, can both be ON simultaneously
uicontrol(fig7, 'Style', 'togglebutton', 'String', 'Lesion', ...
    'Units', 'normalized', 'Position', [0.76, 0.37, 0.11, 0.04], ...
    'FontSize', 9, 'Tag', 'btnToggleLesion', 'Value', 1, ...
    'Callback', @(~,~) drawSlice(fig7, getappdata(fig7,'sliceIdx')));
uicontrol(fig7, 'Style', 'togglebutton', 'String', 'Atlas', ...
    'Units', 'normalized', 'Position', [0.87, 0.37, 0.11, 0.04], ...
    'FontSize', 9, 'Tag', 'btnToggleAtlas', 'Value', 0, ...
    'Callback', @(~,~) drawSlice(fig7, getappdata(fig7,'sliceIdx')));

% --- Pie chart: 50% of original width, below the lesion map ---
hLP = axes('Parent', fig7, ...
     'Position', [0.52, 0.09, 0.23, 0.32], ...
     'Tag', 'singleAxLesionPie');
setappdata(fig7, 'lesionPieHandle', hLP);

% --- Population filter controls (right column, below Lesion/Atlas buttons at y=0.37) ---
% Row A: label + AND/OR popup  (y ≈ 0.33)
uicontrol(fig7, 'Style', 'text', 'String', 'Filter Infarction:', ...
    'Units', 'normalized', 'Position', [0.76, 0.33, 0.12, 0.03], ...
    'FontSize', 9, 'HorizontalAlignment', 'left');
uicontrol(fig7, 'Style', 'popupmenu', 'String', {'OR','AND'}, ...
    'Units', 'normalized', 'Position', [0.89, 0.33, 0.09, 0.03], ...
    'FontSize', 9, 'Tag', 'popAndOr', 'Value', 1);
% Row B: region toggle buttons  (y ≈ 0.29)
uicontrol(fig7, 'Style', 'togglebutton', 'String', 'M1 (MOp)', ...
    'Units', 'normalized', 'Position', [0.760, 0.29, 0.073, 0.035], ...
    'FontSize', 9, 'Tag', 'chkM1', 'Value', 1);
uicontrol(fig7, 'Style', 'togglebutton', 'String', 'M2 (MOs)', ...
    'Units', 'normalized', 'Position', [0.833, 0.29, 0.073, 0.035], ...
    'FontSize', 9, 'Tag', 'chkM2', 'Value', 0);
uicontrol(fig7, 'Style', 'togglebutton', 'String', 'S1 (SSp)', ...
    'Units', 'normalized', 'Position', [0.906, 0.29, 0.073, 0.035], ...
    'FontSize', 9, 'Tag', 'chkS1', 'Value', 0);
% Row C: minimum volume (≥)  (y ≈ 0.25)
uicontrol(fig7, 'Style', 'text', 'String', '≥ mm³', ...
    'Units', 'normalized', 'Position', [0.760, 0.25, 0.055, 0.03], ...
    'FontSize', 8, 'HorizontalAlignment', 'left');
uicontrol(fig7, 'Style', 'edit', 'String', '0', ...
    'Units', 'normalized', 'Position', [0.815, 0.25, 0.055, 0.03], ...
    'FontSize', 9, 'Tag', 'editThreshM1');
uicontrol(fig7, 'Style', 'edit', 'String', '0', ...
    'Units', 'normalized', 'Position', [0.870, 0.25, 0.055, 0.03], ...
    'FontSize', 9, 'Tag', 'editThreshM2');
uicontrol(fig7, 'Style', 'edit', 'String', '0', ...
    'Units', 'normalized', 'Position', [0.925, 0.25, 0.055, 0.03], ...
    'FontSize', 9, 'Tag', 'editThreshS1');
% Row D: maximum volume (≤)  (y ≈ 0.21)
uicontrol(fig7, 'Style', 'text', 'String', '≤ mm³', ...
    'Units', 'normalized', 'Position', [0.760, 0.21, 0.055, 0.03], ...
    'FontSize', 8, 'HorizontalAlignment', 'left');
uicontrol(fig7, 'Style', 'edit', 'String', 'Inf', ...
    'Units', 'normalized', 'Position', [0.815, 0.21, 0.055, 0.03], ...
    'FontSize', 9, 'Tag', 'editMaxM1');
uicontrol(fig7, 'Style', 'edit', 'String', 'Inf', ...
    'Units', 'normalized', 'Position', [0.870, 0.21, 0.055, 0.03], ...
    'FontSize', 9, 'Tag', 'editMaxM2');
uicontrol(fig7, 'Style', 'edit', 'String', 'Inf', ...
    'Units', 'normalized', 'Position', [0.925, 0.21, 0.055, 0.03], ...
    'FontSize', 9, 'Tag', 'editMaxS1');
% Population button  (y ≈ 0.17)
uicontrol(fig7, 'Style', 'pushbutton', 'String', 'Population', ...
    'Units', 'normalized', 'Position', [0.76, 0.17, 0.22, 0.035], ...
    'FontSize', 9, 'Tag', 'btnPopulation', ...
    'Callback', @(~,~) updatePopulationFromFig7(fig7));
% Lesion centroid map button  (y ≈ 0.085)
uicontrol(fig7, 'Style', 'pushbutton', 'String', 'Lesion Centroids', ...
    'Units', 'normalized', 'Position', [0.76, 0.085, 0.22, 0.035], ...
    'FontSize', 9, 'Tag', 'btnLesionCentroid', ...
    'Callback', @(~,~) openLesionCentroidFig(fig7));

% --- Behavior day selector (below Release subplot, y ≈ 0.03) --------
% sL ≈ 0.138  (left edge of behavioural subplots)
uicontrol(fig7, 'Style', 'pushbutton', 'String', '◀', ...
    'Units', 'normalized', 'Position', [0.138, 0.03, 0.042, 0.038], ...
    'FontSize', 9, 'Tag', 'btnBehBack', ...
    'Callback', @(~,~) stepBehaviorDay(fig7, -1));
uicontrol(fig7, 'Style', 'pushbutton', 'String', '▶', ...
    'Units', 'normalized', 'Position', [0.183, 0.03, 0.042, 0.038], ...
    'FontSize', 9, 'Tag', 'btnBehNext', ...
    'Callback', @(~,~) stepBehaviorDay(fig7, +1));
uicontrol(fig7, 'Style', 'pushbutton', 'String', 'Behavior', ...
    'Units', 'normalized', 'Position', [0.228, 0.03, 0.080, 0.038], ...
    'FontSize', 9, 'Tag', 'btnBehavior', ...
    'Callback', @(~,~) playBehaviorVideo(fig7));
uicontrol(fig7, 'Style', 'text', 'String', '', ...
    'Units', 'normalized', 'Position', [0.312, 0.03, 0.120, 0.038], ...
    'FontSize', 9, 'Tag', 'txtBehDay', ...
    'HorizontalAlignment', 'left', 'BackgroundColor', get(fig7, 'Color'));

% --- Left-forelimb visibility toggle (off by default) ----------------
% The left (blue) forelimb traces are hidden unless this box is checked.
uicontrol(fig7, 'Style', 'checkbox', 'String', 'Show Left forelimb', ...
    'Units', 'normalized', 'Position', [0.11 0.955 0.22 0.03], ...
    'FontSize', 9, 'Tag', 'chkShowLeft', 'Value', 0, ...
    'BackgroundColor', get(fig7, 'Color'), ...
    'Callback', @(~,~) plotSingleAnimal( ...
        get(findobj(fig7,'Tag','listboxAnimals'),'Value'), getappdata(fig7,'BehData'), fig7));

% Draw initial selection
plotSingleAnimal(defIdx, BehData, fig7);

%% ── Local functions ──────────────────────────────────────────────────────────

function plotSingleAnimal(animalIdx, BehData, fig7)
% Redraws behavioral subplots and lesion panels for the selected animal.
bd = BehData(animalIdx);
setappdata(fig7, 'selBehData', bd);

% ── Select metric ─────────────────────────────────────────────────────────
metricMethod = 'original';
ftSess = bd.FT_sess;     ccSess = bd.CC_sess;
metricLabel = 'Original';
ftSessField = 'FT_sess';     ccSessField = 'CC_sess';

% ── Composite severity index (4th panel) ──────────────────────────────────
% Severity = z(Fall time) + z(Fall count), matching the population figure's
% "Severity (zFT+zFC)" metric. Each metric is standardized against the FULL
% cohort's session data (every animal, all sessions) so the value means the
% same thing across animals; the two z-scores are then summed (high when
% EITHER fall time or fall count is elevated). NaN sessions stay NaN.
allFT = []; allCC = [];
for a = 1:numel(BehData)
    if isfield(BehData(a), 'FT_sess') && ~isempty(BehData(a).FT_sess)
        allFT = [allFT; BehData(a).FT_sess(:)]; %#ok<AGROW>
    end
    if isfield(BehData(a), 'CC_sess') && ~isempty(BehData(a).CC_sess)
        allCC = [allCC; BehData(a).CC_sess(:)]; %#ok<AGROW>
    end
end
[muFT, sdFT] = poolMeanStd(allFT, []);
[muCC, sdCC] = poolMeanStd(allCC, []);
svSess = zStd(ftSess(:), muFT, sdFT) + zStd(ccSess(:), muCC, sdCC);
svSess = reshape(svSess, size(ftSess));
% Stash on the cached BehData copy so drawDayMarker can read it by field name.
bd.SV_sess = svSess;
setappdata(fig7, 'selBehData', bd);

% Store field names so drawDayMarker can use the same data (4th = Severity).
setappdata(fig7, 'metricSessFields', {ftSessField, ccSessField, 'RHT_sess', 'SV_sess'});

% ── Behavioral plots ──────────────────────────────────────────────────────
metrics   = {ftSess; ccSess; bd.RHT_sess; svSess};
ylabels_s = {'Fall time (min/10min)', 'Fall count (/10min)', ...
             'Regular hold (min/10min)', 'Severity (zFT+zFC)'};
titles_s  = {'Forelimb fall time', 'Fall count', 'Regular hold time', 'Severity'};
invertY   = [true, true, false, true];

% Left forelimb session data (may be NaN if not yet processed). The 4th
% panel's left trace is left-forelimb severity, standardized with the same
% cohort mean/std as the right-forelimb severity.
hasLeft = isfield(bd, 'FT_sess_L') && ~isempty(bd.FT_sess_L) && any(~isnan(bd.FT_sess_L));
metricsL  = {};
if hasLeft
    svSessL = zStd(bd.FT_sess_L(:), muFT, sdFT) + zStd(bd.CC_sess_L(:), muCC, sdCC);
    svSessL = reshape(svSessL, size(bd.FT_sess_L));
    metricsL = {bd.FT_sess_L; bd.CC_sess_L; bd.RHT_sess_L; svSessL};
end

% Left-forelimb traces are drawn only when the "Show Left forelimb" box is on.
showLeft = false;
hChk = findobj(fig7, 'Tag', 'chkShowLeft');
if ~isempty(hChk), showLeft = logical(get(hChk, 'Value')); end

for sp = 1:4
    ax = findobj(fig7, 'Type', 'axes', 'Tag', sprintf('singleAx%d', sp));
    legend(ax, 'off');   % delete any legend from a previous animal before cla
    cla(ax);
    axis(ax, 'auto');
    hold(ax, 'on');
    pod  = bd.POD_sess;
    vals = metrics{sp};

    % Right forelimb (black)
    plot(ax, pod, vals, 'ko-', 'LineWidth', 1.5, 'MarkerSize', 5, ...
        'MarkerFaceColor', 'w', 'DisplayName', 'Right');

    % Left forelimb overlay (blue) — hidden unless the "Show Left forelimb"
    % checkbox is ticked.
    if showLeft && hasLeft && ~isempty(metricsL)
        valsL = metricsL{sp};
        plot(ax, pod, valsL, 'b^--', 'LineWidth', 1.2, 'MarkerSize', 4, ...
            'MarkerFaceColor', 'w', 'DisplayName', 'Left');
    end

    xline(ax, 0, '--k', 'LineWidth', 1, 'HandleVisibility', 'off');
    xlabel(ax, 'Days post-infarction');
    ylabel(ax, ylabels_s{sp});
    set(ax, 'TickDir', 'out', 'Box', 'off');
    if invertY(sp)
        set(ax, 'YDir', 'reverse');
    end
    % Legend after all axis properties are set to avoid YDir being reset.
    % Only meaningful when a Left trace is actually shown alongside Right.
    if showLeft && hasLeft
        legend(ax, 'Location', 'best', 'FontSize', 7, 'Box', 'off');
    end
end

sgtitle(fig7, sprintf('%s  (%s)  [%s]', bd.ID, bd.Group, metricLabel));

% ── Behavior day controls ─────────────────────────────────────────────────
pod_sess   = bd.POD_sess;
surgDate   = bd.SurgDate;
movFolder  = '';
if isfield(bd, 'MovieFolder'), movFolder = bd.MovieFolder; end

behMovies      = cell(length(pod_sess), 1);
behMovieFrames = zeros(length(pod_sess), 1);   % frame counts for same-day disambiguation
if ~isempty(movFolder) && isfolder(movFolder)
    labFiles = dir(fullfile(movFolder, '*_labeled.mp4'));
    for jj = 1:length(labFiles)
        mDate = parseDateFromFilename(labFiles(jj).name);
        if isnat(mDate), continue; end
        mPOD = days(mDate - surgDate);
        [dif, di] = min(abs(pod_sess - mPOD));
        if dif < 0.6
            candidatePath = fullfile(labFiles(jj).folder, labFiles(jj).name);
            % Find the matching _FallCount.mat by stripping the DLC/labeled suffix
            [cDir, cBase] = fileparts(candidatePath);
            cBase = regexprep(cBase, '\s*DLC_.*$', '');
            cBase = regexprep(cBase, '\s*_labeled$', '');
            cMatPath = fullfile(cDir, [strtrim(cBase) '_FallCount.mat']);
            cFrames = 0;
            if exist(cMatPath, 'file')
                try
                    cS = load(cMatPath, 'distance_mm_filtered', 'distance_mm');
                    if isfield(cS, 'distance_mm_filtered')
                        cFrames = numel(cS.distance_mm_filtered);
                    elseif isfield(cS, 'distance_mm')
                        cFrames = numel(cS.distance_mm);
                    end
                catch, end
            end
            % Keep the longest recording when multiple sessions fall on the same day
            if isempty(behMovies{di}) || cFrames > behMovieFrames(di)
                if ~isempty(behMovies{di})
                    fprintf('behMovies: same day — replacing %s (%d fr) with %s (%d fr)\n', ...
                        behMovies{di}, behMovieFrames(di), candidatePath, cFrames);
                end
                behMovies{di}      = candidatePath;
                behMovieFrames(di) = cFrames;
            end
        end
    end
end
setappdata(fig7, 'behMovies',   behMovies);
setappdata(fig7, 'behPOD_sess', pod_sess);
setappdata(fig7, 'behDayIdx',   1);
drawDayMarker(fig7);
updateBehDayLabel(fig7);

% ── Lesion panels ─────────────────────────────────────────────────────────
% Track handles via appdata so even tagless piechart objects get deleted.
lesionMapPos = [0.542, 0.52, 0.176, 0.40];  % 80% of original, shifted up
% Pie chart shrinks to make room for event scatter when a non-original metric is selected
if strcmp(metricMethod, 'original')
    lesionPiePos = [0.52, 0.09, 0.23, 0.32];
else
    lesionPiePos = [0.52, 0.25, 0.23, 0.16];
end

hMap = getappdata(fig7, 'lesionMapHandle');
if ~isempty(hMap) && all(isvalid(hMap)), delete(hMap); end
axM = axes('Parent', fig7, 'Position', lesionMapPos, 'Tag', 'singleAxLesionMap');
setappdata(fig7, 'lesionMapHandle', axM);

hPie = getappdata(fig7, 'lesionPieHandle');
if ~isempty(hPie) && all(isvalid(hPie)), delete(hPie); end
axP = axes('Parent', fig7, 'Position', lesionPiePos, 'Tag', 'singleAxLesionPie');
setappdata(fig7, 'lesionPieHandle', axP);

% ── Event scatter axes (below pie, visible only for dv/gmm metric) ────────
axEvt = findobj(fig7, 'Tag', 'singleAxEventScatter');
if strcmp(metricMethod, 'original')
    if ~isempty(axEvt) && all(isvalid(axEvt)), cla(axEvt); set(axEvt,'Visible','off'); end
else
    evtPos = [0.52, 0.09, 0.23, 0.14];
    if isempty(axEvt) || ~all(isvalid(axEvt))
        axes('Parent', fig7, 'Position', evtPos, 'Tag', 'singleAxEventScatter');
    else
        set(axEvt, 'Position', evtPos, 'Visible', 'on');
        cla(axEvt);
    end
end
drawEventScatter(fig7);

CCF_root  = fullfile(getDataServerRoot(), 'ImagingData\Iwai\DAPI_Data');
ccfFiles  = findCCFFiles(CCF_root, bd.ID);

% Reset slice buttons and clear stale indicator handle
set(findobj(fig7,'Tag','btnSliceBack'), 'Enable','off');
set(findobj(fig7,'Tag','btnSliceNext'), 'Enable','off');

% Clear slice axes
hSAx = getappdata(fig7, 'sliceAxHandle');
if ~isempty(hSAx) && all(isvalid(hSAx)), cla(hSAx); axis(hSAx,'off'); end

if isempty(ccfFiles)
    % No CCF data (sham or not yet processed)
    text(axM, 0.5, 0.5, 'No lesion data', ...
        'HorizontalAlignment','center','Units','normalized','FontSize',9);
    text(axP, 0.5, 0.5, '', 'Units','normalized');
    return
end

S = load(fullfile(ccfFiles(1).folder, ccfFiles(1).name));
lesion_ccf  = S.lesion_ccf;
Area_mapRGB = S.Area_mapRGB;

% Load per-slice AP coordinate from histology_ccf.mat.
% This is the authoritative mapping: slice file index → CCF AP position.
% (Avoids the broken assumption that unique AP values in lesion_ccf.points
%  align 1:1 with slice file indices, which fails when some slices have no
%  lesion annotation.)
sliceAP   = [];
avSlices  = {};
histCCF_fn = fullfile(ccfFiles(1).folder, 'histology_ccf.mat');
if exist(histCCF_fn, 'file')
    hCCF    = load(histCCF_fn, 'histology_ccf');
    sliceAP  = arrayfun(@(s) round(mean(s.plane_ap(:), 'omitnan')), hCCF.histology_ccf);
    avSlices = {hCCF.histology_ccf.av_slices};
end
atlasTforms = {};
tformFn = fullfile(ccfFiles(1).folder, 'atlas2histology_tform.mat');
if exist(tformFn, 'file')
    tData = load(tformFn, 'atlas2histology_tform');
    atlasTforms = tData.atlas2histology_tform;
end
setappdata(fig7, 'sliceAP',      sliceAP);
setappdata(fig7, 'avSlices',     avSlices);
setappdata(fig7, 'atlasTforms',  atlasTforms);

% ---- Top-view map ----
imagesc(axM, Area_mapRGB);
axis(axM, 'image');  axis(axM, 'off');
set(axM, 'YDir', 'reverse', 'XDir', 'normal');   % lock correct orientation
hold(axM, 'on');
slice_width  = 50 * 0.001;   % 50 µm slice spacing in mm
volTotal_mm3 = 0;

MIN_LESION_VOL_MM3 = 0.02;   % below this a sub-lesion is a histology marker, not tissue
for lsn = 1:length(lesion_ccf)
    lVol = sum(lesion_ccf(lsn).lesion_area_size) * 0.010 * 0.010 * slice_width;
    if lVol < MIN_LESION_VOL_MM3
        pc = [0 1 1];      % cyan = sub-threshold histology marker (excluded from total)
    else
        pc = [1 0 0];      % red = lesion tissue
        volTotal_mm3 = volTotal_mm3 + lVol;
    end
    patch(axM, ...
        'XData',      lesion_ccf(lsn).lesionArea_TopView(:,1), ...
        'YData',      lesion_ccf(lsn).lesionArea_TopView(:,2), ...
        'EdgeColor',  pc, 'FaceColor', pc, 'FaceAlpha', 0.4);
end
plot(axM, 570, 540, 'r+', 'MarkerSize', 12, 'LineWidth', 1.5);   % bregma
title(axM, sprintf('Total lesion: %.3f mm³', volTotal_mm3), 'FontSize', 8);
% Freeze limits so the slice indicator line cannot rescale the axes.
% Store image limits in appdata for use in drawSlice.
set(axM, 'XLimMode', 'manual', 'YLimMode', 'manual');
setappdata(fig7, 'lesionMapXLim', get(axM, 'XLim'));
setappdata(fig7, 'lesionMapYLim', get(axM, 'YLim'));

% White 1 mm scale bar (top-view map is 100 px/mm), lower-left corner
xlM = get(axM, 'XLim');  ylM = get(axM, 'YLim');
xb0 = xlM(1) + 0.08*diff(xlM);
yb0 = ylM(1) + 0.08*diff(ylM);
plot(axM, [xb0, xb0+100], [yb0 yb0], 'w-', 'LineWidth', 2);
text(axM, xb0+50, yb0 + 0.04*diff(ylM), '1 mm', ...
    'HorizontalAlignment','center', 'Color','w', 'FontSize', 8);


% ---- Slice viewer setup (after limits stored so indicator line can draw) ----
ccfFolder  = ccfFiles(1).folder;
sliceFiles = dir(fullfile(ccfFolder, 'slice_*.tif'));
if ~isempty(sliceFiles)
    nums = cellfun(@(n) str2double(regexp(n,'\d+','match','once')), {sliceFiles.name});
    [~,si] = sort(nums);
    sliceFiles = sliceFiles(si);
end
setappdata(fig7, 'sliceFiles', sliceFiles);
setappdata(fig7, 'sliceIdx',   1);
setappdata(fig7, 'lesionCCF',  lesion_ccf);
if ~isempty(sliceFiles)
    drawSlice(fig7, 1);
    enNext = 'off'; if length(sliceFiles) > 1, enNext = 'on'; end
    set(findobj(fig7,'Tag','btnSliceNext'), 'Enable', enNext);
end

% ---- Area breakdown ----
MIN_LESION_VOL_MM3 = 0.02;   % below this a sub-lesion is a histology marker, not tissue
areaNames = {};
areaVols  = [];
for lsn = 1:length(lesion_ccf)
    vol = sum(lesion_ccf(lsn).lesion_area_size) * 0.010 * 0.010 * slice_width;
    if vol < MIN_LESION_VOL_MM3, continue; end   % skip histology markers
    acr = lesion_ccf(lsn).lesion_areas.acronym;
    % Strip from first digit onward: 'MOp6a'→'MOp', 'MOp2'→'MOp'
    % (matches OutputSummary_MOp_volume_Lever.m lines 57-65)
    acr = cellfun(@(x) x(1:find(isstrprop(x,'digit'),1)-1), acr, 'UniformOutput', false);
    uAcr = unique(acr);
    uAcr = uAcr(~cellfun('isempty', uAcr));   % drop entries with no digits
    cnt  = cell2mat(cellfun(@(x) sum(strcmp(acr,x)), uAcr, 'UniformOutput', false));
    v    = cnt(:) / sum(cnt) * vol;
    areaNames = [areaNames; uAcr(:)];  %#ok<AGROW>
    areaVols  = [areaVols;  v(:)];     %#ok<AGROW>
end

% Merge duplicates across lesions, sort largest first
[uA, ~, ic] = unique(areaNames);
uV = accumarray(ic, areaVols);
[uV, si] = sort(uV, 'descend');
uA = uA(si);

% Pie chart — keep top-N to avoid clutter, lump rest as 'other'
maxSlices = 7;
if length(uV) > maxSlices
    other = sum(uV(maxSlices+1:end));
    uV = [uV(1:maxSlices); other];
    uA = [uA(1:maxSlices); {'other'}];
end

% Draw pie manually: clockwise from 12 o'clock, full control over angles.
% Each slice is colored by its Allen CCF region color (the same
% color_hex_triplet LUT that colors the top-view lesion map above), so a
% given area (e.g. MOs) always shows the same color regardless of its
% volume rank. The lumped 'other' slice gets a neutral gray.
cla(axP);
hold(axP, 'on');
axis(axP, 'equal');  axis(axP, 'off');
fracs  = uV / sum(uV);
N      = 120;          % arc resolution
theta  = pi/2;         % 12 o'clock start
for k = 1:numel(uV)
    if strcmp(uA{k}, 'other')
        sliceCol = [0.7 0.7 0.7];
    else
        sliceCol = ccfAreaColor(uA{k});
    end
    dtheta = -2*pi*fracs(k);          % negative = clockwise
    arc    = linspace(theta, theta+dtheta, N);
    px     = [0, cos(arc), 0];
    py     = [0, sin(arc), 0];
    patch(axP, px, py, sliceCol, 'EdgeColor', 'w', 'LineWidth', 0.8);
    % Label at slice midpoint, outside the circle
    mid = theta + dtheta/2;
    text(axP, 1.25*cos(mid), 1.25*sin(mid), ...
        sprintf('%s\n%.3f mm³', uA{k}, uV(k)), ...
        'HorizontalAlignment', 'center', 'FontSize', 7);
    theta = theta + dtheta;
end
hold(axP, 'off');
title(axP, 'Area breakdown', 'FontSize', 8);
end

function drawSlice(fig7, idx)
% Load slice image, overlay lesion contour, update Back/Next buttons.
sliceFiles = getappdata(fig7, 'sliceFiles');
lesion_ccf = getappdata(fig7, 'lesionCCF');
n = length(sliceFiles);
idx = max(1, min(n, idx));
setappdata(fig7, 'sliceIdx', idx);

% Retrieve or recreate slice axes
axS = getappdata(fig7, 'sliceAxHandle');
if isempty(axS) || ~isvalid(axS)
    axS = axes('Parent', fig7, 'Position', [0.76, 0.47, 0.22, 0.45], ...
                'Tag', 'singleAxSlice');
    setappdata(fig7, 'sliceAxHandle', axS);
end
cla(axS);

% Load and invert the slice image (dark tissue on white background)
img = imread(fullfile(sliceFiles(idx).folder, sliceFiles(idx).name));
if size(img,3) == 3
    img = rgb2gray(img);
end
img = imcomplement(img);

% Check each overlay toggle independently
hTglLesion = findobj(fig7, 'Tag', 'btnToggleLesion');
hTglAtlas  = findobj(fig7, 'Tag', 'btnToggleAtlas');
showLesion = ~isempty(hTglLesion) && get(hTglLesion, 'Value') == 1;
showAtlas  = ~isempty(hTglAtlas)  && get(hTglAtlas,  'Value') == 1;

% Always display the grayscale slice first
imagesc(axS, img);
colormap(axS, gray(256));
axis(axS, 'equal');  axis(axS, 'off');
hold(axS, 'on');

% --- Atlas boundary overlay (red lines) ---
if showAtlas
    avSlices    = getappdata(fig7, 'avSlices');
    atlasTforms = getappdata(fig7, 'atlasTforms');
    if ~isempty(avSlices)   && idx <= length(avSlices) && ...
       ~isempty(atlasTforms) && idx <= length(atlasTforms)
        av = avSlices{idx};
        av(isnan(av)) = 1;
        tform   = affine2d;
        tform.T = atlasTforms{idx};
        tform_size = imref2d([size(img,1), size(img,2)]);
        av_warped  = imwarp(av, tform, 'nearest', 'OutputView', tform_size);
        boundaries = boundarymask(av_warped);
        redLayer = zeros([size(img,1), size(img,2), 3], 'uint8');
        redLayer(:,:,2) = 255;   % G
        redLayer(:,:,3) = 255;   % B  → cyan
        hBound = image(axS, redLayer);
        set(hBound, 'AlphaData', uint8(boundaries) * 220);
    end
end

% --- Lesion overlay (red semitransparent patch) ---
if showLesion && ~isempty(lesion_ccf)
    for lsn = 1:length(lesion_ccf)
        pts_hist = [];
        if isfield(lesion_ccf(lsn), 'lesion_points_histology') && ...
           ~isempty(lesion_ccf(lsn).lesion_points_histology) && ...
           size(lesion_ccf(lsn).lesion_points_histology, 1) >= idx && ...
           size(lesion_ccf(lsn).lesion_points_histology, 2) >= lsn
            pts_hist = lesion_ccf(lsn).lesion_points_histology{idx, lsn};
        end
        if ~isempty(pts_hist)
            patch(axS, pts_hist(:,1), pts_hist(:,2), 'r', ...
                  'FaceAlpha', 0.25, 'EdgeColor', 'r', 'LineWidth', 1.5);
        end
    end
end

% Black 1 mm scale bar. The atlas→histology transform gives the histology
% pixel size: 1 atlas voxel = 10 µm, so 1 mm = 100 voxels, scaled into
% histology pixels by the transform's linear part.
atlasTf = getappdata(fig7, 'atlasTforms');
if ~isempty(atlasTf) && idx <= numel(atlasTf) && ~isempty(atlasTf{idx})
    pxPerVoxel = sqrt(abs(det(atlasTf{idx}(1:2,1:2))));  % hist px per 10-µm voxel
    barLen = 100 * pxPerVoxel;                            % 100 voxels = 1 mm
    W = size(img,2);  H = size(img,1);
    xb = 0.06*W;  yb = 0.94*H;
    plot(axS, [xb, xb+barLen], [yb yb], 'k-', 'LineWidth', 2);
    text(axS, xb + barLen/2, yb - 0.04*H, '1 mm', ...
        'HorizontalAlignment','center', 'Color','k', 'FontSize', 8);
end

title(axS, sprintf('Slice %d / %d', idx, n), 'FontSize', 8);

% Update button states
enBack = 'off'; if idx > 1, enBack = 'on'; end
enNext = 'off'; if idx < n, enNext = 'on'; end
set(findobj(fig7,'Tag','btnSliceBack'), 'Enable', enBack);
set(findobj(fig7,'Tag','btnSliceNext'), 'Enable', enNext);

% Draw horizontal cyan line on lesion map at the AP position of this slice
axM = getappdata(fig7, 'lesionMapHandle');
if isgraphics(axM, 'axes')
    % Get AP coordinate for this slice from histology_ccf (authoritative).
    % Falls back to index-clamping into lesion points if not available.
    sliceAP = getappdata(fig7, 'sliceAP');
    currAP  = [];
    if ~isempty(sliceAP) && idx <= length(sliceAP)
        currAP = sliceAP(idx);
    elseif ~isempty(lesion_ccf)
        allAP = [];
        for lsn = 1:length(lesion_ccf)
            if ~isempty(lesion_ccf(lsn).points)
                allAP = [allAP; lesion_ccf(lsn).points(:,1)]; %#ok<AGROW>
            end
        end
        if ~isempty(allAP)
            AP_s  = sort(unique(allAP));
            currAP = AP_s(max(1, min(idx, length(AP_s))));
        end
    end

    if ~isempty(currAP)
        % Delete previous indicator line
        hOld = getappdata(fig7, 'apLineHandle');
        if isgraphics(hOld, 'line')
            delete(hOld);
        end

        % Draw new line spanning the full image width
        xl = get(axM, 'XLim');
        hold(axM, 'on');
        hLine = plot(axM, xl, [currAP currAP], 'c-', 'LineWidth', 1.2);
        setappdata(fig7, 'apLineHandle', hLine);
        set(axM, 'XLim', xl);
    end
end
end

% ── Population figure helpers ────────────────────────────────────────────────

function updatePopulationFromFig7(fig7)
% Read M1/M2/S1 toggles + volume thresholds and redraw the population figure.
BehData = getappdata(fig7, 'BehData');
figPop  = getappdata(fig7, 'figPop');
StdPOD  = getappdata(fig7, 'StdPOD');

% Build filter from toggle states (empty = all infarction)
filterFields = {};
hM1 = findobj(fig7, 'Tag', 'chkM1');
hM2 = findobj(fig7, 'Tag', 'chkM2');
hS1 = findobj(fig7, 'Tag', 'chkS1');
if ~isempty(hM1) && get(hM1, 'Value'), filterFields{end+1} = 'hasM1'; end
if ~isempty(hM2) && get(hM2, 'Value'), filterFields{end+1} = 'hasM2'; end
if ~isempty(hS1) && get(hS1, 'Value'), filterFields{end+1} = 'hasS1'; end

% Read minimum volume threshold edit boxes
thresholds.M1 = 0;  thresholds.M2 = 0;  thresholds.S1 = 0;
hE1 = findobj(fig7, 'Tag', 'editThreshM1');
hE2 = findobj(fig7, 'Tag', 'editThreshM2');
hE3 = findobj(fig7, 'Tag', 'editThreshS1');
if ~isempty(hE1), v = str2double(get(hE1,'String')); if ~isnan(v) && v >= 0, thresholds.M1 = v; end; end
if ~isempty(hE2), v = str2double(get(hE2,'String')); if ~isnan(v) && v >= 0, thresholds.M2 = v; end; end
if ~isempty(hE3), v = str2double(get(hE3,'String')); if ~isnan(v) && v >= 0, thresholds.S1 = v; end; end

% Read maximum volume threshold edit boxes (default: Inf = no upper limit)
maxVol.M1 = Inf;  maxVol.M2 = Inf;  maxVol.S1 = Inf;
hF1 = findobj(fig7, 'Tag', 'editMaxM1');
hF2 = findobj(fig7, 'Tag', 'editMaxM2');
hF3 = findobj(fig7, 'Tag', 'editMaxS1');
if ~isempty(hF1), v = str2double(get(hF1,'String')); if ~isnan(v) && v > 0, maxVol.M1 = v; end; end
if ~isempty(hF2), v = str2double(get(hF2,'String')); if ~isnan(v) && v > 0, maxVol.M2 = v; end; end
if ~isempty(hF3), v = str2double(get(hF3,'String')); if ~isnan(v) && v > 0, maxVol.S1 = v; end; end

% Read AND/OR popup (1=OR, 2=AND)
useAnd = false;
hAO = findobj(fig7, 'Tag', 'popAndOr');
if ~isempty(hAO) && get(hAO, 'Value') == 2, useAnd = true; end

metricMethod = 'original';

CCF_root_beh = getappdata(fig7, 'CCF_root_beh');

% Create the population figure on first use (figPop starts empty) or
% recreate it if it was closed.
if isempty(figPop) || ~isgraphics(figPop, 'figure')
    figPop = figure('Name', 'Infarction vs Sham - Lever Pull Task', ...
        'Position', [100 50 1000 900]);
    setappdata(fig7, 'figPop', figPop);
else
    figure(figPop);
end
drawPopulationFigure(BehData, figPop, StdPOD, filterFields, thresholds, useAnd, maxVol, metricMethod);

% Lesion map summary figure
figSum = getappdata(fig7, 'figSum');
if isempty(figSum) || ~isgraphics(figSum, 'figure')
    figSum = figure('Name', 'Lesion Map Summary', 'Position', [1120 50 500 500]);
    setappdata(fig7, 'figSum', figSum);
else
    figure(figSum);
end
drawLesionSummaryFigure(BehData, filterFields, thresholds, useAnd, maxVol, CCF_root_beh, figSum);
end

function drawPopulationFigure(BehData, figPop, StdPOD, filterFields, thresholds, useAnd, maxVol, metricMethod, infMaskOverride, filterStrOverride, overlayMask, overlayLabel)
% Draw (or redraw) the population comparison figure.
%
% filterFields : cell array of region keys, e.g. {'hasM1'}, {'hasM1','hasS1'}, {}.
%   Empty → include all infarction animals.
% thresholds   : struct with fields M1, M2, S1 — minimum volume (mm³, default 0).
%   0: use boolean hasM1/hasM2/hasS1; >0: use volM1/volM2/volS1 > threshold.
% useAnd       : logical. true = AND (all active regions must pass); false = OR (any passes).
% maxVol       : struct with fields M1, M2, S1 — maximum volume (mm³, default Inf).
%   Inf: no upper limit; finite: volM1/volM2/volS1 <= maxVol.
% metricMethod : 'original' | 'dv' | 'gmm'  (default: 'original')
% infMaskOverride  : optional logical mask over BehData (same length as
%   numel(BehData)). When non-empty it REPLACES the filterFields-based
%   inf-mask construction, so callers (e.g. the M1/M2/S1 figure's
%   "Time course" button) can specify an arbitrary animal subset.
% filterStrOverride: optional human-readable label for the override case
%   (used in sgtitle / per-panel titles). Falls back to "custom (n=N)".
% overlayMask  : optional SECOND logical mask over BehData. When non-empty the
%   figure enters OVERLAY mode: the infMask subset is drawn as the primary
%   "Region" group (red) and this mask as a second "Surround" group (orange),
%   both overlaid with Sham (gray) on every panel. Rank-sum stars then show
%   Region vs Sham (red), Surround vs Sham (orange) and Region vs Surround
%   (purple); the stats CSV gains the matching families. Used by the Lesion
%   Centroids "Select region" toggle to combine its Region + Surround figures.
% overlayLabel : human-readable label for the overlay (Surround) group.

if nargin < 5 || isempty(thresholds)
    thresholds.M1 = 0;  thresholds.M2 = 0;  thresholds.S1 = 0;
end
if nargin < 6 || isempty(useAnd)
    useAnd = false;
end
if nargin < 7 || isempty(maxVol)
    maxVol.M1 = Inf;  maxVol.M2 = Inf;  maxVol.S1 = Inf;
end
if nargin < 8 || isempty(metricMethod)
    metricMethod = 'original';
end
if nargin < 9, infMaskOverride = []; end
if nargin < 10, filterStrOverride = ''; end
if nargin < 11, overlayMask = []; end
if nargin < 12 || isempty(overlayLabel), overlayLabel = 'Surround'; end

% Map from filterField name to (volField, minThresh, maxThresh)
regionMap = struct( ...
    'hasM1', struct('volField','volM1','thresh', thresholds.M1, 'maxVol', maxVol.M1), ...
    'hasM2', struct('volField','volM2','thresh', thresholds.M2, 'maxVol', maxVol.M2), ...
    'hasS1', struct('volField','volS1','thresh', thresholds.S1, 'maxVol', maxVol.S1));

% ── Build group masks ────────────────────────────────────────────────────
allInf   = strcmp({BehData.Group}, 'Infarction');
shamMask = strcmp({BehData.Group}, 'Sham');

if ~isempty(infMaskOverride)
    % Caller supplied an explicit subset (e.g. animals in the upper panels
    % of the M1/M2/S1 figure). Restrict to Infarction defensively so a
    % stray Sham can't slip in even if the override included one.
    infMask = logical(infMaskOverride(:).') & allInf;
    if ~isempty(filterStrOverride)
        filterStr = filterStrOverride;
    else
        filterStr = sprintf('custom (n=%d)', sum(infMask));
    end
elseif isempty(filterFields)
    infMask  = allInf;
    filterStr = 'All Infarction';
else
    infMask = false(size(allInf));
    for i = find(allInf)
        nPass = 0;
        for k = 1:length(filterFields)
            fld = filterFields{k};
            if ~isfield(regionMap, fld), continue; end
            rm = regionMap.(fld);
            if rm.thresh > 0 || ~isinf(rm.maxVol)
                % volume range mode: min ≤ vol ≤ max
                vol = 0;
                if isfield(BehData, rm.volField), vol = BehData(i).(rm.volField); end
                passes = (vol > rm.thresh) && (vol <= rm.maxVol);
            else
                % boolean mode (thresh==0 and maxVol==Inf)
                passes = isfield(BehData, fld) && BehData(i).(fld);
            end
            if passes, nPass = nPass + 1; end
        end
        if useAnd
            infMask(i) = (nPass == length(filterFields));
        else
            infMask(i) = (nPass >= 1);
        end
    end
    % Human-readable label: hasM1→M1 (≥Xmm³) etc.
    labels = cell(size(filterFields));
    for k = 1:length(filterFields)
        fld = filterFields{k};
        name = strrep(fld, 'has', '');
        rm = regionMap.(fld);
        if rm.thresh > 0 && ~isinf(rm.maxVol)
            labels{k} = sprintf('%s(%.2f–%.2fmm³)', name, rm.thresh, rm.maxVol);
        elseif rm.thresh > 0
            labels{k} = sprintf('%s(>%.2fmm³)', name, rm.thresh);
        elseif ~isinf(rm.maxVol)
            labels{k} = sprintf('%s(≤%.2fmm³)', name, rm.maxVol);
        else
            labels{k} = name;
        end
    end
    sep = ' or ';
    if useAnd, sep = ' and '; end
    filterStr = strjoin(labels, sep);
end

% Overlay (Surround) group: a second Infarction subset drawn alongside the
% primary one. Restrict to Infarction defensively, and drop any animal already
% in the primary subset so the two overlaid groups are disjoint.
overlayMode = ~isempty(overlayMask);
if overlayMode
    ovlMask = logical(overlayMask(:).') & allInf & ~infMask;
    overlayMode = any(ovlMask);
else
    ovlMask = false(size(allInf));
end

nInf  = sum(infMask);
nSham = sum(shamMask);
nOvl  = sum(ovlMask);

% Name of the primary group, used by the plots AND by every reported
% statistic. In overlay mode the primary subset is the selected Region and the
% comparison of interest is Region vs Surround: Sham is drawn as a reference
% only, so no Sham comparison is computed, printed or exported there.
primaryName = 'Infarction';
if overlayMode, primaryName = 'Region'; end

ftField    = 'FallTime_10min';
ccField    = 'CrossCount_10min';
metricLabel = 'Original';
% Fall back to original if dv/gmm fields are missing (old FallCount files)
if ~isfield(BehData, ftField)
    ftField = 'FallTime_10min';
    ccField = 'CrossCount_10min';
    metricLabel = 'Original (fallback)';
end

FallTime_Inf = vertcat(BehData(infMask).(ftField));
FallTime_Sha = vertcat(BehData(shamMask).(ftField));
RegHold_Inf  = vertcat(BehData(infMask).RegHoldTime_10min);
RegHold_Sha  = vertcat(BehData(shamMask).RegHoldTime_10min);
Cross_Inf    = vertcat(BehData(infMask).(ccField));
Cross_Sha    = vertcat(BehData(shamMask).(ccField));

% Composite severity index (z-scored Fall time + z-scored Fall count),
% mirroring the "Severity (zFT+zFC)" Color-by option on the M1/M2/S1
% region-relation figure. Each metric is standardized, then summed; high
% when EITHER fall time or fall count is elevated (OR semantics). NaN
% sessions stay NaN.
%
% The z-score reference is the FULL Infarction+Sham cohort (every animal,
% all timepoints) — NOT the currently selected subset. This is what makes
% Severity comparable ACROSS windows: the M1, M2 and S1 centroid time
% courses each plot a different Infarction subset, but all standardize
% against the same fixed mean/SD, so a given Severity value means the same
% thing in every window. (Standardizing within each subset — as before —
% gave each window its own scale, so the numbers weren't comparable.)
refMask      = allInf | shamMask;
[muFT, sdFT] = poolMeanStd(vertcat(BehData(refMask).(ftField)), []);
[muCC, sdCC] = poolMeanStd(vertcat(BehData(refMask).(ccField)), []);
Sever_Inf = zStd(FallTime_Inf, muFT, sdFT) + zStd(Cross_Inf, muCC, sdCC);
Sever_Sha = zStd(FallTime_Sha, muFT, sdFT) + zStd(Cross_Sha, muCC, sdCC);

% Overlay (Surround) group's per-animal x per-POD matrices, standardized with
% the SAME pooled mean/std so Severity is comparable across all three groups.
if overlayMode
    FallTime_Ovl = vertcat(BehData(ovlMask).(ftField));
    Cross_Ovl    = vertcat(BehData(ovlMask).(ccField));
    RegHold_Ovl  = vertcat(BehData(ovlMask).RegHoldTime_10min);
    Sever_Ovl    = zStd(FallTime_Ovl, muFT, sdFT) + zStd(Cross_Ovl, muCC, sdCC);
else
    FallTime_Ovl = []; Cross_Ovl = []; RegHold_Ovl = []; Sever_Ovl = [];
end

% ── Statistics ───────────────────────────────────────────────────────────
pval2stars = @(p) subsref({'','*','**','***'}, struct('type','{}', ...
    'subs', {{1 + (~isnan(p) & p<0.05) + (~isnan(p) & p<0.01) + (~isnan(p) & p<0.001)}}));

metricPairs = {FallTime_Inf, FallTime_Sha; Cross_Inf, Cross_Sha; ...
               RegHold_Inf, RegHold_Sha; Sever_Inf, Sever_Sha};
nMetrics = size(metricPairs, 1);

% Wilcoxon rank-sum: Infarction vs Sham
pvals    = NaN(length(StdPOD), nMetrics);
n_rs_Inf = zeros(length(StdPOD), nMetrics);
n_rs_Sha = zeros(length(StdPOD), nMetrics);
for m = 1:nMetrics
    for t = 1:length(StdPOD)
        x = metricPairs{m,1}(:,t);  x = x(~isnan(x));
        y = metricPairs{m,2}(:,t);  y = y(~isnan(y));
        n_rs_Inf(t,m) = numel(x);
        n_rs_Sha(t,m) = numel(y);
        if numel(x) >= 2 && numel(y) >= 2
            pvals(t,m) = ranksum(x, y);
        end
    end
end

% Wilcoxon signed-rank (paired by animal): each timepoint vs baseline.
% MATLAB's signrank(x,y) with two same-length vectors is the PAIRED test
% on the differences x-y. pI masks to animals with non-NaN at BOTH the
% baseline and the POD-t column, so pI(pI,1) and metricPairs{...}(pI,t)
% are aligned by animal index — i.e. each animal is its own control.
% Also track n_paired per cell; with small n the test's discrete p-value
% floor (~2/2^n) can sit above 0.05 once Holm-corrected at position 1
% (which is Bonferroni-equivalent), which the user wants to see when
% diagnosing "no significance vs baseline".
pvals_Inf       = NaN(length(StdPOD), nMetrics);
pvals_Sha       = NaN(length(StdPOD), nMetrics);
n_Inf_vsBase    = zeros(length(StdPOD), nMetrics);
n_Sha_vsBase    = zeros(length(StdPOD), nMetrics);
for m = 1:nMetrics
    for t = 2:length(StdPOD)
        pI = ~isnan(metricPairs{m,1}(:,1)) & ~isnan(metricPairs{m,1}(:,t));
        n_Inf_vsBase(t,m) = sum(pI);
        if n_Inf_vsBase(t,m) >= 2
            pvals_Inf(t,m) = signrank(metricPairs{m,1}(pI,1), metricPairs{m,1}(pI,t));
        end
        pS = ~isnan(metricPairs{m,2}(:,1)) & ~isnan(metricPairs{m,2}(:,t));
        n_Sha_vsBase(t,m) = sum(pS);
        if n_Sha_vsBase(t,m) >= 2
            pvals_Sha(t,m) = signrank(metricPairs{m,2}(pS,1), metricPairs{m,2}(pS,t));
        end
    end
end

% Wilcoxon signed-rank (paired by animal): each later timepoint vs POD3
% — recovery test. Same paired construction as the vs-baseline block: pI
% masks to animals with non-NaN at BOTH POD3 (column 2) and POD-t, so
% each animal is its own control. StdPOD(2) is POD3 (first post-surgery
% session); comparing t=3..end against t=2 tells us whether the metric
% has moved away from the early post-infarction value, i.e. has been
% recovering (or worsening further).
pvals_Inf_vsP3 = NaN(length(StdPOD), nMetrics);
pvals_Sha_vsP3 = NaN(length(StdPOD), nMetrics);
n_Inf_vsP3     = zeros(length(StdPOD), nMetrics);
n_Sha_vsP3     = zeros(length(StdPOD), nMetrics);
for m = 1:nMetrics
    for t = 3:length(StdPOD)
        pI = ~isnan(metricPairs{m,1}(:,2)) & ~isnan(metricPairs{m,1}(:,t));
        n_Inf_vsP3(t,m) = sum(pI);
        if n_Inf_vsP3(t,m) >= 2
            pvals_Inf_vsP3(t,m) = signrank(metricPairs{m,1}(pI,2), metricPairs{m,1}(pI,t));
        end
        pS = ~isnan(metricPairs{m,2}(:,2)) & ~isnan(metricPairs{m,2}(:,t));
        n_Sha_vsP3(t,m) = sum(pS);
        if n_Sha_vsP3(t,m) >= 2
            pvals_Sha_vsP3(t,m) = signrank(metricPairs{m,2}(pS,2), metricPairs{m,2}(pS,t));
        end
    end
end

% RM ANOVA (Group × Time)
metricNames = {'FallTime_10min','CrossCount_10min','RegularHoldTime_10min', ...
               'Severity_zFTzFC'};
groups = [repmat({primaryName}, nInf, 1); repmat({'Sham'}, nSham, 1)];
anovaByMetric = cell(1, nMetrics);   % captured for the paper-export CSV
lmeContrastsByMetric = cell(1, nMetrics);   % model-based post hoc, CSV only
% Skipped entirely in overlay mode: this model's Group factor is
% primary-vs-Sham, and Sham is not a comparison group there. The Region vs
% Surround model is fitted in the overlay block below instead.
if ~overlayMode
fprintf('\n--- Two-way RM ANOVA — %s ---\n', filterStr)
for m = 1:nMetrics
    data_all = [metricPairs{m,1}; metricPairs{m,2}];
    AnimalID = {}; GroupCol = {}; TimeCol = []; ValCol = [];
    for i = 1:size(data_all,1)
        for t = 1:length(StdPOD)
            if ~isnan(data_all(i,t))
                AnimalID{end+1,1} = sprintf('A%02d',i);
                GroupCol{end+1,1} = groups{i};
                TimeCol(end+1,1)  = StdPOD(t);
                ValCol(end+1,1)   = data_all(i,t);
            end
        end
    end
    if numel(unique(GroupCol)) >= 2 && numel(unique(TimeCol)) >= 2
        Tbl = table(categorical(AnimalID), categorical(GroupCol), ...
                    categorical(TimeCol), ValCol, ...
                    'VariableNames', {'Animal','Group','Time','Value'});
        lme = fitlme(Tbl, 'Value ~ Group * Time + (1|Animal)');
        aT  = anova(lme);
        anovaByMetric{m} = aT;
        % Model-based post hoc for the same model the RM ANOVA above reports:
        % the group difference AT EACH TIMEPOINT, as a contrast on the fitted
        % LME, Sidak-adjusted across the post-surgery timepoints. Exported to
        % the stats CSV only — the figure's asterisks stay on the Wilcoxon
        % tests. Gives an effect size with a CI rather than only a p-value,
        % and unlike fitrm/ranova it keeps animals that are missing a session
        % (those contribute their available timepoints instead of being
        % dropped listwise).
        lmeContrastsByMetric{m} = lmeGroupContrasts(lme, Tbl, StdPOD);
        fprintf('%s:\n', metricNames{m})
        for r = 1:height(aT)
            fprintf('  %-20s F(%s,%s)=%.3f p=%.4f\n', aT.Term{r}, ...
                num2str(aT.DF1(r)), num2str(aT.DF2(r)), aT.FStat(r), aT.pValue(r))
        end
    end
end
end   % ~overlayMode

% Holm-Bonferroni (step-down): applied per family = per metric x per
% group x per test type. Sort the family's p-values, multiply the i-th
% smallest by k-i+1, take the running max so adjustments stay monotone,
% cap at 1. Less conservative than Sidak/Bonferroni when there are
% multiple small p's; smallest p still must clear alpha/k.
%   vs baseline: 8 POD comparisons per metric (k_holm = length(StdPOD)-1).
%   vs POD3    : 7 POD comparisons per metric (k_holm_P3 = length-2).
k_holm    = length(StdPOD) - 1;
k_holm_P3 = max(1, length(StdPOD) - 2);

pvals_Inf_Holm = NaN(size(pvals_Inf));
pvals_Sha_Holm = NaN(size(pvals_Sha));
for m = 1:nMetrics
    pvals_Inf_Holm(2:end, m) = holmAdjust(pvals_Inf(2:end, m));
    pvals_Sha_Holm(2:end, m) = holmAdjust(pvals_Sha(2:end, m));
end

pvals_Inf_vsP3_Holm = NaN(size(pvals_Inf_vsP3));
pvals_Sha_vsP3_Holm = NaN(size(pvals_Sha_vsP3));
for m = 1:nMetrics
    pvals_Inf_vsP3_Holm(3:end, m) = holmAdjust(pvals_Inf_vsP3(3:end, m));
    pvals_Sha_vsP3_Holm(3:end, m) = holmAdjust(pvals_Sha_vsP3(3:end, m));
end

% Rank-sum (Infarction vs Sham per timepoint) gets the SAME treatment: the
% family is the k_holm post-surgery timepoints of one metric, exactly as for
% the paired tests above. These are post hoc comparisons following the
% Group×Time RM ANOVA, and leaving one star row uncorrected while the others
% are corrected isn't defensible — a mixed panel just reflects the order the
% rows were added. Row 1 (pre-surgery baseline) stays OUT of the family: it
% is a baseline-equivalence check, not a hypothesis test, so correcting it
% against the post-surgery tests would both weaken them and misstate it.
% The uncorrected values stay in `pvals` and are still written to the CSV.
pvals_rs_Holm = NaN(size(pvals));
for m = 1:nMetrics
    pvals_rs_Holm(2:end, m) = holmAdjust(pvals(2:end, m));
end

% ── Overlay (Surround) group statistics (overlay mode only) ───────────────
% Region here = the primary infMask group; Surround = ovlMask group. We add
% the two extra rank-sum families the overlay panels show (Surround vs Sham,
% Region vs Surround) plus Surround's paired signed-rank vs baseline / vs POD3
% and a Region-vs-Surround RM ANOVA, so the stats CSV is complete.
pvals_ovl_rs = NaN(length(StdPOD), nMetrics);   % Surround vs Sham
n_ovl_rs     = zeros(length(StdPOD), nMetrics);
n_sha_ovl    = zeros(length(StdPOD), nMetrics);
pvals_RS_rs  = NaN(length(StdPOD), nMetrics);    % Region vs Surround
n_reg_RS     = zeros(length(StdPOD), nMetrics);
n_ovl_RS     = zeros(length(StdPOD), nMetrics);
pvals_Ovl_vsBase = NaN(length(StdPOD), nMetrics);
n_Ovl_vsBase     = zeros(length(StdPOD), nMetrics);
pvals_Ovl_vsP3   = NaN(length(StdPOD), nMetrics);
n_Ovl_vsP3       = zeros(length(StdPOD), nMetrics);
anovaRSByMetric  = cell(1, nMetrics);
lmeContrastsRSByMetric = cell(1, nMetrics);   % Region - Surround, CSV only
if overlayMode
    metricOvl = {FallTime_Ovl, Cross_Ovl, RegHold_Ovl, Sever_Ovl};
    fprintf('\n--- Two-way RM ANOVA (Region x Surround) — %s ---\n', filterStr)
    for m = 1:nMetrics
        oData = metricOvl{m};
        for t = 1:length(StdPOD)
            xr = metricPairs{m,1}(:,t);  xr = xr(~isnan(xr));   % Region
            xo = oData(:,t);             xo = xo(~isnan(xo));   % Surround
            ys = metricPairs{m,2}(:,t);  ys = ys(~isnan(ys));   % Sham
            n_ovl_rs(t,m) = numel(xo);  n_sha_ovl(t,m) = numel(ys);
            n_reg_RS(t,m) = numel(xr);  n_ovl_RS(t,m)  = numel(xo);
            if numel(xo) >= 2 && numel(ys) >= 2
                pvals_ovl_rs(t,m) = ranksum(xo, ys);
            end
            if numel(xr) >= 2 && numel(xo) >= 2
                pvals_RS_rs(t,m) = ranksum(xr, xo);
            end
        end
        for t = 2:length(StdPOD)
            pO = ~isnan(oData(:,1)) & ~isnan(oData(:,t));
            n_Ovl_vsBase(t,m) = sum(pO);
            if n_Ovl_vsBase(t,m) >= 2
                pvals_Ovl_vsBase(t,m) = signrank(oData(pO,1), oData(pO,t));
            end
        end
        for t = 3:length(StdPOD)
            pO = ~isnan(oData(:,2)) & ~isnan(oData(:,t));
            n_Ovl_vsP3(t,m) = sum(pO);
            if n_Ovl_vsP3(t,m) >= 2
                pvals_Ovl_vsP3(t,m) = signrank(oData(pO,2), oData(pO,t));
            end
        end
        % Region vs Surround RM ANOVA (Group x Time) via LME.
        data_all = [metricPairs{m,1}; oData];
        grpRS = [repmat({'Region'}, nInf, 1); repmat({'Surround'}, nOvl, 1)];
        AnimalID = {}; GroupCol = {}; TimeCol = []; ValCol = [];
        for i = 1:size(data_all,1)
            for t = 1:length(StdPOD)
                if ~isnan(data_all(i,t))
                    AnimalID{end+1,1} = sprintf('A%02d',i); %#ok<AGROW>
                    GroupCol{end+1,1} = grpRS{i};            %#ok<AGROW>
                    TimeCol(end+1,1)  = StdPOD(t);           %#ok<AGROW>
                    ValCol(end+1,1)   = data_all(i,t);       %#ok<AGROW>
                end
            end
        end
        if numel(unique(GroupCol)) >= 2 && numel(unique(TimeCol)) >= 2
            Tbl = table(categorical(AnimalID), categorical(GroupCol), ...
                        categorical(TimeCol), ValCol, ...
                        'VariableNames', {'Animal','Group','Time','Value'});
            lme = fitlme(Tbl, 'Value ~ Group * Time + (1|Animal)');
            aRS = anova(lme);
            anovaRSByMetric{m} = aRS;
            % Same model-based post hoc the Infarction-vs-Sham figure gets,
            % but for the pair this figure actually compares: Region minus
            % Surround at each timepoint, Sidak-adjusted.
            lmeContrastsRSByMetric{m} = lmeGroupContrasts(lme, Tbl, StdPOD);
            fprintf('%s:\n', metricNames{m})
            for r = 1:height(aRS)
                fprintf('  %-20s F(%s,%s)=%.3f p=%.4f\n', aRS.Term{r}, ...
                    num2str(aRS.DF1(r)), num2str(aRS.DF2(r)), aRS.FStat(r), aRS.pValue(r))
            end
        end
    end
end
pvals_Ovl_Holm      = NaN(size(pvals_Ovl_vsBase));
pvals_Ovl_vsP3_Holm = NaN(size(pvals_Ovl_vsP3));
% The overlay panels' two extra rank-sum rows are corrected the same way, for
% the same reason: all star rows in one panel share one correction policy.
pvals_ovl_rs_Holm = NaN(size(pvals_ovl_rs));
pvals_RS_rs_Holm  = NaN(size(pvals_RS_rs));
if overlayMode
    for m = 1:nMetrics
        pvals_Ovl_Holm(2:end, m)      = holmAdjust(pvals_Ovl_vsBase(2:end, m));
        pvals_Ovl_vsP3_Holm(3:end, m) = holmAdjust(pvals_Ovl_vsP3(3:end, m));
        pvals_ovl_rs_Holm(2:end, m)   = holmAdjust(pvals_ovl_rs(2:end, m));
        pvals_RS_rs_Holm(2:end, m)    = holmAdjust(pvals_RS_rs(2:end, m));
    end
end

% Console summary of the per-timepoint stats (the ones that drive the
% asterisks on the panels). Gated on the override path so only the
% centroid time-course windows print this — the existing Infarction-vs-
% Sham figure keeps its previous (RM ANOVA only) console output.
if ~isempty(infMaskOverride)
    metricShort = {'Fall time','Fall count','Reg hold','Severity'};
    fprintf('\n=== Centroid time-course stats — %s ===\n', filterStr);
    % In overlay mode every reported comparison is Region vs Surround or
    % within one of those two groups; Sham is drawn on the panels as a
    % reference and is not tested, so it is absent from all of these tables.
    if overlayMode
        fprintf('  n: %s=%d, %s=%d  (Sham n=%d drawn for reference only, not tested)\n', ...
            primaryName, nInf, overlayLabel, nOvl, nSham);
        rsName = sprintf('%s vs %s', primaryName, overlayLabel);
        pRS    = pvals_RS_rs;   pRSh = pvals_RS_rs_Holm;
    else
        fprintf('  n: %s=%d, Sham=%d\n', primaryName, nInf, nSham);
        rsName = sprintf('%s vs Sham', primaryName);
        pRS    = pvals;         pRSh = pvals_rs_Holm;
    end

    fprintf(['\n  Wilcoxon rank-sum  (%s), per POD  ' ...
             '(cells: uncorrected / Holm-Bonferroni, k=%d):\n'], rsName, k_holm);
    fprintf('  (POD -1 is the baseline-equivalence check — outside the corrected family)\n');
    fprintf('  %-9s', 'POD');
    fprintf(' %-20s', metricShort{:});
    fprintf('\n');
    for t = 1:length(StdPOD)
        fprintf('  POD %4d ', StdPOD(t));
        for m = 1:nMetrics
            p  = pRS(t, m);
            pc = pRSh(t, m);
            if isnan(p)
                fprintf('     -               ');
            elseif isnan(pc)
                fprintf(' %6.4f /    -       ', p);
            else
                % Stars follow the Holm-corrected p — the reportable one.
                fprintf(' %6.4f /%6.4f%-6s', p, pc, pval2stars(pc));
            end
        end
        fprintf('\n');
    end

    % Signed-rank tables show "uncorrected / Holm-corrected" with the
    % paired n per row so it's visible when the discrete signed-rank
    % p-value floor (~ 2 / 2^n) limits what the corrected p can reach.
    % Example: paired n=8 -> uncorrected floor 0.0078; smallest Holm
    % position needs uncorrected < 0.05/k (Bonferroni) to clear 0.05.
    % Stars stay on the Holm-corrected p (the reportable one).
    printSRTable(StdPOD, metricShort, pvals_Inf, pvals_Inf_Holm, n_Inf_vsBase, 2, ...
        sprintf('vs baseline, %-10s (cells: uncorrected / Holm-Bonferroni, k=%d)', primaryName, k_holm));
    if overlayMode
        % The second group is Surround, not Sham.
        printSRTable(StdPOD, metricShort, pvals_Ovl_vsBase, pvals_Ovl_Holm, n_Ovl_vsBase, 2, ...
            sprintf('vs baseline, %-10s (cells: uncorrected / Holm-Bonferroni, k=%d)', overlayLabel, k_holm));
    else
        printSRTable(StdPOD, metricShort, pvals_Sha, pvals_Sha_Holm, n_Sha_vsBase, 2, ...
            sprintf('vs baseline, Sham       (cells: uncorrected / Holm-Bonferroni, k=%d)', k_holm));
    end

    % Recovery: each later timepoint vs POD3. Significant rows mean the
    % metric has moved away from the early post-infarction value at that
    % POD (recovery if the direction reverses the initial deficit, further
    % decline if it doesn't).
    printSRTable(StdPOD, metricShort, pvals_Inf_vsP3, pvals_Inf_vsP3_Holm, n_Inf_vsP3, 3, ...
        sprintf('vs POD3, %s — recovery  (cells: uncorrected / Holm-Bonferroni, k=%d)', primaryName, k_holm_P3));
    if overlayMode
        printSRTable(StdPOD, metricShort, pvals_Ovl_vsP3, pvals_Ovl_vsP3_Holm, n_Ovl_vsP3, 3, ...
            sprintf('vs POD3, %s — recovery  (cells: uncorrected / Holm-Bonferroni, k=%d)', overlayLabel, k_holm_P3));
    else
        printSRTable(StdPOD, metricShort, pvals_Sha_vsP3, pvals_Sha_vsP3_Holm, n_Sha_vsP3, 3, ...
            sprintf('vs POD3, Sham — recovery        (cells: uncorrected / Holm-Bonferroni, k=%d)', k_holm_P3));
    end

    % Diagnostic note on the signed-rank's discrete p-value floor + Holm.
    % Holm's smallest-position adjustment multiplies by k (Bonferroni at
    % position 1); subsequent positions use k-1, k-2, ... with a running
    % max, so smaller p's downstream don't help once the leader saturates.
    fprintf('\n  Power note: signed-rank min two-tailed p = 2/2^n_paired\n');
    fprintf('    Holm smallest-position floor = k * min_p (Bonferroni); needs < %.4f to clear .05\n', 0.05/k_holm);
    fprintf('    n=5: min p=.0625  Holm pos1 ~.500   n=8: min p=.0078  Holm pos1 ~.0625\n');
    fprintf('    n=6: min p=.0313  Holm pos1 ~.250   n=9: min p=.0039  Holm pos1 ~.0313\n');
    fprintf('    n=7: min p=.0156  Holm pos1 ~.125   n=10:min p=.0020  Holm pos1 ~.0156\n');
    fprintf('  (significance stars on Holm p: *=p<.05  **=p<.01  ***=p<.001)\n');

    % Model-based post hoc from the RM ANOVA's own LME, for comparison with
    % the rank-sum row above. Not what the figure's asterisks use.
    fprintf(['\n  LME post hoc (group difference per POD, Sidak-adjusted) — ' ...
             'parametric counterpart of the rank-sum row:\n']);
    lmeTbls = lmeContrastsByMetric;
    if overlayMode, lmeTbls = lmeContrastsRSByMetric; end
    for m = 1:nMetrics
        Tc = lmeTbls{m};
        if isempty(Tc), continue; end
        ud = Tc.Properties.UserData;
        gA = primaryName;  gB = 'Sham';
        if isstruct(ud) && isfield(ud,'gRef'), gA = ud.gRef;  gB = ud.gAlt; end
        fprintf('  %s  (%s - %s):\n', metricShort{m}, gA, gB);
        fprintf('  %-8s %-22s %-10s %-10s\n', 'POD', 'estimate [95% CI]', 'p_raw', 'p_Sidak');
        for i = 1:height(Tc)
            if Tc.POD(i) == StdPOD(1)
                tag = '(baseline check)';
            else
                tag = pval2stars(Tc.p_sidak(i));
            end
            fprintf('  %-8g %7.3f [%6.3f,%6.3f] %-10.4f %-8.4f %s\n', ...
                Tc.POD(i), Tc.Estimate(i), Tc.CI_lo(i), Tc.CI_hi(i), ...
                Tc.p_raw(i), Tc.p_sidak(i), tag);
        end
    end
    fprintf('\n');
end

% ── Stash all stats for the "Export (paper)" button ──────────────────────
statsS = struct( ...
    'filterStr',   filterStr, ...
    'metricLabel', metricLabel, ...
    'StdPOD',      StdPOD, ...
    'metricShort', {{'Fall time','Fall count','Regular hold','Severity (zFT+zFC)'}}, ...
    'metricNames', {metricNames}, ...
    'primaryName', primaryName, ...
    'nInf', nInf, 'nSham', nSham, ...
    'pvals_rs',    pvals,    'pvals_rs_Holm', pvals_rs_Holm, ...
    'n_rs_Inf', n_rs_Inf, 'n_rs_Sha', n_rs_Sha, ...
    'pvals_Inf',   pvals_Inf,      'pvals_Inf_Holm', pvals_Inf_Holm, 'n_Inf_vsBase', n_Inf_vsBase, ...
    'pvals_Sha',   pvals_Sha,      'pvals_Sha_Holm', pvals_Sha_Holm, 'n_Sha_vsBase', n_Sha_vsBase, ...
    'pvals_Inf_vsP3', pvals_Inf_vsP3, 'pvals_Inf_vsP3_Holm', pvals_Inf_vsP3_Holm, 'n_Inf_vsP3', n_Inf_vsP3, ...
    'pvals_Sha_vsP3', pvals_Sha_vsP3, 'pvals_Sha_vsP3_Holm', pvals_Sha_vsP3_Holm, 'n_Sha_vsP3', n_Sha_vsP3, ...
    'k_holm', k_holm, 'k_holm_P3', k_holm_P3, ...
    'anovaByMetric', {anovaByMetric}, ...
    'lmeContrastsByMetric', {lmeContrastsByMetric});
% Overlay-mode stats: add the Surround families so the export CSV covers them.
if overlayMode
    statsS.overlayMode  = true;
    statsS.overlayLabel = overlayLabel;
    statsS.nOvl         = nOvl;
    statsS.pvals_ovl_rs = pvals_ovl_rs;  statsS.n_ovl_rs = n_ovl_rs;  statsS.n_sha_ovl = n_sha_ovl;
    statsS.pvals_RS_rs  = pvals_RS_rs;   statsS.n_reg_RS = n_reg_RS;  statsS.n_ovl_RS  = n_ovl_RS;
    statsS.pvals_ovl_rs_Holm = pvals_ovl_rs_Holm;
    statsS.pvals_RS_rs_Holm  = pvals_RS_rs_Holm;
    statsS.lmeContrastsRSByMetric = lmeContrastsRSByMetric;
    statsS.pvals_Ovl_vsBase = pvals_Ovl_vsBase;  statsS.pvals_Ovl_Holm = pvals_Ovl_Holm;  statsS.n_Ovl_vsBase = n_Ovl_vsBase;
    statsS.pvals_Ovl_vsP3 = pvals_Ovl_vsP3;  statsS.pvals_Ovl_vsP3_Holm = pvals_Ovl_vsP3_Holm;  statsS.n_Ovl_vsP3 = n_Ovl_vsP3;
    statsS.anovaRSByMetric = anovaRSByMetric;
else
    statsS.overlayMode = false;
end
setappdata(figPop, 'popStats', statsS);

% ── Plot ─────────────────────────────────────────────────────────────────
cInf  = [0.85, 0.15, 0.15];
cSha  = [0.20, 0.20, 0.20];
cOvl  = [0.00, 0.35, 0.85];   % overlay (Surround) group — blue, matches the map
cRS   = [0.50, 0.10, 0.60];   % Region-vs-Surround rank-sum stars (purple)
cRec  = [0.00, 0.55, 0.20];   % recovery marks: day vs POD3 (green)
% One glyph per significance row, in row order (row 1 = the row drawn at
% yLims(1)). Colour alone cannot carry the distinction: the rows run red,
% green, black and gray, and red-green is the pair most colour-blind readers
% cannot separate. Verified to render in MATLAB text and in the vector PDF —
% the TeX \dagger command does NOT (it prints literally), so these are
% literal UTF-8 characters. Repetition still encodes the level (†† = p<0.01).
ROW_GLYPH = {'*', '†', '‡', '+'};
% Spare glyphs for rows the Stats-table window can add on demand ("Apply marks
% to plot"), i.e. families this figure does not mark by default.
SPARE_GLYPH = {'§', '#', '¶', '@'};
SPARE_COLOR = {[0.85 0.45 0.00], [0.00 0.50 0.55], [0.55 0.30 0.10], [0.35 0.35 0.35]};
aLine = 0.25;
% Geometry of the mark rows per metric, filled in as the panels are drawn and
% stashed so the Stats window can place new rows on the same grid.
markYBase = NaN(1, nMetrics);
markYStep = NaN(1, nMetrics);
avgAxTags = {'axAvgFT', 'axAvgFC', 'axAvgRH', 'axAvgSV'};

clf(figPop);

% ── Store state for Back/Next animal browse ───────────────────────────────
infIdx_arr  = find(infMask);
ovlIdx_arr  = find(ovlMask);
shamIdx_arr = find(shamMask);
allOrder    = [infIdx_arr(:)', ovlIdx_arr(:)', shamIdx_arr(:)'];
setappdata(figPop, 'popBehData',  BehData);
setappdata(figPop, 'popStdPOD',   StdPOD);
setappdata(figPop, 'popInfMask',  infMask);
setappdata(figPop, 'popOvlMask',  ovlMask);
setappdata(figPop, 'popAllOrder', allOrder);
% Pooled mean/std used to z-score Fall time & Fall count into the Severity
% panel, so highlightAnimalInPop can recompute a single animal's severity
% trace with the same standardization the panel data used.
setappdata(figPop, 'popZParams', [muFT, sdFT, muCC, sdCC]);
prevIdx = getappdata(figPop, 'popAnimalIdx');
if isempty(prevIdx) || prevIdx < 1 || prevIdx > numel(allOrder)
    setappdata(figPop, 'popAnimalIdx', 1);
end

ylabels = {'Fall time (min/10min)',   'Fall time (min/10min)', ...
           'Fall count (/10min)',      'Fall count (/10min)', ...
           'Regular hold (min/10min)', 'Regular hold (min/10min)', ...
           'Severity (zFT+zFC)',       'Severity (zFT+zFC)'};
if overlayMode
    nStr = sprintf('Region n=%d, %s n=%d, Sham n=%d', nInf, overlayLabel, nOvl, nSham);
else
    nStr = sprintf('Inf n=%d, Sham n=%d', nInf, nSham);
end
titles  = {sprintf('Forelimb fall time — %s (individual)', metricLabel), ...
           sprintf('Forelimb fall time — %s (mean+/-SEM)  %s', metricLabel, nStr), ...
           sprintf('Fall count — %s (individual)', metricLabel), ...
           sprintf('Fall count — %s (mean+/-SEM)', metricLabel), ...
           'Regular hold time (individual)', 'Regular hold time (mean+/-SEM)', ...
           'Severity zFT+zFC (individual)', 'Severity zFT+zFC (mean+/-SEM)'};

for p = 1:8
    ax = subplot(4, 2, p, 'Parent', figPop);
    hold(ax, 'on');
    isAvg = mod(p,2) == 0;
    indTags = {'axIndFT', '', 'axIndFC', '', 'axIndRH', '', 'axIndSV', ''};
    if ~isAvg, set(ax, 'Tag', indTags{p}); end
    switch p
        case {1,2}, Inf_data = FallTime_Inf; Sha_data = FallTime_Sha; Ovl_data = FallTime_Ovl; mIdx = 1;
        case {3,4}, Inf_data = Cross_Inf;    Sha_data = Cross_Sha;    Ovl_data = Cross_Ovl;    mIdx = 2;
        case {5,6}, Inf_data = RegHold_Inf;  Sha_data = RegHold_Sha;  Ovl_data = RegHold_Ovl;  mIdx = 3;
        case {7,8}, Inf_data = Sever_Inf;    Sha_data = Sever_Sha;    Ovl_data = Sever_Ovl;    mIdx = 4;
    end
    % Mean panels are tagged so the Stats-table window can find the panel a
    % given metric's marks belong to.
    if isAvg, set(ax, 'Tag', avgAxTags{mIdx}); end
    if ~isAvg
        for k = 1:size(Inf_data,1)
            vm = ~isnan(Inf_data(k,:));
            plot(ax, StdPOD(vm), Inf_data(k,vm), 'Color', [cInf, aLine], ...
                'LineWidth', 1.5, 'Marker', 'o', 'MarkerSize', 3)
        end
        for k = 1:size(Ovl_data,1)
            vm = ~isnan(Ovl_data(k,:));
            plot(ax, StdPOD(vm), Ovl_data(k,vm), 'Color', [cOvl, aLine], ...
                'LineWidth', 1.5, 'Marker', 'o', 'MarkerSize', 3)
        end
        for k = 1:size(Sha_data,1)
            vm = ~isnan(Sha_data(k,:));
            plot(ax, StdPOD(vm), Sha_data(k,vm), 'Color', [cSha, aLine], ...
                'LineWidth', 1.5, 'Marker', 'o', 'MarkerSize', 3)
        end
    else
        % Error bars are drawn as shaded +/-SEM bands (area), not caps.
        % Each mean line's handle is kept, in drawing order: the legend is
        % built from exactly these, so nothing else on the panel can wander
        % into it. Slots left empty stay placeholders and are dropped below.
        hLeg = gobjects(1, 3);
        if ~isempty(Inf_data)
            mI = mean(Inf_data,1,'omitnan');
            sI = std(Inf_data,0,1,'omitnan') ./ sqrt(sum(~isnan(Inf_data),1));
            hLeg(1) = plotMeanBand(ax, StdPOD, mI, sI, cInf, primaryName);
        end
        if overlayMode && ~isempty(Ovl_data)
            mO = mean(Ovl_data,1,'omitnan');
            sO = std(Ovl_data,0,1,'omitnan') ./ sqrt(sum(~isnan(Ovl_data),1));
            hLeg(2) = plotMeanBand(ax, StdPOD, mO, sO, cOvl, overlayLabel);
        end
        if ~isempty(Sha_data)
            mS = mean(Sha_data,1,'omitnan');
            sS = std(Sha_data,0,1,'omitnan') ./ sqrt(sum(~isnan(Sha_data),1));
            % In overlay mode Sham is drawn purely as a visual reference for
            % the normal range — the comparison of interest is Region vs
            % Surround, so nothing is tested against Sham. Say so in the
            % legend rather than leaving a curve that looks like a tested arm.
            shaName = 'Sham';
            if overlayMode, shaName = 'Sham (reference, not tested)'; end
            hLeg(3) = plotMeanBand(ax, StdPOD, mS, sS, cSha, shaName);
        end
        % The legend names the traces and nothing else. The significance marks
        % drawn below used to add a key row apiece here, which made the box
        % large enough to sit on the data on a four-by-two page; what each mark
        % row means is spelled out on the figure title's second line instead,
        % and that line is rebuilt whenever the Stats window applies a
        % different set of rows, so it cannot go stale.
        %
        % Rows carry DIFFERENT GLYPHS, not just different colours: the palette
        % runs red / green / black / gray, and red-green is precisely the pair
        % that a colour-blind reader cannot separate. The glyph is the primary
        % cue and the colour is the redundant one. Repetition still encodes the
        % level, so ††† is p<0.001 on the vs-baseline row.
        %
        % Built from the mean-line handles rather than from the axes: a legend
        % left to collect the axes' children picks up the xline at day 0 as a
        % stray "data1" entry, and would re-adopt the key markers if any older
        % figure still carried them. AutoUpdate off for the same reason.
        hLeg = hLeg(isgraphics(hLeg));
        if ~isempty(hLeg)
            lgd = legend(ax, hLeg, 'Location', 'best');
            set(lgd, 'FontSize', 7, 'AutoUpdate', 'off');
        end

        yLims  = ylim(ax);
        yRange = yLims(2) - yLims(1);
        isInv  = strcmp(get(ax,'YDir'), 'reverse');
        step   = yRange * 0.07 * (1 - 2*isInv);
        yRow1  = yLims(1) + step*0;
        yRow2  = yLims(1) + step*1;
        yRow3  = yLims(1) + step*2;
        yRow4  = yLims(1) + step*3;
        % Same grid the Stats window will place re-applied rows on.
        markYBase(mIdx) = yLims(1);
        markYStep(mIdx) = step;
        if overlayMode
            % Only the Region-vs-Surround rank-sum is marked (*, purple);
            % nothing is tested against Sham here. The vs-Sham p-values are
            % still computed and exported to the stats CSV, they just don't
            % put marks on this figure. Glyphs keep their meaning from the
            % Infarction-vs-Sham figure — '*' is the between-group test of the
            % day, '+' is the vs-POD3 recovery test — so the two read alike.
            for t = 2:length(StdPOD)
                drawSigMark(ax, StdPOD(t), yRow1, pvals_RS_rs_Holm(t,mIdx), ROW_GLYPH{1}, cRS);
            end
        else
            % * Inf vs Sham that day, † Inf vs pre-surgery, ‡ Sham vs
            % pre-surgery.
            for t = 2:length(StdPOD)
                drawSigMark(ax, StdPOD(t), yRow1, pvals_rs_Holm(t,mIdx),  ROW_GLYPH{1}, [0 0 0]);
                drawSigMark(ax, StdPOD(t), yRow2, pvals_Inf_Holm(t,mIdx), ROW_GLYPH{2}, cInf);
                drawSigMark(ax, StdPOD(t), yRow3, pvals_Sha_Holm(t,mIdx), ROW_GLYPH{3}, cSha);
            end
        end
        % Recovery row (+, green): every session AFTER POD3 tested against
        % POD3 itself, paired within animal (Wilcoxon signed-rank, Holm-
        % corrected over the post-POD3 timepoints). A mark means the metric
        % has moved significantly away from the early post-infarction value —
        % i.e. the impairment has recovered (or worsened; read the direction
        % off the trace). Starts at t=3 because StdPOD(2) is POD3, the
        % reference. It is the last row in either mode, which is row 2 in
        % overlay mode (only Region vs Surround precedes it) and row 4 in the
        % Infarction-vs-Sham figure.
        yRec = yRow4;
        if overlayMode, yRec = yRow2; end
        for t = 3:length(StdPOD)
            drawSigMark(ax, StdPOD(t), yRec, pvals_Inf_vsP3_Holm(t,mIdx), ROW_GLYPH{4}, cRec);
        end
    end

    xline(ax, 0, '--k', 'LineWidth', 1)
    xlabel(ax, 'Days post-infarction')
    ylabel(ax, ylabels{p})
    title(ax, titles{p})
    set(ax, 'TickDir','out','Box','off')
    % Reverse the y-axis for deficit-direction metrics (Fall time, Fall
    % count, Severity — higher = worse) so a post-infarction worsening dips
    % downward, matching Regular hold's decrease. Regular hold (mIdx 3) is
    % the only "higher = better" metric, so it keeps the normal direction.
    if mIdx ~= 3, set(ax,'YDir','reverse'); end
end

% Title line 1 identifies the figure; line 2 lists what the marks mean, and is
% regenerated whenever the Stats window re-applies a different set of rows, so
% it is built from the same row spec the marks are drawn from.
if overlayMode
    titleLine1 = sprintf(['Region vs %s — Lever Pull Task  [%s]   ' ...
        '(Sham drawn for reference, not tested)  —  %s'], ...
        overlayLabel, metricLabel, filterStr);
    markSpec = struct( ...
        'family', {sprintf('%s vs %s (per timepoint)', primaryName, overlayLabel), ...
                   sprintf('%s: paired vs POD3 (recovery)', primaryName)}, ...
        'label',  {sprintf('%s vs %s, same day', primaryName, overlayLabel), ...
                   sprintf('%s vs POD3 (recovery)', primaryName)}, ...
        'glyph',  {ROW_GLYPH{1}, ROW_GLYPH{4}}, ...
        'color',  {cRS, cRec});
else
    titleLine1 = sprintf('Infarction (%s) vs Sham — Lever Pull Task  [%s]', ...
        filterStr, metricLabel);
    markSpec = struct( ...
        'family', {sprintf('%s vs Sham (per timepoint)', primaryName), ...
                   sprintf('%s: paired vs baseline', primaryName), ...
                   'Sham: paired vs baseline', ...
                   sprintf('%s: paired vs POD3 (recovery)', primaryName)}, ...
        'label',  {'Inf vs Sham that day (rank-sum)', 'Inf vs pre-surgery', ...
                   'Sham vs pre-surgery', 'Inf vs POD3 (recovery)'}, ...
        'glyph',  {ROW_GLYPH{1}, ROW_GLYPH{2}, ROW_GLYPH{3}, ROW_GLYPH{4}}, ...
        'color',  {[0 0 0], cInf, cSha, cRec});
end
setappdata(figPop, 'popTitleLine1',  titleLine1);
setappdata(figPop, 'popMarkSpec',    markSpec);   % currently applied rows
setappdata(figPop, 'popMarkDefault', markSpec);   % for "Restore default marks"
setappdata(figPop, 'popMarkGeom', struct('yBase', markYBase, 'yStep', markYStep, ...
                                         'axTags', {avgAxTags}));
setappdata(figPop, 'popSpareGlyph', SPARE_GLYPH);
setappdata(figPop, 'popSpareColor', SPARE_COLOR);
setPopMarkTitle(figPop, markSpec, k_holm);

% ── Back / Next buttons for individual animal browse ──────────────────────
uicontrol(figPop, 'Style', 'pushbutton', 'String', 'Back', ...
    'Units', 'normalized', 'Position', [0.02 0.005 0.06 0.028], ...
    'FontSize', 9, 'Tag', 'btnPopBack', ...
    'Callback', @(~,~) stepPopAnimal(figPop, -1));
uicontrol(figPop, 'Style', 'pushbutton', 'String', 'Next', ...
    'Units', 'normalized', 'Position', [0.09 0.005 0.06 0.028], ...
    'FontSize', 9, 'Tag', 'btnPopNext', ...
    'Callback', @(~,~) stepPopAnimal(figPop, +1));
uicontrol(figPop, 'Style', 'text', 'String', '', ...
    'Units', 'normalized', 'Position', [0.16  0.005 0.18 0.028], ...
    'FontSize', 9, 'Tag', 'txtPopID', ...
    'HorizontalAlignment', 'left', 'BackgroundColor', get(figPop, 'Color'));

% ── Stats table browser: every number behind the figure, in one window ─────
uicontrol(figPop, 'Style', 'pushbutton', 'String', 'Stats table', ...
    'Units', 'normalized', 'Position', [0.50 0.005 0.15 0.028], ...
    'FontSize', 9, 'Tag', 'btnPopStatsTable', ...
    'TooltipString', ['Browse every statistic behind this figure in a ' ...
        'sortable table, and append the filtered view to a PDF as a ' ...
        'supplementary page'], ...
    'Callback', @(~,~) openPopStatsTable(figPop));

% ── Paper export: vector PDF (Arial) + stats CSV (test name per plot) ──────
uicontrol(figPop, 'Style', 'pushbutton', 'String', 'Export (paper)', ...
    'Units', 'normalized', 'Position', [0.69 0.005 0.155 0.028], ...
    'FontSize', 9, 'Tag', 'btnPopExport', ...
    'TooltipString', ['Save this figure as a vector PDF (Arial) plus a CSV ' ...
        'of the statistical values and test names for each panel'], ...
    'Callback', @(~,~) exportPopFigure(figPop));

highlightAnimalInPop(figPop);
end

function exportPopFigure(figPop)
% "Export (paper)" button on a population time-course figure (used by the
% centroid time courses and the region time course). Saves two files:
%   1. a VECTOR PDF of the figure with every font set to Arial, and
%   2. a CSV of the statistical values + the test name for each panel:
%      Wilcoxon rank-sum (Infarction vs Sham) per timepoint; Wilcoxon
%      signed-rank (paired) vs baseline and vs POD3, both Holm-Bonferroni
%      corrected; and the two-way RM ANOVA (Group×Time, LME) per metric.
% The CSV is written next to the PDF with the same base name + "_stats.csv".
S = getappdata(figPop, 'popStats');
if isempty(S)
    warning('LeverPullTask:noPopStats', ...
        'Export: statistics not found on this figure — redraw it and retry.');
    return
end

% Default filename from the figure name (sanitized to a safe base).
defBase = get(figPop, 'Name');
if isempty(defBase), defBase = 'population_time_course'; end
defBase = regexprep(defBase, '[^\w\-]+', '_');
defBase = regexprep(defBase, '_+', '_');
defBase = regexprep(defBase, '^_|_$', '');

[fn, pth] = uiputfile({'*.pdf','Vector PDF (*.pdf)'}, ...
    'Export figure (PDF; stats CSV saved alongside)', [defBase '.pdf']);
if isequal(fn, 0), return; end
[~, base] = fileparts(fn);
pdfFile = fullfile(pth, [base '.pdf']);
csvFile = fullfile(pth, [base '_stats.csv']);

% ── 1. Vector PDF: Arial fonts, uicontrols hidden so the buttons/labels
%       don't appear in the exported figure. ────────────────────────────
uics = findall(figPop, 'Type', 'uicontrol');
oldVis = {};
if ~isempty(uics)
    oldVis = get(uics, 'Visible');
    set(uics, 'Visible', 'off');
end
set(findall(figPop, '-property', 'FontName'), 'FontName', 'Arial');
drawnow;
okPDF = true;
try
    exportgraphics(figPop, pdfFile, 'ContentType', 'vector', ...
        'BackgroundColor', 'white');
catch ME
    okPDF = false;
    warning('LeverPullTask:pdfExport', 'Export: PDF failed — %s', ME.message);
end
if ~isempty(uics)   % restore uicontrol visibility
    if iscell(oldVis)
        for i = 1:numel(uics), set(uics(i), 'Visible', oldVis{i}); end
    else
        set(uics, 'Visible', oldVis);
    end
end

% ── 2. Stats CSV (long format: one row per test × metric × timepoint) ─────
okCSV = true;
try
    % Stars in the glyphs the exported figure draws, so the CSV and the PDF
    % of the same export read the same way.
    T = buildPopStatsTable(S, getappdata(figPop, 'popMarkSpec'));
    writetable(T, csvFile);
catch ME
    okCSV = false;
    warning('LeverPullTask:csvExport', 'Export: CSV failed — %s', ME.message);
end

if okPDF, fprintf('Exported figure -> %s\n', pdfFile); end
if okCSV, fprintf('Exported stats  -> %s\n', csvFile); end
end

function T = buildPopStatsTable(S, spec)
% Assemble the long-format statistics table exported by exportPopFigure.
%
% With a mark spec (the figure's `popMarkDefault`, or whatever the Stats
% window last applied) the Stars column is stamped in each family's own plot
% glyph — "++" for a row the panels mark with '+' — so a star string in the
% table is the mark to look for on the plot. Without one the column keeps
% plain asterisks.
if nargin < 2, spec = []; end
StdPOD = S.StdPOD;
nT     = numel(StdPOD);
nM     = numel(S.metricShort);
% In overlay mode the figure compares Region with Surround and Sham is drawn
% as a reference only. Every Sham family is therefore omitted from the export,
% and the primary group is named "Region" rather than "Infarction" — a table
% that still said "Infarction vs Sham" would describe a comparison the figure
% deliberately does not make.
isOvl = isfield(S,'overlayMode') && S.overlayMode;
pName = 'Infarction';
if isfield(S,'primaryName') && ~isempty(S.primaryName), pName = S.primaryName; end
C = {};
for m = 1:nM
    mn = S.metricShort{m};

    % Wilcoxon rank-sum: primary vs Sham, per timepoint (drives the black
    % marks). Holm-corrected over the post-surgery timepoints, same family
    % definition as the paired tests below. Row 1 (pre-surgery baseline) is
    % outside that family — it is the baseline-equivalence check — so it is
    % reported uncorrected and carries no mark. Overlay mode reports the
    % Region-vs-Surround rank-sum in the overlay section instead.
    corrRS = sprintf('Holm-Bonferroni (k=%d)', S.k_holm);
    if ~isOvl
    for t = 1:nT
        r = newStatRow();
        r.Dataset = S.filterStr;  r.Metric = mn;
        r.TestFamily = sprintf('%s vs Sham (per timepoint)', pName);
        r.TestName   = 'Wilcoxon rank-sum (Mann-Whitney U)';
        r.Comparison = sprintf('POD %g: %s vs Sham', StdPOD(t), pName);
        r.POD = StdPOD(t);
        r.N_Inf = S.n_rs_Inf(t, m);  r.N_Sha = S.n_rs_Sha(t, m);
        r.p_uncorrected = S.pvals_rs(t, m);
        if t == 1
            r.Correction = 'none (baseline-equivalence check)';
            r.Stars = '';
        else
            r.p_corrected = S.pvals_rs_Holm(t, m);
            r.Correction  = corrRS;
            r.Stars       = pStars(S.pvals_rs_Holm(t, m));
        end
        C{end+1} = r; %#ok<AGROW>
    end
    end

    % Wilcoxon signed-rank (paired) vs baseline — primary group, then Sham
    % (skipped in overlay mode, where Surround's own vs-baseline family is
    % emitted in the overlay section below).
    corrBase = sprintf('Holm-Bonferroni (k=%d)', S.k_holm);
    nGrpBase = 2;  if isOvl, nGrpBase = 1; end
    for gi = 1:nGrpBase
        if gi == 1
            pu = S.pvals_Inf;  pc = S.pvals_Inf_Holm;  nn = S.n_Inf_vsBase;  g = pName;
        else
            pu = S.pvals_Sha;  pc = S.pvals_Sha_Holm;  nn = S.n_Sha_vsBase;  g = 'Sham';
        end
        for t = 2:nT
            r = newStatRow();
            r.Dataset = S.filterStr;  r.Metric = mn;
            r.TestFamily = sprintf('%s: paired vs baseline', g);
            r.TestName   = 'Wilcoxon signed-rank (paired)';
            r.Comparison = sprintf('%s: POD %g vs baseline (POD %g)', g, StdPOD(t), StdPOD(1));
            r.POD = StdPOD(t);  r.RefPOD = StdPOD(1);  r.N = nn(t, m);
            r.p_uncorrected = pu(t, m);  r.p_corrected = pc(t, m);
            r.Correction = corrBase;     r.Stars = pStars(pc(t, m));
            C{end+1} = r; %#ok<AGROW>
        end
    end

    % Wilcoxon signed-rank (paired) vs POD3 — recovery test.
    corrP3 = sprintf('Holm-Bonferroni (k=%d)', S.k_holm_P3);
    nGrpP3 = 2;  if isOvl, nGrpP3 = 1; end
    for gi = 1:nGrpP3
        if gi == 1
            pu = S.pvals_Inf_vsP3;  pc = S.pvals_Inf_vsP3_Holm;  nn = S.n_Inf_vsP3;  g = pName;
        else
            pu = S.pvals_Sha_vsP3;  pc = S.pvals_Sha_vsP3_Holm;  nn = S.n_Sha_vsP3;  g = 'Sham';
        end
        for t = 3:nT
            r = newStatRow();
            r.Dataset = S.filterStr;  r.Metric = mn;
            r.TestFamily = sprintf('%s: paired vs POD3 (recovery)', g);
            r.TestName   = 'Wilcoxon signed-rank (paired)';
            r.Comparison = sprintf('%s: POD %g vs POD %g', g, StdPOD(t), StdPOD(2));
            r.POD = StdPOD(t);  r.RefPOD = StdPOD(2);  r.N = nn(t, m);
            r.p_uncorrected = pu(t, m);  r.p_corrected = pc(t, m);
            r.Correction = corrP3;       r.Stars = pStars(pc(t, m));
            C{end+1} = r; %#ok<AGROW>
        end
    end

    % Two-way RM ANOVA (Group × Time) via LME — one row per model term. In
    % overlay mode this model is not fitted at all (its Group factor would be
    % Region vs Sham); the Region-vs-Surround ANOVA is emitted below.
    aT = [];
    if ~isOvl, aT = S.anovaByMetric{m}; end
    if ~isempty(aT)
        for r_ = 1:height(aT)
            r = newStatRow();
            r.Dataset = S.filterStr;  r.Metric = mn;
            r.TestFamily = 'RM ANOVA (Group x Time)';
            r.TestName   = 'Two-way RM ANOVA via LME: Value ~ Group*Time + (1|Animal)';
            r.Comparison = aT.Term{r_};
            r.Fstat = aT.FStat(r_);  r.DF1 = aT.DF1(r_);  r.DF2 = aT.DF2(r_);
            r.p_uncorrected = aT.pValue(r_);
            r.Correction = 'none';   r.Stars = pStars(aT.pValue(r_));
            C{end+1} = r; %#ok<AGROW>
        end
    end

    % Post hoc contrasts on that same LME: the group difference at each
    % timepoint, with a 95% CI and a Sidak-adjusted p. Reported here only —
    % the figure's asterisks come from the Wilcoxon families above. Present
    % so the parametric analysis a reviewer may ask for is already in hand.
    % In overlay mode these come from the Region-vs-Surround model.
    lmeFld = 'lmeContrastsByMetric';
    if isOvl, lmeFld = 'lmeContrastsRSByMetric'; end
    if isfield(S, lmeFld) && numel(S.(lmeFld)) >= m && ~isempty(S.(lmeFld){m})
        Tc = S.(lmeFld){m};
        ud = Tc.Properties.UserData;
        gA = pName;  gB = 'Sham';
        if isstruct(ud) && isfield(ud,'gRef'), gA = ud.gRef;  gB = ud.gAlt; end
        for i = 1:height(Tc)
            r = newStatRow();
            r.Dataset = S.filterStr;  r.Metric = mn;
            r.TestFamily = sprintf('%s vs %s (LME post hoc, per timepoint)', gA, gB);
            r.TestName   = ['LME contrast: Value ~ Group*Time + (1|Animal), ' ...
                            'Satterthwaite df'];
            r.Comparison = sprintf('POD %g: %s - %s', Tc.POD(i), gA, gB);
            r.POD   = Tc.POD(i);
            r.Fstat = Tc.Fstat(i);  r.DF1 = Tc.DF1(i);  r.DF2 = Tc.DF2(i);
            r.Estimate = Tc.Estimate(i);  r.SE = Tc.SE(i);
            r.CI95_lo  = Tc.CI_lo(i);     r.CI95_hi = Tc.CI_hi(i);
            r.p_uncorrected = Tc.p_raw(i);
            if Tc.POD(i) == StdPOD(1)
                r.Correction = 'none (baseline-equivalence check)';  r.Stars = '';
            else
                r.p_corrected = Tc.p_sidak(i);
                r.Correction  = sprintf('Sidak (k=%d)', Tc.k_family(i));
                r.Stars       = pStars(Tc.p_sidak(i));
            end
            C{end+1} = r; %#ok<AGROW>
        end
    end

    % ── Overlay families, when the figure was drawn in overlay mode. The
    %    comparison is Region vs Surround; Sham is a drawn reference only, so
    %    the Surround-vs-Sham family that used to be emitted here is gone
    %    along with every other Sham comparison. ───────────────────────────
    if isOvl
        ovl = S.overlayLabel;

        % Rank-sum: Region vs Surround, per timepoint.
        for t = 1:nT
            r = newStatRow();
            r.Dataset = S.filterStr;  r.Metric = mn;
            r.TestFamily = sprintf('%s vs %s (per timepoint)', pName, ovl);
            r.TestName   = 'Wilcoxon rank-sum (Mann-Whitney U)';
            r.Comparison = sprintf('POD %g: %s vs %s', StdPOD(t), pName, ovl);
            r.POD = StdPOD(t);
            r.N_Inf = S.n_reg_RS(t, m);  r.N_Sha = S.n_ovl_RS(t, m);
            r.p_uncorrected = S.pvals_RS_rs(t, m);
            if t == 1
                r.Correction = 'none (baseline-equivalence check)';  r.Stars = '';
            else
                r.p_corrected = S.pvals_RS_rs_Holm(t, m);
                r.Correction  = corrRS;
                r.Stars       = pStars(S.pvals_RS_rs_Holm(t, m));
            end
            C{end+1} = r; %#ok<AGROW>
        end

        % Signed-rank: Surround vs baseline (Holm).
        corrBase = sprintf('Holm-Bonferroni (k=%d)', S.k_holm);
        for t = 2:nT
            r = newStatRow();
            r.Dataset = S.filterStr;  r.Metric = mn;
            r.TestFamily = sprintf('%s: paired vs baseline', ovl);
            r.TestName   = 'Wilcoxon signed-rank (paired)';
            r.Comparison = sprintf('%s: POD %g vs baseline (POD %g)', ovl, StdPOD(t), StdPOD(1));
            r.POD = StdPOD(t);  r.RefPOD = StdPOD(1);  r.N = S.n_Ovl_vsBase(t, m);
            r.p_uncorrected = S.pvals_Ovl_vsBase(t, m);  r.p_corrected = S.pvals_Ovl_Holm(t, m);
            r.Correction = corrBase;  r.Stars = pStars(S.pvals_Ovl_Holm(t, m));
            C{end+1} = r; %#ok<AGROW>
        end

        % Signed-rank: Surround vs POD3 (recovery, Holm).
        corrP3 = sprintf('Holm-Bonferroni (k=%d)', S.k_holm_P3);
        for t = 3:nT
            r = newStatRow();
            r.Dataset = S.filterStr;  r.Metric = mn;
            r.TestFamily = sprintf('%s: paired vs POD3 (recovery)', ovl);
            r.TestName   = 'Wilcoxon signed-rank (paired)';
            r.Comparison = sprintf('%s: POD %g vs POD %g', ovl, StdPOD(t), StdPOD(2));
            r.POD = StdPOD(t);  r.RefPOD = StdPOD(2);  r.N = S.n_Ovl_vsP3(t, m);
            r.p_uncorrected = S.pvals_Ovl_vsP3(t, m);  r.p_corrected = S.pvals_Ovl_vsP3_Holm(t, m);
            r.Correction = corrP3;  r.Stars = pStars(S.pvals_Ovl_vsP3_Holm(t, m));
            C{end+1} = r; %#ok<AGROW>
        end

        % RM ANOVA: Region vs Surround (Group × Time).
        aR = S.anovaRSByMetric{m};
        if ~isempty(aR)
            for r_ = 1:height(aR)
                r = newStatRow();
                r.Dataset = S.filterStr;  r.Metric = mn;
                r.TestFamily = sprintf('RM ANOVA %s vs %s (Group x Time)', pName, ovl);
                r.TestName   = 'Two-way RM ANOVA via LME: Value ~ Group*Time + (1|Animal)';
                r.Comparison = aR.Term{r_};
                r.Fstat = aR.FStat(r_);  r.DF1 = aR.DF1(r_);  r.DF2 = aR.DF2(r_);
                r.p_uncorrected = aR.pValue(r_);
                r.Correction = 'none';   r.Stars = pStars(aR.pValue(r_));
                C{end+1} = r; %#ok<AGROW>
            end
        end
    end
end
T = struct2table([C{:}]);
T = stampStarsWithGlyphs(T, spec);
end

function T = stampStarsWithGlyphs(T, spec)
% Rewrite the Stars column so each row's stars are written in the glyph the
% plot marks that test family with: a "**" row of a family drawn with '#'
% becomes "##". Only the character changes — the count still is the
% significance level (1/2/3 = p<.05/.01/.001) and a blank cell stays blank,
% so stamping an already-stamped table again is a no-op and a re-stamp with a
% different spec simply overwrites the glyph.
%
% Families the spec does not mention keep the plain asterisks pStars
% produced: nothing on the plot corresponds to them, so there is no glyph to
% borrow.
if isempty(T) || height(T) == 0 || isempty(spec), return; end
if ~ismember('Stars', T.Properties.VariableNames), return; end
for k = 1:numel(spec)
    g = spec(k).glyph;
    if isempty(g), continue; end
    for i = find(strcmp(T.TestFamily, spec(k).family)).'
        n = numel(statRowStars(T, i));
        if n > 0, T.Stars{i} = repmat(g(1), 1, n); end
    end
end
end

function r = newStatRow()
% One blank row of the exported stats table (field order = column order).
r = struct('Dataset','', 'Metric','', 'TestFamily','', 'TestName','', ...
    'Comparison','', 'POD',NaN, 'RefPOD',NaN, 'N',NaN, 'N_Inf',NaN, 'N_Sha',NaN, ...
    'Fstat',NaN, 'DF1',NaN, 'DF2',NaN, ...
    'Estimate',NaN, 'SE',NaN, 'CI95_lo',NaN, 'CI95_hi',NaN, ...
    'p_uncorrected',NaN, 'p_corrected',NaN, ...
    'Correction','', 'Stars','');
end

function s = pStars(p)
% Significance stars for a p-value (blank if NaN or >= 0.05).
s = '';
if isnan(p), return; end
if     p < 0.001, s = '***';
elseif p < 0.01,  s = '**';
elseif p < 0.05,  s = '*';
end
end

function printSRTable(StdPOD, metricShort, pUnc, pAdj, nMat, tStart, header)
% Print one signed-rank table to the command window. Cells show
% "uncorrected / corrected" with significance stars on the corrected
% value (currently Holm-Bonferroni). The leading n column = paired
% animals contributing to that POD (max across the three metrics;
% usually identical since metrics share the same NaN pattern, but
% max() avoids hiding a partial column).
% Header is printed verbatim; tStart skips POD index 1 (baseline) for
% vs-baseline tables (tStart=2) and additionally POD3 for recovery
% tables (tStart=3).
nM = numel(metricShort);
fprintf('\n  Wilcoxon signed-rank (paired by animal) %s\n', header);
fprintf('  %-8s %-3s  ', 'POD', 'n');
fprintf('%-19s ', metricShort{:});
fprintf('\n');
for t = tStart:length(StdPOD)
    nRow = max(nMat(t, :));
    fprintf('  POD %4d  %2d   ', StdPOD(t), nRow);
    for m = 1:nM
        pU = pUnc(t, m);
        if isnan(pU)
            fprintf('%-19s ', '   -');
        else
            pC = pAdj(t, m);
            sc = pval2stars(pC);
            fprintf('%6.4f / %6.4f%-3s ', pU, pC, sc);
        end
    end
    fprintf('\n');
end
end

function figTbl = openPopStatsTable(figPop)
% "Stats table" button on a population time-course figure. Opens a sortable
% window holding exactly the rows the "Export (paper)" CSV writes — every
% test behind the figure, roughly 200 of them — with Metric / Test-family
% filters and a "significant only" switch, plus a button that appends the
% CURRENTLY FILTERED view to a PDF as vector text (a supplementary table).
% Reading the numbers should not require opening the CSV in Excel.
%
% Returns the window handle (empty if it could not be opened), so the caller —
% or a test — can drive it without hunting through the root's children.
figTbl = gobjects(0);
S = getappdata(figPop, 'popStats');
if isempty(S)
    warning('LeverPullTask:noPopStats', ...
        'Stats table: statistics not found on this figure — redraw it and retry.');
    return
end
T = buildPopStatsTable(S);
if isempty(T) || height(T) == 0
    warning('LeverPullTask:emptyStats', 'Stats table: no statistics to show.');
    return
end
% Keep the unstamped table aside: every re-stamp starts from it, so a family
% that drops out of the applied spec goes back to plain asterisks instead of
% keeping a glyph the plot no longer draws.
Tbase = T;
T = stampStarsWithGlyphs(T, getappdata(figPop, 'popMarkSpec'));

srcName = get(figPop, 'Name');
if isempty(srcName), srcName = 'population time course'; end
figTbl = uifigure('Name', sprintf('Stats — %s', srcName), ...
                  'Position', [120 120 1280 720]);
setappdata(figTbl, 'statsBase',     Tbase);
setappdata(figTbl, 'statsAll',      T);
setappdata(figTbl, 'statsFiltered', T);
setappdata(figTbl, 'srcName',       srcName);
setappdata(figTbl, 'srcFig',        figPop);

gl = uigridlayout(figTbl, [3 1]);
gl.RowHeight   = {34, 30, '1x'};
gl.ColumnWidth = {'1x'};

top = uigridlayout(gl, [1 8]);
top.Layout.Row  = 1;
top.ColumnWidth = {52, 150, 52, 290, 130, 150, 150, '1x'};
top.Padding     = [0 0 0 0];

uilabel(top, 'Text', 'Metric:');
uidropdown(top, 'Items', [{'All'}; unique(T.Metric)], 'Tag', 'ddMetric', ...
    'ValueChangedFcn', @(~,~) popStatsApplyFilter(figTbl));
uilabel(top, 'Text', 'Family:');
uidropdown(top, 'Items', [{'All'}; unique(T.TestFamily)], 'Tag', 'ddFamily', ...
    'ValueChangedFcn', @(~,~) popStatsApplyFilter(figTbl));
uicheckbox(top, 'Text', 'Significant only', 'Tag', 'cbSig', ...
    'ValueChangedFcn', @(~,~) popStatsApplyFilter(figTbl));
uibutton(top, 'Text', 'Add table to PDF', 'Tag', 'btnTblPDF', ...
    'ButtonPushedFcn', @(~,~) exportPopStatsTablePDF(figTbl));
uibutton(top, 'Text', 'Save filtered CSV', 'Tag', 'btnTblCSV', ...
    'ButtonPushedFcn', @(~,~) exportPopStatsTableCSV(figTbl));
uilabel(top, 'Text', '', 'Tag', 'lblCount');

% Second row: push the selected tests back onto the time-course figure. The
% table holds families the figure never marks by default (Sham vs POD3, the
% LME contrasts), so this is the way to see any of them on the plot.
mid = uigridlayout(gl, [1 4]);
mid.Layout.Row  = 2;
mid.ColumnWidth = {170, 170, 200, '1x'};
mid.Padding     = [0 0 0 0];
uibutton(mid, 'Text', 'Apply marks to plot', 'Tag', 'btnApplyMarks', ...
    'Tooltip', ['Redraw the time-course marks from the selected rows ' ...
                '(or from everything currently filtered, if nothing is selected). ' ...
                'One mark row per test family, in the order they appear. ' ...
                'Each mark repeats its glyph once per star in the Stars ' ...
                'column, and a blank Stars cell draws nothing.'], ...
    'ButtonPushedFcn', @(~,~) applyStatsMarksToPlot(figTbl));
uibutton(mid, 'Text', 'Restore default marks', 'Tag', 'btnResetMarks', ...
    'ButtonPushedFcn', @(~,~) restoreDefaultMarks(figTbl));
uilabel(mid, 'Text', '', 'Tag', 'lblApplied');

tb = uitable(gl, 'Data', T, 'Tag', 'tblStats');
tb.Layout.Row = 3;
% Row selection drives "Apply marks to plot"; not every release supports it,
% and the button falls back to the filtered view when it isn't available.
try
    tb.SelectionType = 'row';
    tb.Multiselect   = 'on';
catch
end
% Sortable columns are a uifigure-only feature and post-date some releases;
% the table is still readable without them.
try
    tb.ColumnSortable = true;
catch
end

popStatsApplyFilter(figTbl);
end

function popStatsApplyFilter(figTbl)
% Apply the Metric / Family / significance filters to the stats table.
% "Significant" uses the corrected p where one exists and the uncorrected p
% otherwise, which is the same value the Stars column was built from.
T = getappdata(figTbl, 'statsAll');
if isempty(T), return; end
hM = findobj(figTbl, 'Tag', 'ddMetric');
hF = findobj(figTbl, 'Tag', 'ddFamily');
hS = findobj(figTbl, 'Tag', 'cbSig');
hL = findobj(figTbl, 'Tag', 'lblCount');
hT = findobj(figTbl, 'Tag', 'tblStats');

keep = true(height(T), 1);
if ~isempty(hM) && ~strcmp(hM(1).Value, 'All')
    keep = keep & strcmp(T.Metric, hM(1).Value);
end
if ~isempty(hF) && ~strcmp(hF(1).Value, 'All')
    keep = keep & strcmp(T.TestFamily, hF(1).Value);
end
if ~isempty(hS) && hS(1).Value
    pEff = T.p_corrected;
    useUnc = isnan(pEff);
    pEff(useUnc) = T.p_uncorrected(useUnc);
    keep = keep & (pEff < 0.05);
end

Tf = T(keep, :);
setappdata(figTbl, 'statsFiltered', Tf);
if ~isempty(hT), hT(1).Data = Tf; end
if ~isempty(hL)
    hL(1).Text = sprintf('%d of %d rows', height(Tf), height(T));
end
end

function applyStatsMarksToPlot(figTbl)
% "Apply marks to plot": redraw the time-course figure's significance marks
% from the rows selected in this table (or, if nothing is selected, from
% everything the filter currently shows).
%
% One mark row per distinct test family, in the order the families first
% appear in the selection. A family the figure already marks keeps its usual
% glyph and colour so the plot stays familiar; anything else — a Sham-vs-POD3
% family, an LME contrast family — is given a spare glyph.
figPop = getappdata(figTbl, 'srcFig');
if isempty(figPop) || ~isgraphics(figPop, 'figure')
    uialert(figTbl, ['The time-course figure this table came from has been ' ...
        'closed. Reopen it and press "Stats table" again.'], 'Apply marks');
    return
end

rows = getappdata(figTbl, 'statsFiltered');
hT   = findobj(figTbl, 'Tag', 'tblStats');
usedSelection = false;
if ~isempty(hT)
    try
        sel = hT(1).Selection;
        if ~isempty(sel)
            rows = rows(unique(sel(:,1)), :);
            usedSelection = true;
        end
    catch
    end
end
if isempty(rows) || height(rows) == 0
    uialert(figTbl, 'Nothing to apply — no rows are selected or filtered.', 'Apply marks');
    return
end

% Build one spec entry per family, reusing the figure's own glyph/colour for
% families it already knows.
defSpec = getappdata(figPop, 'popMarkDefault');
spares  = getappdata(figPop, 'popSpareGlyph');
sparesC = getappdata(figPop, 'popSpareColor');
fams    = unique(rows.TestFamily, 'stable');
spec    = struct('family', {}, 'label', {}, 'glyph', {}, 'color', {});
nSpare  = 0;
for i = 1:numel(fams)
    hit = [];
    if ~isempty(defSpec), hit = find(strcmp({defSpec.family}, fams{i}), 1); end
    if ~isempty(hit)
        spec(end+1) = defSpec(hit); %#ok<AGROW>
    else
        nSpare = nSpare + 1;
        gi = mod(nSpare-1, numel(spares)) + 1;
        spec(end+1) = struct('family', fams{i}, ...
                             'label',  shortenFamilyLabel(fams{i}), ...
                             'glyph',  spares{gi}, ...
                             'color',  sparesC{gi}); %#ok<AGROW>
    end
end

counts = applyPopMarkSpec(figPop, spec, rows);
% Put the glyphs the plot just drew into the table's own Stars column, so a
% row reading "##" is the "##" now visible on the panels. The stars keep the
% level they had, so the rows applied above are unaffected.
restampStatsWindow(figTbl, spec);
hL = findobj(figTbl, 'Tag', 'lblApplied');
if ~isempty(hL)
    src = 'filtered rows';
    if usedSelection, src = 'selected rows'; end
    msg = sprintf('%d marks from %d %s, %d rows', counts(1), numel(spec), ...
                  'families', height(rows));
    if counts(2) > 0, msg = sprintf('%s; %d n.s.', msg, counts(2)); end
    if counts(3) > 0, msg = sprintf('%s; %d without a POD skipped', msg, counts(3)); end
    hL(1).Text = sprintf('%s  (%s)', msg, src);
end
figure(figPop);
end

function restoreDefaultMarks(figTbl)
% Put the figure's own default mark rows back, drawn from the full table.
figPop = getappdata(figTbl, 'srcFig');
if isempty(figPop) || ~isgraphics(figPop, 'figure')
    uialert(figTbl, 'The time-course figure has been closed.', 'Restore marks');
    return
end
defSpec = getappdata(figPop, 'popMarkDefault');
counts  = applyPopMarkSpec(figPop, defSpec, getappdata(figTbl, 'statsAll'));
restampStatsWindow(figTbl, defSpec);
hL = findobj(figTbl, 'Tag', 'lblApplied');
if ~isempty(hL)
    hL(1).Text = sprintf('default marks restored (%d marks)', counts(1));
end
figure(figPop);
end

function restampStatsWindow(figTbl, spec)
% Re-stamp the whole window's Stars column in the glyphs of `spec` and redraw
% the visible rows through the current filter. Always stamps the pristine
% table, never the displayed one, so glyphs never accumulate across applies.
Tbase = getappdata(figTbl, 'statsBase');
if isempty(Tbase), return; end
setappdata(figTbl, 'statsAll', stampStarsWithGlyphs(Tbase, spec));
% Refreshing Data drops the row selection, and the filter is unchanged here,
% so put the same rows back — pressing Apply twice should not need reselecting.
hT  = findobj(figTbl, 'Tag', 'tblStats');
sel = [];
if ~isempty(hT)
    try
        sel = hT(1).Selection;
    catch
    end
end
popStatsApplyFilter(figTbl);
if ~isempty(sel) && ~isempty(hT)
    try
        hT(1).Selection = sel;
    catch
    end
end
end

function s = shortenFamilyLabel(fam)
% Legend label for a family the figure has no default label for. Drops the
% "(per timepoint)" noise that every family carries.
s = regexprep(fam, '\s*\(LME post hoc,\s*per timepoint\)', ' (LME)');
s = regexprep(s, '\s*\(per timepoint\)', '');
end

function exportPopStatsTableCSV(figTbl)
% Save just the filtered rows as CSV (the "Export (paper)" button already
% writes the full table; this is for the subset currently on screen).
Tf = getappdata(figTbl, 'statsFiltered');
if isempty(Tf) || height(Tf) == 0
    warning('LeverPullTask:emptyFilter', 'Nothing to save — the filter matches no rows.');
    return
end
[fn, pth] = uiputfile({'*.csv','CSV (*.csv)'}, 'Save filtered stats', ...
    [statsBaseName(getappdata(figTbl,'srcName')) '_stats_filtered.csv']);
if isequal(fn, 0), return; end
writetable(Tf, fullfile(pth, fn));
fprintf('Exported filtered stats -> %s\n', fullfile(pth, fn));
end

function exportPopStatsTablePDF(figTbl)
% Render the filtered rows as a paginated table of VECTOR TEXT and write it
% to PDF. Pointing this at the PDF the "Export (paper)" button produced and
% choosing Append gives one file: the figure, then its statistics table.
Tf = getappdata(figTbl, 'statsFiltered');
if isempty(Tf) || height(Tf) == 0
    warning('LeverPullTask:emptyFilter', 'Nothing to export — the filter matches no rows.');
    return
end
srcName = getappdata(figTbl, 'srcName');
[fn, pth] = uiputfile({'*.pdf','PDF (*.pdf)'}, 'Export stats table (PDF)', ...
    [statsBaseName(srcName) '_stats_table.pdf']);
if isequal(fn, 0), return; end
outFile = fullfile(pth, fn);

appendMode = false;
if exist(outFile, 'file') == 2
    ch = uiconfirm(figTbl, ...
        {'That PDF already exists.', '', ...
         'Append the table as extra pages (keeps the figure pages), or replace the file?'}, ...
        'Export stats table', ...
        'Options', {'Append','Replace','Cancel'}, ...
        'DefaultOption', 1, 'CancelOption', 3);
    switch ch
        case 'Append',  appendMode = true;
        case 'Replace', delete(outFile);
        otherwise,      return
    end
end

nPages = renderStatsTablePDF(Tf, outFile, appendMode, srcName);
if nPages > 0
    fprintf('Exported stats table -> %s  (%d page(s), %d rows)\n', ...
        outFile, nPages, height(Tf));
end
end

function base = statsBaseName(nm)
% Filename-safe base derived from the source figure's name.
if isempty(nm), nm = 'population_time_course'; end
base = regexprep(nm, '[^\w\-]+', '_');
base = regexprep(base, '_+', '_');
base = regexprep(base, '^_|_$', '');
if isempty(base), base = 'population_time_course'; end
end

function nPages = renderStatsTablePDF(Tf, outFile, appendMode, srcName)
% Paginate Tf into landscape pages of vector text and export to PDF.
%
% Only the columns worth reading on paper are printed — the CSV keeps the
% rest. Numbers are pre-formatted here (p < 0.001 rather than 3.2e-07, an
% estimate folded together with its CI) because the point of this page is to
% be read, not re-analysed.
ROWS_PER_PAGE = 34;
if isempty(outFile)
    error('LeverPullTask:noOutFile', 'renderStatsTablePDF: no output file given.');
end

% A "Test" column is needed even though the window filters by family: with
% the filter on All, a rank-sum row and an LME row for the same timepoint
% differ only by "vs" against "-" in the Comparison text.
hdr  = {'Metric','Comparison','Test','n','Estimate [95% CI]','Statistic', ...
        'p','p corrected','Correction','Sig'};
xCol = [0.000 0.100 0.330 0.445 0.495 0.650 0.770 0.832 0.898 0.975];
body = statsRowsToText(Tf);

nRows  = size(body, 1);
nPages = ceil(nRows / ROWS_PER_PAGE);
fig = figure('Visible','off', 'Units','inches', 'Position',[0 0 11 8.5], ...
             'Color','w', 'PaperPositionMode','auto');
cleanup = onCleanup(@() close(fig));
for pg = 1:nPages
    clf(fig);
    ax = axes('Parent', fig, 'Position', [0.03 0.04 0.94 0.90]);
    axis(ax, [0 1 0 1]);  axis(ax, 'off');  hold(ax, 'on');

    text(ax, 0, 1.045, sprintf('Statistics — %s', srcName), ...
        'FontName','Arial', 'FontSize',10, 'FontWeight','bold', ...
        'VerticalAlignment','bottom');
    text(ax, 1, 1.045, sprintf('page %d of %d', pg, nPages), ...
        'FontName','Arial', 'FontSize',8, 'Color',[0.35 0.35 0.35], ...
        'HorizontalAlignment','right', 'VerticalAlignment','bottom');

    yTop = 0.985;
    for c = 1:numel(hdr)
        text(ax, xCol(c), yTop, hdr{c}, 'FontName','Arial', 'FontSize',7.5, ...
            'FontWeight','bold', 'VerticalAlignment','middle');
    end
    plot(ax, [0 1], (yTop - 0.011)*[1 1], 'k-', 'LineWidth', 0.75);

    dy = 0.0275;
    i0 = (pg-1)*ROWS_PER_PAGE + 1;
    i1 = min(nRows, pg*ROWS_PER_PAGE);
    for i = i0:i1
        y = yTop - 0.028 - (i - i0)*dy;
        for c = 1:numel(hdr)
            text(ax, xCol(c), y, body{i,c}, 'FontName','Arial', 'FontSize',7, ...
                'VerticalAlignment','middle', 'Interpreter','none');
        end
    end

    appendThis = appendMode || pg > 1;   %#ok<NASGU>  (read inside evalc)
    try
        % Appending to a PDF makes exportgraphics print a "Fixing references"
        % line per object; with ~34 rows a page that buries everything else
        % in the console. evalc swallows the chatter and still rethrows any
        % real error into the catch below.
        evalc(['exportgraphics(fig, outFile, ''ContentType'', ''vector'', ' ...
               '''BackgroundColor'', ''white'', ''Append'', appendThis);']);
    catch ME
        % 'Append' predates some releases; without it a multi-page table
        % can't be written, so say what happened rather than half-writing.
        warning('LeverPullTask:tablePDF', ...
            'Stats table PDF failed on page %d — %s', pg, ME.message);
        nPages = 0;
        return
    end
end
end

function body = statsRowsToText(Tf)
% Format the printed columns of the stats table as display strings.
n = height(Tf);
body = repmat({''}, n, 10);
for i = 1:n
    body{i,1} = Tf.Metric{i};
    body{i,2} = Tf.Comparison{i};
    body{i,3} = shortTestName(Tf.TestName{i});

    % n: paired tests carry one N, two-group tests carry N_Inf / N_Sha.
    if ~isnan(Tf.N(i))
        body{i,4} = sprintf('%g', Tf.N(i));
    elseif ~isnan(Tf.N_Inf(i)) || ~isnan(Tf.N_Sha(i))
        body{i,4} = sprintf('%g/%g', Tf.N_Inf(i), Tf.N_Sha(i));
    end

    if ~isnan(Tf.Estimate(i))
        body{i,5} = sprintf('%.3g [%.3g, %.3g]', ...
            Tf.Estimate(i), Tf.CI95_lo(i), Tf.CI95_hi(i));
    end
    if ~isnan(Tf.Fstat(i))
        body{i,6} = sprintf('F(%g,%.1f)=%.3f', Tf.DF1(i), Tf.DF2(i), Tf.Fstat(i));
    end

    body{i,7}  = fmtPval(Tf.p_uncorrected(i));
    body{i,8}  = fmtPval(Tf.p_corrected(i));
    body{i,9}  = shortenCorrection(Tf.Correction{i});
    body{i,10} = Tf.Stars{i};
end
end

function s = shortTestName(t)
% Column-width-sized name for the test; the CSV keeps the full description.
if     contains(t, 'rank-sum'),     s = 'rank-sum';
elseif contains(t, 'signed-rank'),  s = 'signed-rank';
elseif contains(t, 'LME contrast'), s = 'LME contrast';
elseif contains(t, 'RM ANOVA'),     s = 'RM ANOVA';
else,  s = t(1:min(12, numel(t)));
end
end

function s = fmtPval(p)
% p-values as a reader wants them: a threshold rather than an exponent.
if isnan(p),      s = '';        return; end
if p < 0.001,     s = '<0.001';  return; end
s = sprintf('%.4f', p);
end

function s = shortenCorrection(c)
% Keep the correction column narrow: the CSV holds the full wording.
s = c;
if isempty(s), return; end
s = strrep(s, 'Holm-Bonferroni', 'Holm');
s = strrep(s, 'none (baseline-equivalence check)', 'none (base)');
end

function T = lmeGroupContrasts(lme, Tbl, StdPOD)
% Per-timepoint group-difference contrasts on a fitted Group*Time LME.
%
% With dummy coding, the fixed effects are (Intercept), Group_<alt>, Time_<t>
% and Group_<alt>:Time_<t>, where the FIRST category of each factor is the
% reference. The group difference at timepoint t is therefore
%     Group_<alt>            at the reference timepoint, and
%     Group_<alt> + Group_<alt>:Time_<t>   at every other timepoint,
% which is the contrast vector c built below. The estimate is negated so it
% reads reference-minus-alternative (Infarction - Sham), matching how the
% figure is described, and p is unaffected by that sign flip.
%
% p-values come from coefTest with Satterthwaite denominator df (the residual
% df default overstates df when the design is unbalanced). Adjustment is
% single-step Sidak across the post-surgery timepoints — the same family the
% Wilcoxon rows use. StdPOD(1) (pre-surgery) is excluded from the family: it
% is a baseline-equivalence check, not a hypothesis test.
%
% Returns an empty table if the model can't support the contrast (one group,
% unexpected coefficient names, rank deficiency).
T = table();
try
    cn = lme.CoefficientNames;
    gl = categories(Tbl.Group);
    if numel(gl) < 2, return; end
    gRef = gl{1};  gAlt = gl{2};
    iG = find(strcmp(cn, ['Group_' gAlt]), 1);
    if isempty(iG), return; end

    b  = lme.Coefficients.Estimate;
    V  = lme.CoefficientCovariance;
    tl = categories(Tbl.Time);
    nC = numel(cn);

    POD = []; Estimate = []; SE = []; CI_lo = []; CI_hi = [];
    Fstat = []; DF1 = []; DF2 = []; p_raw = [];
    for t = 1:numel(StdPOD)
        tname = char(string(StdPOD(t)));
        if ~ismember(tname, tl), continue; end     % timepoint absent entirely
        c = zeros(1, nC);
        c(iG) = 1;
        % No interaction term exists at the reference timepoint — there c is
        % just the group indicator, which is already correct.
        iGT = find(strcmp(cn, ['Group_' gAlt ':Time_' tname]), 1);
        if isempty(iGT)
            iGT = find(strcmp(cn, ['Time_' tname ':Group_' gAlt]), 1);
        end
        if ~isempty(iGT), c(iGT) = 1; end

        est = -(c * b);                 % gRef - gAlt
        se  = sqrt(c * V * c.');
        [pv, F, df1, df2] = coefTest(lme, c, 0, 'DFMethod', 'satterthwaite');
        if ~isfinite(se) || ~isfinite(df2) || df2 <= 0, continue; end
        tc = tinv(0.975, df2);

        POD(end+1,1)      = StdPOD(t);      %#ok<AGROW>
        Estimate(end+1,1) = est;            %#ok<AGROW>
        SE(end+1,1)       = se;             %#ok<AGROW>
        CI_lo(end+1,1)    = est - tc*se;    %#ok<AGROW>
        CI_hi(end+1,1)    = est + tc*se;    %#ok<AGROW>
        Fstat(end+1,1)    = F;              %#ok<AGROW>
        DF1(end+1,1)      = df1;            %#ok<AGROW>
        DF2(end+1,1)      = df2;            %#ok<AGROW>
        p_raw(end+1,1)    = pv;             %#ok<AGROW>
    end
    if isempty(POD), return; end

    p_sidak = NaN(size(p_raw));
    inFam   = (POD ~= StdPOD(1)) & ~isnan(p_raw);
    p_sidak(inFam) = sidakAdjust(p_raw(inFam));
    k_family = repmat(sum(inFam), numel(POD), 1);

    T = table(POD, Estimate, SE, CI_lo, CI_hi, Fstat, DF1, DF2, ...
              p_raw, p_sidak, k_family);
    T.Properties.UserData = struct('gRef', gRef, 'gAlt', gAlt);
catch ME
    warning('LeverPullTask:lmeContrast', ...
        'LME post-hoc contrasts skipped — %s', ME.message);
    T = table();
end
end

function p_adj = sidakAdjust(p)
% Single-step Sidak adjustment: p_adj = 1 - (1-p)^k over the k non-NaN
% p-values, capped at 1, NaNs passed through. This is what Prism reports as
% "Sidak's multiple comparisons test". Note it is single-step, so unlike the
% step-down Holm used for the plotted rows it applies the same threshold to
% every comparison in the family.
p_adj = NaN(size(p));
valid = ~isnan(p);
k     = sum(valid);
if k == 0, return; end
p_adj(valid) = min(1, 1 - (1 - p(valid)).^k);
end

function p_adj = holmAdjust(p)
% Holm-Bonferroni step-down adjustment of a vector of p-values, with
% NaN pass-through. Equivalent to R's p.adjust(p, method='holm').
% Algorithm: sort the non-NaN p's ascending; multiply the i-th smallest
% by k-i+1; apply running max so the sequence is monotone non-decreasing;
% cap at 1; place back into the original positions. NaN entries stay NaN.
p_adj = NaN(size(p));
valid = ~isnan(p);
pv    = p(valid);
k     = numel(pv);
if k == 0, return; end
[ps, ord] = sort(pv(:));
mult      = (k:-1:1)';
adj       = cummax(min(1, mult .* ps));
% Inverse permutation: invOrd(j) = rank of original index j among sorted.
invOrd        = zeros(k, 1);
invOrd(ord)   = 1:k;
p_adj(valid)  = adj(invOrd);
end

function setPopMarkTitle(figPop, spec, kHolm)
% Rebuild the figure title so line 2 always describes the marks currently
% drawn. Called at draw time and again whenever the Stats window applies a
% different set of rows — a title left describing the default rows would be
% worse than no title at all.
line1 = getappdata(figPop, 'popTitleLine1');
if isempty(line1), line1 = get(figPop, 'Name'); end
if isempty(spec)
    line2 = 'marks: none applied';
else
    % Numbered, because the mark rows are stacked in this order and the panels
    % no longer carry a legend key saying which row is which. Row 1 sits
    % closest to the axis floor: at the top on the deficit-direction metrics
    % (y reversed) and at the bottom on Regular hold.
    parts = cell(1, numel(spec));
    for k = 1:numel(spec)
        parts{k} = sprintf('row %d %s %s', k, spec(k).glyph, spec(k).label);
    end
    line2 = sprintf(['marks (1/2/3 repeats = p<0.05 / 0.01 / 0.001, corrected within ' ...
                     'each family over the %d post-surgery timepoints; rows stack ' ...
                     'from the axis floor):   %s'], ...
                    kHolm, strjoin(parts, '   '));
end
stH = sgtitle(figPop, sprintf('%s\n%s', line1, line2));
set(stH, 'FontSize', 9);
end

function counts = applyPopMarkSpec(figPop, spec, rowsTbl)
% Redraw every mean panel's significance marks from `spec` (one entry per mark
% row: family, label, glyph, colour) using the p-values in `rowsTbl`, a subset
% of the stats table. This is what the Stats window's "Apply marks to plot"
% calls, and also what restores the defaults.
%
% Rows are placed on the grid recorded when the panels were drawn, so an
% applied row lands exactly where a default row would have.
%
% The mark level comes from the row's own Stars column, not from a second
% reading of its p-values: what the Stats window prints as "**" is drawn as a
% double glyph, and a row whose Stars cell is blank is never marked. That
% keeps the two in step for rows where the table deliberately withholds stars
% — the POD-1 baseline-equivalence checks, which are reported uncorrected and
% used to pick up a mark here from the p_uncorrected fallback.
counts = [0 0 0];   % [drawn, not-significant, no-POD]
geom = getappdata(figPop, 'popMarkGeom');
S    = getappdata(figPop, 'popStats');
if isempty(geom) || isempty(S), return; end
kHolm = 8;
if isfield(S,'k_holm'), kHolm = S.k_holm; end
hasStars = ismember('Stars', rowsTbl.Properties.VariableNames);

nDrawn = 0;  nSkipNoPOD = 0;  nNotSig = 0;
for mi = 1:numel(geom.axTags)
    ax = findobj(figPop, 'Type','axes', 'Tag', geom.axTags{mi});
    if isempty(ax), continue; end
    ax = ax(1);
    delete(findobj(ax, 'Tag','sigMark'));
    % Key markers are no longer drawn, but a figure produced before they were
    % dropped can still be carrying some; clear them so the legend it was
    % given at draw time is the one that stays.
    delete(findobj(ax, 'Tag','sigKey'));
    if isnan(geom.yBase(mi)), continue; end

    for k = 1:numel(spec)
        y = geom.yBase(mi) + geom.yStep(mi) * (k-1);
        sel = strcmp(rowsTbl.TestFamily, spec(k).family) & ...
              strcmp(rowsTbl.Metric,     S.metricShort{mi});
        idx = find(sel);
        for i = idx(:).'
            if isnan(rowsTbl.POD(i)), nSkipNoPOD = nSkipNoPOD + 1; continue; end
            if hasStars
                stars = statRowStars(rowsTbl, i);
            else
                % Older stashed table without the column: fall back to the
                % same p the Stars cell would have been built from.
                p = rowsTbl.p_corrected(i);
                if isnan(p), p = rowsTbl.p_uncorrected(i); end
                stars = pStars(p);
            end
            if isempty(stars), nNotSig = nNotSig + 1; continue; end
            drawSigMarkStars(ax, rowsTbl.POD(i), y, numel(stars), ...
                             spec(k).glyph, spec(k).color);
            nDrawn = nDrawn + 1;
        end
    end
    % The legend lists the traces only and they have not changed, so it is
    % left exactly as drawn. Which mark row is which is read off the title's
    % second line, rebuilt from this same spec below.
end

setappdata(figPop, 'popMarkSpec', spec);
setPopMarkTitle(figPop, spec, kHolm);
counts = [nDrawn nNotSig nSkipNoPOD];
drawnow limitrate;
end

function drawSigMark(ax, x, y, p, glyph, col)
% Draw one significance mark of a star row, or nothing if p is NaN or >= .05.
% The level goes through pStars — the same function that fills the stats
% table's Stars column — so the panel and the table can never disagree about
% how many glyphs a p-value earns.
drawSigMarkStars(ax, x, y, numel(pStars(p)), glyph, col);
end

function drawSigMarkStars(ax, x, y, nStar, glyph, col)
% Draw one mark of nStar glyphs (nothing when nStar < 1). The glyph identifies
% WHICH comparison the row is (see ROW_GLYPH), repeated 1-3 times for
% p<.05 / .01 / .001 — the same convention as asterisks, so a reader who
% ignores the glyph still reads the level correctly.
if nStar < 1, return; end
text(ax, x, y, repmat(glyph, 1, nStar), 'HorizontalAlignment','center', ...
    'FontSize', 11, 'Color', col, 'Tag', 'sigMark');
end

function s = statRowStars(rowsTbl, i)
% The Stars cell of one stats-table row, as a trimmed char row vector.
s = '';
v = rowsTbl.Stars(i);
if iscell(v), v = v{1}; end
if isstring(v), v = char(v); end
if ischar(v), s = strtrim(v); end
end

function s = pval2stars(p)
% String of significance stars for a p-value (named local copy of the
% anonymous handle defined inside drawPopulationFigure, so the new
% printSRTable helper can call it without capturing the closure).
if isnan(p),       s = '';    return; end
if p < 0.001,      s = '***'; return; end
if p < 0.01,       s = '**';  return; end
if p < 0.05,       s = '*';   return; end
s = '';
end

function [mu, sd] = poolMeanStd(A, B)
% Mean and std of all finite entries pooled across two matrices (e.g. the
% Infarction and Sham per-animal x per-POD matrices for one metric). Used
% to standardize a metric onto a common scale before forming the composite
% severity index. Returns sd = 0 when there is no spread (guarded downstream
% by zStd, which then yields zeros).
v  = [A(:); B(:)];
v  = v(~isnan(v));
if isempty(v)
    mu = 0; sd = 0;
else
    mu = mean(v);
    sd = std(v);
end
end

function z = zStd(x, mu, sd)
% Standardize x with the supplied mean/std, NaN pass-through. A non-finite
% or zero std (no spread) collapses the finite entries to 0 rather than
% NaN/Inf, matching the pooled-z convention used for the severity index.
z = nan(size(x));
if isfinite(sd) && sd > 0
    z = (x - mu) / sd;
else
    z(~isnan(x)) = 0;
end
end

function h = plotMeanBand(ax, x, m, s, col, dispName)
% Draw a mean trace with its error bar shown as a shaded +/-s band (area),
% not error-bar caps. Only timepoints with a finite mean are used; NaN gaps
% are bridged the same way the individual traces are. The band is a
% semi-transparent patch in the trace color (kept out of the legend); the
% returned handle is the mean line, which carries the legend entry. A
% single valid point degenerates to a thin vertical bar, still an "area".
h = gobjects(1);
x = x(:).'; m = m(:).'; s = s(:).';
vm = isfinite(m);
if ~any(vm), return; end
xv = x(vm); mv = m(vm); sv = s(vm);
sv(~isfinite(sv)) = 0;
patch(ax, [xv, fliplr(xv)], [mv + sv, fliplr(mv - sv)], col, ...
    'FaceAlpha', 0.2, 'EdgeColor', 'none', 'HandleVisibility', 'off');
h = plot(ax, xv, mv, 'Color', col, 'LineWidth', 2, ...
    'Marker', 'o', 'MarkerSize', 5, 'DisplayName', dispName);
end

function openLesionCentroidFig(fig7)
% Open (or refresh) the lesion-centroid scatter figure plus the companion
% "M1-centroid lesions: size vs post-infarction fall count" figure.
BehData      = getappdata(fig7, 'BehData');
CCF_root_beh = getappdata(fig7, 'CCF_root_beh');
figCent = getappdata(fig7, 'figCent');
if isempty(figCent) || ~isgraphics(figCent, 'figure')
    figCent = figure('Name', 'Lesion Centroids', 'Position', [1140 80 760 760]);
    setappdata(fig7, 'figCent', figCent);
else
    figure(figCent);
end
drawLesionCentroidFigure(BehData, CCF_root_beh, figCent);

% Stash what the "Select region" button needs to open a time-course figure
% (drawPopulationFigure over the region-selected animal subset) and the
% companion "Lesion map" button. Set after drawLesionCentroidFigure (which
% clf's the figure but leaves figure appdata intact).
setappdata(figCent, 'BehData',      BehData);
setappdata(figCent, 'StdPOD',       getappdata(fig7, 'StdPOD'));
setappdata(figCent, 'CCF_root_beh', CCF_root_beh);

% Companion figure: lesion size vs post-infarction fall count, split into
% M1 / M2 / S1 panels by the region the lesion centroid pixel falls in.
S = getappdata(figCent, 'centData');
figM1 = getappdata(fig7, 'figM1');
if isempty(figM1) || ~isgraphics(figM1, 'figure')
    figM1 = figure('Name', ...
        'M1/M2/S1-centroid lesions: size vs post-infarction fall count', ...
        'Position', [1100 80 1180 880]);   % tall enough for 3 cols x 2 rows
    setappdata(fig7, 'figM1', figM1);
else
    figure(figM1);
end
% Stash what the figRF callbacks need to spawn the "Time course" companion
% (a new drawPopulationFigure window filtered to the row-1 animal subset),
% plus CCF_root_beh so each time-course window's "Lesion map" button can
% reach the lesion-CCF files for the centroid-filtered subset.
setappdata(figM1, 'BehData',      BehData);
setappdata(figM1, 'StdPOD',       getappdata(fig7, 'StdPOD'));
setappdata(figM1, 'CCF_root_beh', CCF_root_beh);
drawRegionRelationFigure(figM1, S);
end

function drawLesionCentroidFigure(BehData, CCF_root_beh, figCent)
% Scatter each infarction animal's lesion centroid on the CCF top-view atlas.
%   marker area  ∝ total lesion volume (mm³)
%   marker color = total post-infarction fall count (CrossCount, POD > 0)
% Centroid = mean pixel of the union of all sub-lesion top-view polygons,
% in the shared CCF atlas pixel space (same frame as the lesion-map panel).
% Circle-size scale and opacity are adjustable via sliders so overlapping
% centroids stay readable.
clf(figCent);

slice_width_mm = 50 * 0.001;
MIN_LESION_VOL_MM3 = 0.02;   % below this a "lesion" is a histology marker, not tissue
allInf = find(strcmp({BehData.Group}, 'Infarction'));

Area_mapRGB = [];  mapH = 0;  mapW = 0;
cx = [];  cy = [];  vol = [];  ids = {};  metricMat3d = [];
polyPts = {};   % per-marker top-view polygon vertices (for the deficit heatmap)
volByRegion = zeros(0, 3);   % per-marker [volM1 volM2 volS1] in mm³ — used as
                             % x-axis when the M1/M2/S1 figure's "per-region"
                             % toggle is on. Same fractional split as the
                             % per-animal volM1/volM2/volS1 in BehData.
nAni = 0;   % infarction animals that contributed >= 1 lesion marker

% Behavioral symptoms selectable via the "Color by" dropdown. Each value is
% the post-infarction mean of the per-session field within the selected phase
% (Acute / Sub-acute / Chronic / All — see phaseNames below). Mean (not sum)
% so animals with different numbers of recorded sessions are comparable.
metricNames  = {'Fall time','Fall count','Regular hold','Release count'};
metricFields = {'FT_sess','CC_sess','RHT_sess','Release_sess'};
phaseNames   = {'All (POD>0)','Acute (3-7)','Sub-acute (10-24)','Chronic (28+)'};
phaseLo      = [    0.5,        3,            10,                  28 ];
phaseHi      = [    Inf,        7,            24,                  Inf];
% Days a phase's window may extend outward (both bounds) to absorb near-miss
% sessions recorded slightly early or late. A session counts toward a phase
% when it lands within < Tolerance days of the window, i.e.
% phaseLo - (Tolerance-1) <= POD <= phaseHi + (Tolerance-1). So POD2 or POD8
% join "Acute (3-7)", POD9 or POD25 join "Sub-acute (10-24)", and POD27 joins
% "Chronic (28+)"; a session 2 days out (e.g. POD26, two days from both 24 and
% 28) joins neither. "All (POD>0)" keeps its exact bound (grace 0). With
% grace 1 the widened windows still don't overlap (acute<=8, sub-acute 9..25,
% chronic>=27).
Tolerance    = 2;   % days; mirrors the script-level StdPOD match tolerance
phaseGrace   = [    0,          Tolerance-1,  Tolerance-1,         Tolerance-1 ];
nM = numel(metricFields);  nP = numel(phaseNames);

for i = allInf(:)'
    bd   = BehData(i);
    ccfF = findCCFFiles(CCF_root_beh, bd.ID);
    if isempty(ccfF), continue; end
    try
        Sc = load(fullfile(ccfF(1).folder, ccfF(1).name), 'lesion_ccf', 'Area_mapRGB');
    catch
        continue
    end
    if ~isfield(Sc, 'lesion_ccf') || isempty(Sc.lesion_ccf), continue; end
    if isempty(Area_mapRGB) && isfield(Sc, 'Area_mapRGB') && ~isempty(Sc.Area_mapRGB)
        Area_mapRGB = Sc.Area_mapRGB;
        [mapH, mapW, ~] = size(Area_mapRGB);
    end
    if mapH == 0, continue; end

    % Per-animal phase × metric matrix (nM x nP): post-infarction means of the
    % per-session field for each phase window. Shared by every lesion marker
    % of this animal (drives the color via the Color-by / Phase dropdowns).
    mvecPhase = nan(nM, nP);
    if isfield(bd, 'POD_sess') && ~isempty(bd.POD_sess)
        pod = bd.POD_sess(:);
        for mm = 1:nM
            f = metricFields{mm};
            % Release count falls back to fall count when not computed,
            % mirroring plotSingleAnimal.
            if strcmp(f, 'Release_sess') && (~isfield(bd, 'Release_sess') ...
                    || isempty(bd.Release_sess))
                f = 'CC_sess';
            end
            if ~isfield(bd, f) || isempty(bd.(f)), continue; end
            v = bd.(f)(:);
            if numel(v) ~= numel(pod), continue; end
            for ph = 1:nP
                pmask = pod >= (phaseLo(ph) - phaseGrace(ph)) & pod <= (phaseHi(ph) + phaseGrace(ph));
                if any(pmask & ~isnan(v))
                    mvecPhase(mm, ph) = mean(v(pmask), 'omitnan');
                end
            end
        end
    end

    % One marker per sub-lesion (lesion_ccf entry): centroid = mean pixel of
    % that lesion's own top-view polygon; size = that lesion's own volume.
    addedAny = false;
    for lsn = 1:length(Sc.lesion_ccf)
        pts = Sc.lesion_ccf(lsn).lesionArea_TopView;
        if isempty(pts), continue; end
        lmask = poly2mask(pts(:,1), pts(:,2), mapH, mapW);
        if ~any(lmask(:)), continue; end
        lVol = sum(Sc.lesion_ccf(lsn).lesion_area_size) ...
               * 0.010 * 0.010 * slice_width_mm;
        if lVol < MIN_LESION_VOL_MM3, continue; end   % skip histology markers
        % Per-region volume of THIS sub-lesion (mm³): distribute lVol by the
        % share of acronym entries tagged MOp / MOs / SSp* — same approach as
        % the per-animal volM1/volM2/volS1 split in BehData construction.
        vRegM1 = 0; vRegM2 = 0; vRegS1 = 0;
        try
            acr = Sc.lesion_ccf(lsn).lesion_areas.acronym;
            acr = cellfun(@stripLayerSuffix, acr, 'UniformOutput', false);
            nA  = numel(acr);
            if nA > 0
                vRegM1 = lVol * sum(strcmp(acr,'MOp'))                              / nA;
                vRegM2 = lVol * sum(strcmp(acr,'MOs'))                              / nA;
                vRegS1 = lVol * sum(cellfun(@(x) startsWith(x,'SSp'), acr))         / nA;
            end
        catch
            % Missing lesion_areas — leave per-region volumes at 0
        end
        [yy, xx] = find(lmask);
        cx(end+1)              = mean(xx);   %#ok<AGROW>
        cy(end+1)              = mean(yy);   %#ok<AGROW>
        vol(end+1)             = lVol;       %#ok<AGROW>
        metricMat3d(end+1,:,:) = reshape(mvecPhase, [1, nM, nP]);   %#ok<AGROW>
        ids{end+1}             = bd.ID;      %#ok<AGROW>
        polyPts{end+1}         = pts;        %#ok<AGROW>
        volByRegion(end+1, :)  = [vRegM1, vRegM2, vRegS1];          %#ok<AGROW>
        addedAny = true;
    end
    if addedAny, nAni = nAni + 1; end
end

if isempty(cx)
    ax = axes('Parent', figCent, 'Position', [0.07 0.08 0.80 0.85]);
    axis(ax, 'off');
    text(ax, 0.5, 0.5, 'No lesion-map data for any infarction animal', ...
        'Units','normalized', 'HorizontalAlignment','center', 'FontSize',11);
    return
end

% Composite severity index (extra "Color by" option): the sum of z-scored
% Fall time and Fall count. High when EITHER metric is elevated (OR
% semantics), scale-free, equally weighted — captures both "few but long
% falls" and "many falls" as severe. The z-reference is POOLED across all
% markers AND all phases (single mean/std per metric), so severity is
% absolute and comparable across phases: a recovered animal in Chronic gets
% a low severity, not one re-centred on the (also-recovered) chronic cohort.
iFT = find(strcmp(metricNames, 'Fall time'),  1);
iFC = find(strcmp(metricNames, 'Fall count'), 1);
if ~isempty(iFT) && ~isempty(iFC)
    ftSlab = metricMat3d(:, iFT, :);
    fcSlab = metricMat3d(:, iFC, :);
    [muFT, sdFT] = poolMeanStd(ftSlab(:), []);
    [muFC, sdFC] = poolMeanStd(fcSlab(:), []);
    metricMat3d(:, end+1, :) = zStd(ftSlab, muFT, sdFT) + zStd(fcSlab, muFC, sdFC);
    metricNames{end+1} = 'Severity (zFT+zFC)';
end

% Stash everything the redraw needs (avoids re-reading CCF files on slider drag)
S = struct('cx',cx, 'cy',cy, 'cyF',mapH + 1 - cy, 'vol',vol, 'ids',{ids}, ...
           'metricMat3d',metricMat3d, 'metricNames',{metricNames}, ...
           'phaseNames',{phaseNames}, 'nAni',nAni, 'polyPts',{polyPts}, ...
           'Area_mapRGB',Area_mapRGB, 'mapH',mapH, 'mapW',mapW, ...
           'volByRegion',volByRegion, ...
           'sScale', 1500 / max(vol));
setappdata(figCent, 'centData', S);

% Plot axes (leave room at the bottom for sliders and at the top for the
% Phase dropdown); redraw finds the axes by Tag.
axes('Parent', figCent, 'Position', [0.07 0.21 0.80 0.69], 'Tag', 'centAx');

% Phase dropdown (top row) — restricts the post-infarction symptom sums to
% the selected stroke phase. Default "All (POD>0)" preserves prior behavior.
uicontrol(figCent, 'Style','text', 'String','Phase:', ...
    'Units','normalized', 'Position',[0.07 0.955 0.06 0.035], ...
    'FontSize',9, 'HorizontalAlignment','left', ...
    'BackgroundColor',get(figCent,'Color'));
uicontrol(figCent, 'Style','popupmenu', 'String', phaseNames, 'Value', 1, ...
    'Units','normalized', 'Position',[0.13 0.955 0.22 0.04], ...
    'FontSize',9, 'Tag','popCentPhase', ...
    'Callback', @(~,~) redrawCentroidScatter(figCent));

% View toggle: lesion centroids (default) vs deficit-occurrence heatmap,
% drawn in the same axes using the current Phase / Color-by / size filters.
uicontrol(figCent, 'Style','togglebutton', 'String','Deficit map: On', ...
    'Value',1, 'Units','normalized', 'Position',[0.40 0.955 0.18 0.04], ...
    'FontSize',9, 'Tag','tglCentHeatmap', ...
    'Callback', @(~,~) redrawCentroidScatter(figCent));
% Dual-centroid toggle: include or exclude (default) lesions from animals
% with multiple lesions when computing the deficit map.
uicontrol(figCent, 'Style','togglebutton', 'String','Dual centroids: Off', ...
    'Value',0, 'Units','normalized', 'Position',[0.60 0.955 0.18 0.04], ...
    'FontSize',9, 'Tag','tglCentDual', ...
    'Callback', @(~,~) redrawCentroidScatter(figCent));
% Coverage filter for the deficit map: when On (default), show only pixels
% covered by >= 2 lesions (hide single-lesion pixels).
uicontrol(figCent, 'Style','togglebutton', 'String','Pixel ≥2: On', ...
    'Value',1, 'Units','normalized', 'Position',[0.79 0.955 0.18 0.04], ...
    'FontSize',9, 'Tag','tglCentMinCov', ...
    'Callback', @(~,~) redrawCentroidScatter(figCent));

bg = get(figCent, 'Color');
% Lesion-size slider range = actual volume range (guard degenerate case)
vLoLim = min(vol);  vHiLim = max(vol);
if vHiLim <= vLoLim, vHiLim = vLoLim + max(1e-3, abs(vLoLim)*1e-3); end

% ── Left column: 4 sliders (circle size / opacity / min size / max size) ──
uicontrol(figCent, 'Style','text', 'String','Circle size', ...
    'Units','normalized', 'Position',[0.07 0.165 0.11 0.03], ...
    'FontSize',9, 'HorizontalAlignment','left', 'BackgroundColor',bg);
hSz = uicontrol(figCent, 'Style','slider', 'Min',0.1, 'Max',5, 'Value',1, ...
    'SliderStep',[0.02 0.1], 'Units','normalized', ...
    'Position',[0.18 0.165 0.30 0.028], 'Tag','sldCentSize');
uicontrol(figCent, 'Style','text', 'String','1.0×', ...
    'Units','normalized', 'Position',[0.49 0.165 0.085 0.03], ...
    'FontSize',9, 'Tag','txtCentSize', 'BackgroundColor',bg);

uicontrol(figCent, 'Style','text', 'String','Opacity', ...
    'Units','normalized', 'Position',[0.07 0.125 0.11 0.03], ...
    'FontSize',9, 'HorizontalAlignment','left', 'BackgroundColor',bg);
hAl = uicontrol(figCent, 'Style','slider', 'Min',0.05, 'Max',1, 'Value',0.55, ...
    'SliderStep',[0.05 0.2], 'Units','normalized', ...
    'Position',[0.18 0.125 0.30 0.028], 'Tag','sldCentAlpha');
uicontrol(figCent, 'Style','text', 'String','0.55', ...
    'Units','normalized', 'Position',[0.49 0.125 0.085 0.03], ...
    'FontSize',9, 'Tag','txtCentAlpha', 'BackgroundColor',bg);

uicontrol(figCent, 'Style','text', 'String','Min size', ...
    'Units','normalized', 'Position',[0.07 0.085 0.11 0.03], ...
    'FontSize',9, 'HorizontalAlignment','left', 'BackgroundColor',bg);
minDef = max(vLoLim, min(vHiLim, 0.1));   % default Min size 0.1 mm³ (clamped)
hMn = uicontrol(figCent, 'Style','slider', 'Min',vLoLim, 'Max',vHiLim, ...
    'Value',minDef, 'Units','normalized', ...
    'Position',[0.18 0.085 0.30 0.028], 'Tag','sldCentMinVol');
uicontrol(figCent, 'Style','text', 'String',sprintf('%.2f mm³',minDef), ...
    'Units','normalized', 'Position',[0.49 0.085 0.085 0.03], ...
    'FontSize',9, 'Tag','txtCentMinVol', 'BackgroundColor',bg);

uicontrol(figCent, 'Style','text', 'String','Max size', ...
    'Units','normalized', 'Position',[0.07 0.045 0.11 0.03], ...
    'FontSize',9, 'HorizontalAlignment','left', 'BackgroundColor',bg);
maxDef = max(vLoLim, min(vHiLim, 2.0));   % default Max size 2.0 mm³ (clamped)
hMx = uicontrol(figCent, 'Style','slider', 'Min',vLoLim, 'Max',vHiLim, ...
    'Value',maxDef, 'Units','normalized', ...
    'Position',[0.18 0.045 0.30 0.028], 'Tag','sldCentMaxVol');
uicontrol(figCent, 'Style','text', 'String',sprintf('%.2f mm³',maxDef), ...
    'Units','normalized', 'Position',[0.49 0.045 0.085 0.03], ...
    'FontSize',9, 'Tag','txtCentMaxVol', 'BackgroundColor',bg);

% Visibility toggles: Allen brain map + animal IDs (default both ON)
uicontrol(figCent, 'Style','togglebutton', 'String','Brain map: On', ...
    'Value',1, 'Units','normalized', 'Position',[0.60 0.150 0.17 0.036], ...
    'FontSize',9, 'Tag','tglCentMap', ...
    'Callback', @(~,~) redrawCentroidScatter(figCent));
uicontrol(figCent, 'Style','togglebutton', 'String','Animal IDs: On', ...
    'Value',1, 'Units','normalized', 'Position',[0.60 0.105 0.17 0.036], ...
    'FontSize',9, 'Tag','tglCentIDs', ...
    'Callback', @(~,~) redrawCentroidScatter(figCent));

% Color-by dropdown: choose which post-infarction symptom drives the color
uicontrol(figCent, 'Style','text', 'String','Color by:', ...
    'Units','normalized', 'Position',[0.79 0.150 0.085 0.03], ...
    'FontSize',9, 'HorizontalAlignment','left', 'BackgroundColor',bg);
miDef = find(strcmp(metricNames, 'Fall count'), 1);
if isempty(miDef), miDef = 1; end
uicontrol(figCent, 'Style','popupmenu', 'String', metricNames, ...
    'Value', miDef, 'Units','normalized', ...
    'Position',[0.79 0.105 0.19 0.036], 'FontSize',9, ...
    'Tag','popCentMetric', ...
    'Callback', @(~,~) redrawCentroidScatter(figCent));

% ── Manual region selection: pick a circle of a fixed diameter (µm) and
% plot the impairment time-course for the lesions whose AREA overlaps it.
% Diameter edit box + "Select region" toggle (bottom-right). When the toggle
% is On the axes switch to a clean contour-only view (selection circle +
% selected lesion outlines over the brain map, no scatter/heatmap clutter)
% so the red contours are easy to see; Off restores the normal view.
uicontrol(figCent, 'Style','popupmenu', 'String',{'Circle','Line'}, ...
    'Value',2, 'Units','normalized', 'Position',[0.560 0.047 0.072 0.036], ...
    'FontSize',9, 'Tag','popCentShape', ...
    'TooltipString',['Selection shape. Circle: click one centre; In/Out are the ' ...
        'inner/outer DIAMETERS (µm). Line: click two endpoints; In/Out are the ' ...
        'inner/outer corridor WIDTHS (µm) of a thick line segment.'], ...
    'Callback', @(~,~) onCentShapeChange(figCent));
uicontrol(figCent, 'Style','text', 'String','In:', ...
    'Units','normalized', 'Position',[0.636 0.050 0.024 0.03], ...
    'FontSize',9, 'HorizontalAlignment','left', 'BackgroundColor',bg);
uicontrol(figCent, 'Style','edit', 'String','100', ...
    'Units','normalized', 'Position',[0.660 0.047 0.040 0.036], ...
    'FontSize',9, 'Tag','edCentDiam', ...
    'BackgroundColor',[1 1 1], ...
    'TooltipString',['Inner size (µm): circle = inner diameter, line = corridor ' ...
        'width. Lesions overlapping this inner region form the "Region" group.']);
uicontrol(figCent, 'Style','text', 'String','Out:', ...
    'Units','normalized', 'Position',[0.702 0.050 0.030 0.03], ...
    'FontSize',9, 'HorizontalAlignment','left', 'BackgroundColor',bg);
uicontrol(figCent, 'Style','edit', 'String','800', ...
    'Units','normalized', 'Position',[0.732 0.047 0.040 0.036], ...
    'FontSize',9, 'Tag','edSurDiam', ...
    'BackgroundColor',[1 1 1], ...
    'TooltipString',['Outer size (µm): circle = outer diameter, line = outer ' ...
        'corridor width. Surround = lesions overlapping the zone between In and ' ...
        'Out but NOT the inner region. Set 0 or <= In to disable the surround.']);
uicontrol(figCent, 'Style','togglebutton', 'String','Select region: Off', ...
    'Value',0, 'Units','normalized', 'Position',[0.776 0.047 0.216 0.036], ...
    'FontSize',9, 'Tag','tglCentSelReg', ...
    'TooltipString',['Toggle On, then click on the map (a centre for Circle, or ' ...
        'two endpoints for Line) to select a region: shows the selected (inner) ' ...
        'and surrounding lesion contours and opens ONE combined time course with ' ...
        'the Region and Surround groups overlaid. Toggle Off to restore.'], ...
    'Callback', @(~,~) selectCentroidRegion(figCent));

% ── Cluster statistics for the deficit map (bottom-left strip) ───────────
% Runs the per-pixel test with permutation-based cluster correction on
% whatever the map currently shows, outlines the surviving clusters and
% prints the numbers. Kept as a button, not a live redraw: a run is seconds
% to a couple of minutes, and nobody wants that on a slider drag.
uicontrol(figCent, 'Style','pushbutton', 'String','Cluster stats', ...
    'Units','normalized', 'Position',[0.07 0.005 0.145 0.036], ...
    'FontSize',9, 'Tag','btnCentStats', ...
    'TooltipString',['Per-pixel Fisher exact / chi-square test on the ' ...
        'current deficit map, family-wise corrected by permuting the ' ...
        'deficit labels between lesions and comparing each cluster with ' ...
        'the null distribution of the largest cluster. Outlines the ' ...
        'clusters that survive and prints the table to the console.'], ...
    'Callback', @(~,~) runDeficitClusterStats(figCent));
uicontrol(figCent, 'Style','popupmenu', 'String',{'Fisher','Chi2'}, ...
    'Value',1, 'Units','normalized', 'Position',[0.222 0.005 0.082 0.036], ...
    'FontSize',9, 'Tag','popCentTest', ...
    'TooltipString',['Per-pixel test. Fisher is exact and is the right ' ...
        'choice when a dozen lesions make the expected counts small; ' ...
        'chi-square is the approximation most papers quote.']);
uicontrol(figCent, 'Style','text', 'String','perm:', ...
    'Units','normalized', 'Position',[0.312 0.008 0.040 0.030], ...
    'FontSize',9, 'HorizontalAlignment','left', 'BackgroundColor',bg);
uicontrol(figCent, 'Style','edit', 'String','2000', ...
    'Units','normalized', 'Position',[0.352 0.005 0.055 0.036], ...
    'FontSize',9, 'Tag','edCentNPerm', 'BackgroundColor',[1 1 1], ...
    'TooltipString',['Label shuffles. Every shuffle contributes its ' ...
        'largest cluster to the null, so the smallest p obtainable is ' ...
        '1/(perm+1). All arrangements are enumerated instead when there ' ...
        'are fewer of them than this.']);
uicontrol(figCent, 'Style','text', 'String','p<', ...
    'Units','normalized', 'Position',[0.414 0.008 0.024 0.030], ...
    'FontSize',9, 'HorizontalAlignment','left', 'BackgroundColor',bg);
uicontrol(figCent, 'Style','edit', 'String','0.05', ...
    'Units','normalized', 'Position',[0.438 0.005 0.048 0.036], ...
    'FontSize',9, 'Tag','edCentPThr', 'BackgroundColor',[1 1 1], ...
    'TooltipString',['Cluster-forming threshold on the PIXEL p. It is not ' ...
        'a significance level: it only decides which pixels get grouped ' ...
        'into candidate clusters. The reported cluster p is corrected.']);

% Live update while dragging (plus the standard on-release callback). Min/Max
% size additionally refresh the linked Region+Surround companion figures.
% The time-course figure's redraw runs drawPopulationFigure's full stats
% (ANOVA/LME), so that one stays release-only (onCentSizeChange) to keep
% dragging from getting laggy. The lesion-volume bar chart is cheap by
% comparison (one bar/errorbar/scatter, no stats) so it refreshes on every
% drag tick too (onCentSizeChangeLive), matching the scatter view.
for hh = [hSz hAl]
    set(hh, 'Callback', @(~,~) redrawCentroidScatter(figCent));
    addlistener(hh, 'ContinuousValueChange', @(~,~) redrawCentroidScatter(figCent));
end
for hh = [hMn hMx]
    set(hh, 'Callback', @(~,~) onCentSizeChange(figCent));
    addlistener(hh, 'ContinuousValueChange', @(~,~) onCentSizeChangeLive(figCent));
end

% Custom datatip: show centroid position as mm from bregma (AP, LR) instead
% of raw plot pixels. 100 px = 1 mm; bregma in plot coords at (570, mapH+1-540).
dcm = datacursormode(figCent);
set(dcm, 'UpdateFcn', @(~,evt) centDatatip(evt, figCent));

redrawCentroidScatter(figCent);
end

function txt = centDatatip(evt, figCent)
% Convert (plot x, plot y) at the data tip into (AP mm, LR mm) from bregma.
%   AP positive = anterior; LR positive = right of bregma.
S = getappdata(figCent, 'centData');
pos = evt.Position;
x = pos(1);  y = pos(2);
if isempty(S) || ~isfield(S, 'mapH')
    txt = {sprintf('x = %.0f px', x), sprintf('y = %.0f px', y)};
    return
end
PX_PER_MM = 100;
bx = 570;                      % bregma ML pixel
by = S.mapH + 1 - 540;         % bregma plot-y (after flipud convention)
AP_mm = (y - by) / PX_PER_MM;
LR_mm = (x - bx) / PX_PER_MM;
txt = {sprintf('AP %+.2f mm', AP_mm), sprintf('LR %+.2f mm', LR_mm)};
end

function ttl = drawDeficitOverlay(ax, S, mi, phIdx, vLo, vHi, inclDual, minCov)
% Draw the deficit-occurrence heatmap into ax (the caller has already drawn
% the atlas / 1 mm grid and set the axis limits & YDir). For every atlas
% pixel: % of eligible lesions covering it whose animal showed a deficit.
%   "Eligible" = lesion size in [vLo, vHi] with valid symptom data
%   "deficit"  = animal symptom > median of eligible (median split)
% inclDual=false drops lesions from animals with >1 lesion, so the deficit
% is attributable to a single lesion. High pixels = consistently associated
% with deficit; low pixels = covered by lesions that did NOT produce a
% deficit (exonerated). Returns the title string.
if nargin < 7 || isempty(inclDual), inclDual = true; end
if nargin < 8 || isempty(minCov),   minCov   = 1;    end
[E, msg] = deficitLesionSet(S, mi, phIdx, vLo, vHi, inclDual);
mname  = E.mname;
phName = E.phName;
if ~isempty(msg)
    ttl = sprintf('Deficit heatmap — %s', msg);
    return
end
if ~isfield(S,'polyPts') || isempty(S.polyPts)
    ttl = 'Deficit heatmap — lesion polygons unavailable (re-open Lesion Centroids)';
    return
end
mapH = S.mapH;  mapW = S.mapW;
elig    = E.elig;
deficit = E.deficit;
thresh  = E.thresh;

% Per-pixel numerator / denominator
num = zeros(mapH, mapW);
den = zeros(mapH, mapW);
for k = find(elig)
    pts = S.polyPts{k};
    if isempty(pts), continue; end
    m = poly2mask(pts(:,1), pts(:,2), mapH, mapW);
    den(m) = den(m) + 1;
    if deficit(k), num(m) = num(m) + 1; end
end
% Color every pixel covered by at least MIN_COVERAGE eligible lesions.
% Color alone conveys % deficit; every shown pixel uses the same opacity.
MIN_COVERAGE = max(1, round(minCov));
FIXED_ALPHA  = 0.65;
valid = den >= MIN_COVERAGE;
pct = nan(mapH, mapW);
pct(valid) = 100 * num(valid) ./ den(valid);

cmap   = jet(256);
idx256 = ones(mapH, mapW);
idx256(valid) = max(1, min(256, round(pct(valid)/100*255) + 1));
heatRGB = zeros(mapH, mapW, 3);
for c = 1:3
    layerC = cmap(:, c);
    layer  = zeros(mapH, mapW);
    layer(valid) = layerC(idx256(valid));
    heatRGB(:, :, c) = layer;
end
alpha = zeros(mapH, mapW);
alpha(valid) = FIXED_ALPHA;
hH = image(ax, flipud(uint8(heatRGB * 255)));
set(hH, 'AlphaData', flipud(alpha));

colormap(ax, jet);
clim(ax, [0 100]);
cb = colorbar(ax);
cb.Label.String = '% lesions associated with deficit';

ttl = sprintf(['Deficit heatmap — %s, %s  |  size %.2f–%.2f mm³, ' ...
    'deficit = %s > %.2f (median, n_def=%d / n=%d)'], ...
    phName, mname, vLo, vHi, lower(mname), thresh, sum(deficit), sum(elig));
if ~inclDual
    ttl = sprintf('%s  | single-lesion animals only', ttl);
end
if MIN_COVERAGE > 1
    ttl = sprintf('%s  (shown where ≥%d lesions/pixel)', ttl, MIN_COVERAGE);
end
end

function [E, msg] = deficitLesionSet(S, mi, phIdx, vLo, vHi, inclDual)
% The lesion set the deficit map is built from, and each lesion's deficit /
% no-deficit label. Shared by the heatmap and by the cluster statistics, so
% the test is run on exactly the lesions the picture is drawn from rather
% than on a second, independently written copy of the same filters.
%
%   E.elig     per marker: within the size range, single-lesion when inclDual
%              is false, and a finite symptom value for this metric/phase
%   E.deficit  per marker: eligible AND on the deficit side of the median
%   E.sym      symptom value per marker for the selected metric/phase
%   E.thresh   the median split point
%   E.mname / E.phName   display names of the metric and phase
%
% msg is non-empty when there is nothing to compute, and says why.
msg = '';
E = struct('elig',[], 'deficit',[], 'sym',[], 'thresh',NaN, ...
           'mname','metric', 'phName','All');
if isfield(S,'metricNames') && mi >= 1 && numel(S.metricNames) >= mi
    E.mname = S.metricNames{mi};
end
if isfield(S,'phaseNames') && phIdx >= 1 && numel(S.phaseNames) >= phIdx
    E.phName = S.phaseNames{phIdx};
end
if ~isfield(S,'metricMat3d') || isempty(S.metricMat3d)
    msg = 'no symptom data on this figure';
    return
end
sym   = reshape(squeeze(S.metricMat3d(:, mi, phIdx)), 1, []);
E.sym = sym;

% Phase-independent eligibility (size-range + optional single-lesion filter)
volDualOK = (S.vol >= vLo) & (S.vol <= vHi);
if ~inclDual
    [~, ~, ic]  = unique(S.ids);
    isMultiAll  = reshape(accumarray(ic(:), 1) > 1, [], 1);
    isMultiAll  = reshape(isMultiAll(ic), 1, []);   % per-marker
    volDualOK   = volDualOK & ~isMultiAll;
end
E.elig = volDualOK & ~isnan(sym);
if ~any(E.elig)
    msg = 'no eligible lesions for the current filter';
    return
end

% Deficit threshold = median symptom value, but POOLED over all phases (not
% just the current one) so the bar is FIXED across phases. A per-phase median
% re-split the cohort in half every phase, so a recovered S1 lesion in Chronic
% — merely above the (now low) chronic median — was still labeled "deficit"
% and, being single-coverage (num/den = 100%), painted dark red. Pooling holds
% the bar still, so a lesion whose current-phase value has recovered below it
% drops out of the deficit set (blue), while genuinely severe phases stay red.
% "Regular hold" is the only metric where higher = better, so for it the
% BELOW-median half is the deficit half.
symSlab  = S.metricMat3d(:, mi, :);                      % markers x 1 x nP
refMask  = repmat(volDualOK(:), 1, 1, size(symSlab, 3)) & isfinite(symSlab);
E.thresh = median(symSlab(refMask), 'omitnan');
if strcmpi(E.mname, 'Regular hold')
    E.deficit = E.elig & (sym < E.thresh);
else
    E.deficit = E.elig & (sym > E.thresh);
end
end

function R = deficitClusterStats(S, mi, phIdx, vLo, vHi, inclDual, minCov, opts)
% Per-pixel lesion-symptom test for the deficit map, with permutation-based
% cluster correction. Returns a result struct; draws nothing.
%
% At every tested pixel the eligible lesions form a 2x2 table
%
%                         covers pixel    does not
%       deficit                 a          nDef-a
%       no deficit              b          nNon-b
%
% read by Fisher's exact test (default; exact is what small counts need) or
% by a chi-square test. Those p-values are NOT corrected one at a time —
% there are ~10^4-10^5 of them and they are strongly dependent, so a
% Bonferroni/FDR pass over pixels would be both wrong-headed and powerless.
% Instead:
%
%   1. pixels with p <= pThr are grouped into connected clusters, separately
%      in the deficit-ENRICHED and deficit-SPARED directions (a cluster must
%      not straddle the two);
%   2. the deficit labels are shuffled BETWEEN LESIONS and the whole map is
%      recomputed, thousands of times. Shuffling labels leaves every lesion
%      outline — and therefore the entire overlap geometry — untouched, which
%      is exactly the null "the label is independent of where the lesion is";
%   3. each shuffle contributes the size and the mass (sum of -log10 p) of
%      its LARGEST cluster, over both directions, to a null distribution;
%   4. an observed cluster's p is its rank in that distribution. Taking the
%      maximum makes it family-wise corrected across the whole map and across
%      both directions at once.
%
% Only the CLUSTER-level p is interpretable. A cluster says "somewhere in
% here matters"; it does not license a claim about any single pixel in it.
%
% opts (all optional):
%   test    'fisher' (default) | 'chi2'
%   pThr    cluster-forming threshold on the pixel p (default 0.05)
%   nPerm   shuffles (default 2000). When the labels admit fewer distinct
%           assignments than this, ALL of them are enumerated and the test is
%           exact rather than sampled.
%   conn    pixel connectivity, 4 or 8 (default 8)
%   seed    RNG seed, so a reported p is reproducible (default 0)
%   verbose print progress (default true)
if nargin < 8 || isempty(opts), opts = struct(); end
dflt = struct('test','fisher', 'pThr',0.05, 'nPerm',2000, 'conn',8, ...
              'seed',0, 'verbose',true);
fn = fieldnames(dflt);
for i = 1:numel(fn)
    if ~isfield(opts, fn{i}) || isempty(opts.(fn{i})), opts.(fn{i}) = dflt.(fn{i}); end
end
opts.pThr = max(min(opts.pThr, 0.5), 1e-6);
if ~ismember(opts.conn, [4 8]), opts.conn = 8; end
minCov = max(1, round(minCov));

R = struct('ok',false, 'msg','', 'clusters',[], 'opts',opts, ...
           'mi',mi, 'phIdx',phIdx, 'vLo',vLo, 'vHi',vHi, ...
           'inclDual',inclDual, 'minCov',minCov, 'sig','', ...
           'mname','', 'phName','', 'thresh',NaN, ...
           'nLesion',0, 'nDef',0, 'nNon',0, 'nPixTested',0, ...
           'nPermUsed',0, 'exhaustive',false, 'pFloor',NaN, ...
           'pMinObs',NaN, 'nullMaxSize',[], 'nullMaxMass',[], ...
           'mapH',0, 'mapW',0, 'mm2PerPix',1e-4);
R.sig = deficitStatsSignature(mi, phIdx, vLo, vHi, inclDual, minCov, opts);

[E, msg] = deficitLesionSet(S, mi, phIdx, vLo, vHi, inclDual);
R.mname = E.mname;  R.phName = E.phName;  R.thresh = E.thresh;
if ~isempty(msg), R.msg = msg; return; end
if ~isfield(S,'polyPts') || isempty(S.polyPts)
    R.msg = 'lesion polygons unavailable (re-open Lesion Centroids)';
    return
end

kIdx = find(E.elig);
lab  = E.deficit(kIdx);            % logical, one per included lesion
N    = numel(kIdx);
nDef = sum(lab);  nNon = N - nDef;
R.nLesion = N;  R.nDef = nDef;  R.nNon = nNon;
R.mapH = S.mapH;  R.mapW = S.mapW;
if nDef < 2 || nNon < 2
    R.msg = sprintf(['the median split leaves %d deficit / %d non-deficit ' ...
        'lesions — at least 2 of each are needed'], nDef, nNon);
    return
end

% ── Coverage: rasterize each included lesion once ────────────────────────
masks = cell(1, N);
den   = zeros(S.mapH, S.mapW);
for j = 1:N
    pts = S.polyPts{kIdx(j)};
    if isempty(pts), continue; end
    masks{j} = poly2mask(pts(:,1), pts(:,2), S.mapH, S.mapW);
    den = den + masks{j};
end
testMask = den >= minCov;
if ~any(testMask(:))
    R.msg = sprintf('no pixel is covered by %d or more included lesions', minCov);
    return
end
% Work inside the bounding box of the tested pixels: every permutation runs a
% connected-component pass, and the atlas frame is mostly empty space.
rr = find(any(testMask, 2));  cc = find(any(testMask, 1));
r0 = rr(1);  r1 = rr(end);  c0 = cc(1);  c1 = cc(end);
crop = [r1-r0+1, c1-c0+1];
tm   = testMask(r0:r1, c0:c1);
idxT = find(tm);
nT   = numel(idxT);
R.nPixTested = nT;

C = false(nT, N);
for j = 1:N
    if isempty(masks{j}), continue; end
    mj = masks{j}(r0:r1, c0:c1);
    C(:, j) = mj(idxT);
end
clear masks

% Every pixel covered by the SAME set of lesions has the same 2x2 table under
% every shuffle, and N overlapping polygons carve the map into far fewer
% distinct sets than there are pixels. Collapsing to those patterns is what
% makes thousands of permutations cheap.
[Cu, ~, ic] = unique(C, 'rows');
clear C
Cud  = double(Cu);
covU = sum(Cud, 2);
if opts.verbose
    fprintf('  %d tested pixels collapse to %d distinct coverage patterns\n', ...
            nT, size(Cud, 1));
end

% p for every reachable (a, b) — at most (nDef+1)(nNon+1) cells, so the
% per-pixel test is a table lookup no matter how many pixels there are.
switch lower(opts.test)
    case 'chi2', LUT = chi2LUT2x2(nDef, nNon);
    otherwise,   LUT = fisherLUT2x2(nDef, nNon);  opts.test = 'fisher';
end
pi0 = nDef / N;

% ── Observed map and its clusters ────────────────────────────────────────
[pObs, sObs] = deficitPixelP(Cud, covU, LUT, ic, pi0, double(lab(:)));
R.pMinObs = min(pObs);
[obsMaxS, obsMaxM, cl] = deficitScanClusters(pObs, sObs, idxT, crop, ...
                                             opts.pThr, opts.conn, true);
if isempty(cl)
    R.ok  = true;
    R.msg = sprintf('no pixel reaches p <= %.3g (smallest p on the map is %.3g)', ...
                    opts.pThr, R.pMinObs);
    R.clusters = cl;
    return
end

% ── Null distribution of the largest cluster ─────────────────────────────
% The label vector has only nchoosek(N, nDef) distinct arrangements. When
% that is small the loop enumerates all of them and the p is exact; the count
% also sets the smallest p the test can possibly return, which is worth
% knowing before reading a "p = 0.03" from 12 lesions.
totalAssign = nchoosek(N, nDef);
exhaustive  = totalAssign <= min(opts.nPerm, 20000);
if exhaustive
    combs     = nchoosek(1:N, nDef);
    nPermUsed = size(combs, 1);
    R.pFloor  = 1 / nPermUsed;
else
    nPermUsed = round(opts.nPerm);
    R.pFloor  = 1 / (nPermUsed + 1);
end
R.exhaustive = exhaustive;
R.nPermUsed  = nPermUsed;

sPrev = rng;                      % leave the caller's RNG stream as it was
cleanupRng = onCleanup(@() rng(sPrev));
rng(opts.seed, 'twister');
nullS = zeros(nPermUsed, 1);
nullM = zeros(nPermUsed, 1);
tic0  = tic;
for q = 1:nPermUsed
    lv = zeros(N, 1);
    if exhaustive
        lv(combs(q, :)) = 1;
    else
        lv(randperm(N, nDef)) = 1;
    end
    [pP, sP] = deficitPixelP(Cud, covU, LUT, ic, pi0, lv);
    [nullS(q), nullM(q)] = deficitScanClusters(pP, sP, idxT, crop, ...
                                               opts.pThr, opts.conn, false);
    if opts.verbose && mod(q, max(1, floor(nPermUsed/10))) == 0
        fprintf('  permutation %d/%d (%.0f s)\n', q, nPermUsed, toc(tic0));
    end
end
R.nullMaxSize = nullS;
R.nullMaxMass = nullM;

% ── Cluster-level p ──────────────────────────────────────────────────────
% Sampled: the +1 counts the observed labelling itself, which keeps the test
% valid (a p of exactly 0 is not a thing a permutation test can produce).
% Exhaustive: the observed labelling is already one of the enumerated ones.
for q = 1:numel(cl)
    if exhaustive
        cl(q).pSize = sum(nullS >= cl(q).size) / nPermUsed;
        cl(q).pMass = sum(nullM >= cl(q).mass) / nPermUsed;
    else
        cl(q).pSize = (1 + sum(nullS >= cl(q).size)) / (1 + nPermUsed);
        cl(q).pMass = (1 + sum(nullM >= cl(q).mass)) / (1 + nPermUsed);
    end
    cl(q).pCluster = cl(q).pMass;      % mass is the reported one (see below)
    % Back to full-map pixels, and to mm from bregma: 100 px = 1 mm, bregma
    % at map pixel (row 540, col 570) — the convention centDatatip uses.
    [pr, pc] = ind2sub(crop, cl(q).pix);
    pr = pr + r0 - 1;  pc = pc + c0 - 1;
    cl(q).pixFull = sub2ind([S.mapH, S.mapW], pr, pc);
    cl(q).area_mm2 = cl(q).size * R.mm2PerPix;
    cl(q).AP_mm    = (540 - mean(pr)) / 100;
    cl(q).LR_mm    = (mean(pc) - 570) / 100;
end
% Report enriched clusters first, then by mass.
[~, ord] = sortrows([-[cl.dir]', -[cl.mass]']);
R.clusters = cl(ord);
R.ok = true;
R.msg = '';
if obsMaxS == 0 && obsMaxM == 0, R.msg = 'no supra-threshold cluster'; end
end

function sig = deficitStatsSignature(mi, phIdx, vLo, vHi, inclDual, minCov, opts)
% Identity of a stats run, so a stored result is only redrawn onto the map it
% was computed for. Any filter change makes the stored clusters stale.
sig = sprintf('m%d_p%d_v%.4f-%.4f_d%d_c%d_%s_t%.4g_n%d_k%d_s%d', ...
    mi, phIdx, vLo, vHi, inclDual, minCov, lower(opts.test), ...
    opts.pThr, opts.nPerm, opts.conn, opts.seed);
end

function [pPix, sPix] = deficitPixelP(Cud, covU, LUT, ic, pi0, labVec)
% The p-value and the direction at every tested pixel, for one assignment of
% deficit labels to lesions. Everything is computed on the distinct coverage
% patterns and only then expanded to pixels, which is what a few thousand
% permutations rest on. sPix is +1 where deficit lesions are over-represented
% relative to their overall share pi0, -1 where they are under-represented.
aU   = Cud * labVec(:);
bU   = covU - aU;
pU   = LUT(sub2ind(size(LUT), aU + 1, bU + 1));
sU   = sign(aU ./ covU - pi0);
pPix = pU(ic);
sPix = sU(ic);
end

function [mxSize, mxMass, cl] = deficitScanClusters(pPix, sPix, idxT, crop, pThr, conn, wantList)
% Threshold one p-map and measure its connected clusters, the two directions
% kept apart so a deficit-enriched patch can never merge with a spared one.
% Returns the largest size and mass in either direction (that pair is what a
% permutation contributes to the null) and, when asked, the full list.
mxSize = 0;  mxMass = 0;
cl = struct('dir',{}, 'pix',{}, 'size',{}, 'mass',{}, 'pMin',{}, ...
            'pSize',{}, 'pMass',{}, 'pCluster',{}, 'pixFull',{}, ...
            'area_mm2',{}, 'AP_mm',{}, 'LR_mm',{});
mlp = -log10(max(pPix, realmin));
M   = false(crop);
for d = [1 -1]
    sel = (pPix <= pThr) & (sPix == d);
    if ~any(sel), continue; end
    M(:) = false;
    M(idxT(sel)) = true;
    CC = bwconncomp(M, conn);
    if CC.NumObjects == 0, continue; end
    L   = labelmatrix(CC);
    lv  = double(L(idxT(sel)));
    szv = accumarray(lv, 1,        [CC.NumObjects 1]);
    msv = accumarray(lv, mlp(sel), [CC.NumObjects 1]);
    mxSize = max(mxSize, max(szv));
    mxMass = max(mxMass, max(msv));
    if wantList
        % @min is slow enough to matter inside the permutation loop, so the
        % peak p is only collected for the observed map.
        pmn = accumarray(lv, pPix(sel), [CC.NumObjects 1], @min, 1);
        for q = 1:CC.NumObjects
            cl(end+1) = struct('dir',d, 'pix',CC.PixelIdxList{q}, ...
                'size',szv(q), 'mass',msv(q), 'pMin',pmn(q), ...
                'pSize',NaN, 'pMass',NaN, 'pCluster',NaN, 'pixFull',[], ...
                'area_mm2',NaN, 'AP_mm',NaN, 'LR_mm',NaN); %#ok<AGROW>
        end
    end
end
end

function P = fisherLUT2x2(nDef, nNon)
% Two-sided Fisher exact p for every reachable 2x2 table
%     [ a  b ; nDef-a  nNon-b ],   indexed P(a+1, b+1).
%
% Conditioning on both margins makes the count of deficit lesions covering a
% pixel hypergeometric, so the whole test is a sum over that pmf: the
% two-sided p is the total probability of every table no more likely than the
% observed one (Fisher's own definition, and what fishertest returns).
% Computed once per map — the per-pixel test is then a lookup.
N = nDef + nNon;
P = ones(nDef+1, nNon+1);
lchoose = @(n, k) gammaln(n+1) - gammaln(k+1) - gammaln(n-k+1);
for n1 = 0:N
    aLo = max(0, n1 - nNon);
    aHi = min(nDef, n1);
    av  = (aLo:aHi)';
    if isempty(av), continue; end
    pmf = exp(lchoose(nDef, av) + lchoose(nNon, n1 - av) - lchoose(N, n1));
    pmf = pmf / sum(pmf);            % guards the tails against rounding
    for t = 1:numel(av)
        a = av(t);
        % 1+1e-9: ties in probability must be counted in, and floating point
        % makes two algebraically equal tables differ in the last bits.
        P(a+1, n1-a+1) = min(1, sum(pmf(pmf <= pmf(t) * (1 + 1e-9))));
    end
end
end

function P = chi2LUT2x2(nDef, nNon)
% Pearson chi-square (1 df, no continuity correction) p for the same tables
% fisherLUT2x2 covers, indexed P(a+1, b+1). Offered because chi-square is
% what most lesion-symptom papers report; Fisher is the default because with
% a dozen lesions the expected counts are routinely below 5, which is exactly
% where the chi-square approximation stops being trustworthy.
N = nDef + nNon;
P = ones(nDef+1, nNon+1);
for a = 0:nDef
    for b = 0:nNon
        n1 = a + b;  n2 = N - n1;
        if n1 == 0 || n2 == 0, continue; end
        c = nDef - a;  d = nNon - b;
        X2 = N * (a*d - b*c)^2 / (n1 * n2 * nDef * nNon);
        P(a+1, b+1) = erfc(sqrt(max(X2, 0) / 2));   % upper tail, 1 df
    end
end
end

function opts = deficitStatsOptsFromUI(figCent)
% The test settings the bottom-left controls currently hold.
opts = struct('test','fisher', 'pThr',0.05, 'nPerm',2000, 'conn',8, ...
              'seed',0, 'verbose',true);
hT = findobj(figCent, 'Tag','popCentTest');
if ~isempty(hT) && round(get(hT(1),'Value')) == 2, opts.test = 'chi2'; end
hN = findobj(figCent, 'Tag','edCentNPerm');
if ~isempty(hN)
    v = str2double(get(hN(1),'String'));
    if isfinite(v) && v >= 10, opts.nPerm = round(v); end
    set(hN(1), 'String', sprintf('%d', opts.nPerm));
end
hP = findobj(figCent, 'Tag','edCentPThr');
if ~isempty(hP)
    v = str2double(get(hP(1),'String'));
    if isfinite(v) && v > 0 && v <= 0.5, opts.pThr = v; end
    set(hP(1), 'String', sprintf('%g', opts.pThr));
end
end

function R = runDeficitClusterStats(figCent)
% "Cluster stats" button: run the per-pixel test with permutation-based
% cluster correction on the map as it currently stands, print the result and
% outline the surviving clusters. The run is tied to the filter settings it
% used, so moving a slider afterwards drops the outlines rather than leaving
% them floating over a map they no longer describe.
R = [];
S = getappdata(figCent, 'centData');
if isempty(S), return; end

hHM = findobj(figCent, 'Tag','tglCentHeatmap');
if ~isempty(hHM) && ~logical(get(hHM(1),'Value'))
    warning('LeverPullTask:noDeficitMap', ...
        ['Cluster stats: turn "Deficit map" on first — the test describes ' ...
         'that map, not the centroid scatter.']);
    return
end

[mi, phIdx, vLo, vHi, inclDual, minCov] = deficitCurrentFilters(figCent, S);
opts = deficitStatsOptsFromUI(figCent);

hBtn = findobj(figCent, 'Tag','btnCentStats');
if ~isempty(hBtn), set(hBtn(1), 'Enable','off', 'String','running…'); drawnow; end
cleanupBtn = onCleanup(@() deficitStatsButtonBack(hBtn));

fprintf('\n=== Deficit map — cluster statistics ===\n');
R = deficitClusterStats(S, mi, phIdx, vLo, vHi, inclDual, minCov, opts);
printDeficitClusterStats(R);
setappdata(figCent, 'centClusterR', R);
% Redraw rather than draw on top: the redraw path already knows how to put
% the outlines and the title line on a matching map, so there is one place
% where that happens instead of two that can drift apart.
redrawCentroidScatter(figCent);
end

function deficitStatsButtonBack(hBtn)
% Put the "Cluster stats" button back however the run ended.
if ~isempty(hBtn) && isgraphics(hBtn(1))
    set(hBtn(1), 'Enable','on', 'String','Cluster stats');
end
end

function [mi, phIdx, vLo, vHi, inclDual, minCov] = deficitCurrentFilters(figCent, S)
% The filter settings the deficit map is currently drawn with. Read from the
% same controls redrawCentroidScatter reads, so a stats run and the picture
% can never disagree about which lesions are in.
hMet = findobj(figCent, 'Tag','popCentMetric');
hPh  = findobj(figCent, 'Tag','popCentPhase');
mi    = 1;  if ~isempty(hMet), mi    = round(get(hMet(1),'Value')); end
phIdx = 1;  if ~isempty(hPh),  phIdx = round(get(hPh(1),'Value'));  end
if isfield(S,'metricMat3d') && ~isempty(S.metricMat3d)
    mi    = max(1, min(mi,    size(S.metricMat3d, 2)));
    phIdx = max(1, min(phIdx, size(S.metricMat3d, 3)));
end
hMn = findobj(figCent, 'Tag','sldCentMinVol');
hMx = findobj(figCent, 'Tag','sldCentMaxVol');
vLo = -inf;  vHi = inf;
if ~isempty(hMn), vLo = get(hMn(1),'Value'); end
if ~isempty(hMx), vHi = get(hMx(1),'Value'); end
if vLo > vHi, tmp = vLo;  vLo = vHi;  vHi = tmp; end
hDual = findobj(figCent, 'Tag','tglCentDual');
inclDual = true;  if ~isempty(hDual), inclDual = logical(get(hDual(1),'Value')); end
hCov = findobj(figCent, 'Tag','tglCentMinCov');
covHi = false;  if ~isempty(hCov), covHi = logical(get(hCov(1),'Value')); end
minCov = 1;  if covHi, minCov = 2; end
end

function printDeficitClusterStats(R)
% The whole result, in the console, in the order a Methods/Results paragraph
% needs it. Everything a reader would have to take on trust otherwise — how
% many lesions, how the labels split, how many permutations, and the smallest
% p the design can return — is printed alongside the clusters.
if isempty(R)
    fprintf('  (no result)\n');  return
end
fprintf('  %s, %s  |  lesion size %.2f–%.2f mm³%s\n', R.phName, R.mname, ...
    R.vLo, R.vHi, ternStr(~R.inclDual, ', single-lesion animals only', ''));
fprintf('  median split at %.3f  ->  %d deficit / %d non-deficit lesions (n=%d)\n', ...
    R.thresh, R.nDef, R.nNon, R.nLesion);
if ~R.ok
    fprintf('  NOT RUN: %s\n\n', R.msg);
    return
end
fprintf('  pixels tested: %d (covered by >= %d lesions), %.3f mm²\n', ...
    R.nPixTested, R.minCov, R.nPixTested * R.mm2PerPix);
fprintf('  per-pixel test: %s, cluster-forming p <= %.3g, %d-connectivity\n', ...
    upper(R.opts.test), R.opts.pThr, R.opts.conn);
if R.exhaustive
    fprintf('  permutations: all %d label arrangements (exact); smallest possible p = %.4g\n', ...
        R.nPermUsed, R.pFloor);
else
    fprintf('  permutations: %d random shuffles (seed %d); smallest possible p = %.4g\n', ...
        R.nPermUsed, R.opts.seed, R.pFloor);
end
fprintf('  smallest per-pixel p anywhere on the map: %.4g\n', R.pMinObs);
if isempty(R.clusters)
    fprintf('  no supra-threshold cluster%s\n\n', ternStr(~isempty(R.msg), [' — ' R.msg], ''));
    return
end
fprintf('\n  %-3s %-9s %8s %9s %8s %9s %9s %9s %8s\n', ...
    '#', 'direction', 'px', 'area mm²', 'mass', 'peak p', 'p (mass)', 'p (size)', 'AP,LR');
for q = 1:numel(R.clusters)
    c = R.clusters(q);
    fprintf('  %-3d %-9s %8d %9.4f %8.2f %9.4g %9.4f %9.4f  %+0.2f,%+0.2f\n', ...
        q, ternStr(c.dir > 0, 'enriched', 'spared'), c.size, c.area_mm2, ...
        c.mass, c.pMin, c.pMass, c.pSize, c.AP_mm, c.LR_mm);
end
nSig = sum([R.clusters.pCluster] <= 0.05);
fprintf(['  (enriched = deficit animals over-represented; AP,LR = cluster ' ...
         'centre in mm from bregma)\n']);
fprintf(['  %d of %d clusters survive family-wise correction at 0.05. ' ...
         'Only the cluster-level p is interpretable —\n  a significant ' ...
         'cluster means "somewhere in this patch matters", not that any ' ...
         'one pixel in it does.\n\n'], nSig, numel(R.clusters));
end

function s = ternStr(cond, a, b)
% Pick one of two strings. Keeps the printf lines above readable.
if cond, s = a; else, s = b; end
end

function line2 = deficitClusterTitleLine(R)
% One-line summary of a stats run, for the map's title.
if isempty(R) || ~R.ok
    line2 = 'cluster stats: not run';
    if ~isempty(R) && ~isempty(R.msg), line2 = ['cluster stats: ' R.msg]; end
    return
end
nSig = 0;
if ~isempty(R.clusters), nSig = sum([R.clusters.pCluster] <= 0.05); end
line2 = sprintf(['cluster stats: %s, pixel p<=%.3g, %d %s -> %d cluster(s) ' ...
                 'at p_FWE<=0.05 (min possible %.3g)'], ...
    upper(R.opts.test), R.opts.pThr, R.nPermUsed, ...
    ternStr(R.exhaustive, 'exact permutations', 'shuffles'), nSig, R.pFloor);
end

function drawDeficitClusters(ax, R)
% Outline the clusters that survive correction on top of the deficit map.
% Solid black = deficit-enriched, dashed white = deficit-spared; anything
% that failed correction is not drawn at all, so the picture cannot suggest
% more than the statistics support.
if isempty(R) || ~R.ok || isempty(R.clusters), return; end
isSig = [R.clusters.pCluster] <= 0.05;
if ~any(isSig), return; end
wasHeld = ishold(ax);
hold(ax, 'on');
% Numbered as in the printed table, so a cluster on the map can be looked up.
for q = find(isSig)
    c = R.clusters(q);
    M = false(R.mapH, R.mapW);
    M(c.pixFull) = true;
    % The atlas is drawn flipud with YDir normal, so the mask has to be
    % flipped the same way to land on the lesions it was computed from.
    if c.dir > 0
        args = {'LineColor', [0 0 0], 'LineStyle', '-',  'LineWidth', 1.6};
    else
        args = {'LineColor', [1 1 1], 'LineStyle', '--', 'LineWidth', 1.4};
    end
    contour(ax, flipud(M), [0.5 0.5], args{:}, 'Tag','sigClust');
    text(ax, meanCol(c.pixFull, R.mapH), ...
         R.mapH + 1 - meanRow(c.pixFull, R.mapH), sprintf('%d', q), ...
         'Color', [0 0 0], 'FontSize', 9, 'FontWeight','bold', ...
         'HorizontalAlignment','center', 'BackgroundColor',[1 1 1], ...
         'Margin', 1, 'Tag','sigClust');
end
if ~wasHeld, hold(ax, 'off'); end
end

function r = meanRow(pixFull, mapH)
% Mean map row of a set of full-map linear indices.
r = mean(mod(pixFull - 1, mapH) + 1);
end

function c = meanCol(pixFull, mapH)
% Mean map column of a set of full-map linear indices.
c = mean(floor((pixFull - 1) / mapH) + 1);
end

function redrawCentroidScatter(figCent)
% Redraw the lesion-centroid scatter using the current slider settings.
S = getappdata(figCent, 'centData');
if isempty(S), return; end
ax = findobj(figCent, 'Type','axes', 'Tag','centAx');
if isempty(ax), return; end
ax = ax(1);

% Slider values (size multiplier and marker opacity)
hSz = findobj(figCent, 'Tag','sldCentSize');
hAl = findobj(figCent, 'Tag','sldCentAlpha');
sizeMult = 1;    if ~isempty(hSz), sizeMult = get(hSz(1),'Value'); end
alphaV   = 0.55; if ~isempty(hAl), alphaV   = get(hAl(1),'Value'); end
set(findobj(figCent,'Tag','txtCentSize'),  'String', sprintf('%.2f×', sizeMult));
set(findobj(figCent,'Tag','txtCentAlpha'), 'String', sprintf('%.2f',  alphaV));

% Lesion-size range filter (min/max size sliders)
hMn = findobj(figCent, 'Tag','sldCentMinVol');
hMx = findobj(figCent, 'Tag','sldCentMaxVol');
vLo = -inf;  vHi = inf;
if ~isempty(hMn), vLo = get(hMn(1),'Value'); end
if ~isempty(hMx), vHi = get(hMx(1),'Value'); end
if vLo > vHi, tmp = vLo;  vLo = vHi;  vHi = tmp; end
set(findobj(figCent,'Tag','txtCentMinVol'), 'String', sprintf('%.2f mm³', vLo));
set(findobj(figCent,'Tag','txtCentMaxVol'), 'String', sprintf('%.2f mm³', vHi));
inRange = S.vol >= vLo & S.vol <= vHi;

% Visibility toggles (Allen brain map + animal IDs)
onoff = {'Off','On'};
hMap = findobj(figCent, 'Tag','tglCentMap');
hIDs = findobj(figCent, 'Tag','tglCentIDs');
showMap = true;  if ~isempty(hMap), showMap = logical(get(hMap(1),'Value')); end
showIDs = true;  if ~isempty(hIDs), showIDs = logical(get(hIDs(1),'Value')); end
if ~isempty(hMap), set(hMap(1),'String',['Brain map: '  onoff{showMap+1}]); end
if ~isempty(hIDs), set(hIDs(1),'String',['Animal IDs: ' onoff{showIDs+1}]); end

% View mode: lesion centroids (default) or deficit-occurrence heatmap
hHM = findobj(figCent, 'Tag','tglCentHeatmap');
heatMode = false;  if ~isempty(hHM), heatMode = logical(get(hHM(1),'Value')); end
if ~isempty(hHM), set(hHM(1),'String',['Deficit map: ' onoff{heatMode+1}]); end

% Dual centroids: include/exclude multi-lesion animals in the deficit map
hDual = findobj(figCent, 'Tag','tglCentDual');
inclDual = true;  if ~isempty(hDual), inclDual = logical(get(hDual(1),'Value')); end
if ~isempty(hDual), set(hDual(1),'String',['Dual centroids: ' onoff{inclDual+1}]); end

% Coverage filter: when On, the deficit map shows only pixels covered by
% >= 2 lesions (hides single-lesion pixels).
hCov = findobj(figCent, 'Tag','tglCentMinCov');
covHi = false;  if ~isempty(hCov), covHi = logical(get(hCov(1),'Value')); end
if ~isempty(hCov), set(hCov(1),'String',['Pixel ≥2: ' onoff{covHi+1}]); end
minCov = 1;  if covHi, minCov = 2; end

% Region-selection contour-only mode: On when the "Select region" toggle is
% pressed and a selection has been stored. Overrides the scatter/heatmap
% views so only the selected contours are shown.
hSel = findobj(figCent, 'Tag','tglCentSelReg');
selOn = false;  if ~isempty(hSel), selOn = logical(get(hSel(1),'Value')); end
regionSel = getappdata(figCent, 'centRegionSel');
regionMode = selOn && ~isempty(regionSel);

% Selected symptom for marker color (dropdown) and stroke phase
hMet = findobj(figCent, 'Tag','popCentMetric');
hPh  = findobj(figCent, 'Tag','popCentPhase');
mi = 1;        if ~isempty(hMet), mi = round(get(hMet(1),'Value'));     end
phIdx = 1;     if ~isempty(hPh),  phIdx = round(get(hPh(1),'Value'));   end
if isfield(S,'metricMat3d') && ~isempty(S.metricMat3d)
    mi    = max(1, min(mi,    size(S.metricMat3d, 2)));
    phIdx = max(1, min(phIdx, size(S.metricMat3d, 3)));
    cval = S.metricMat3d(:, mi, phIdx).';
else
    cval = nan(1, numel(S.cx));
end
mname = 'metric';
if isfield(S,'metricNames') && mi >= 1 && numel(S.metricNames) >= mi
    mname = S.metricNames{mi};
end
phName = 'All';
if isfield(S,'phaseNames') && phIdx >= 1 && numel(S.phaseNames) >= phIdx
    phName = S.phaseNames{phIdx};
end

% Clear previous contents (children + any colorbar) but keep the axes
delete(allchild(ax));
delete(findobj(figCent, 'Type','colorbar'));
hold(ax, 'on'); axis(ax, 'equal'); axis(ax, 'off');

% Atlas background (flipped to match the lesion-map panel convention)
if showMap && ~isempty(S.Area_mapRGB)
    imagesc(ax, flipud(S.Area_mapRGB));
end
% Lock orientation/limits to the atlas frame so hiding the map doesn't
% shift the view. imagesc under hold-on leaves YDir = 'normal'; the atlas
% (flipud) and data (mapH+1-y) use that convention, so keep it explicit.
set(ax, 'YDir','normal');
if S.mapW > 0 && S.mapH > 0
    xlim(ax, [0.5, S.mapW + 0.5]);
    ylim(ax, [0.5, S.mapH + 0.5]);
end

% When the brain map is hidden, draw a 1 mm grid instead (100 px = 1 mm,
% same scale as the bar below), anchored on bregma.
if ~showMap && S.mapW > 0 && S.mapH > 0
    pxPerMM = 100;
    bx = 570;  by = S.mapH + 1 - 540;          % bregma in plot coords
    xl = [0.5, S.mapW + 0.5];  yl = [0.5, S.mapH + 0.5];
    xv = bx + (-floor((bx-xl(1))/pxPerMM) : floor((xl(2)-bx)/pxPerMM)) * pxPerMM;
    yv = by + (-floor((by-yl(1))/pxPerMM) : floor((yl(2)-by)/pxPerMM)) * pxPerMM;
    gC = [0.85 0.85 0.85];
    for xc = xv
        plot(ax, [xc xc], yl, '-', 'Color', gC, 'LineWidth', 0.5);
    end
    for yc = yv
        plot(ax, xl, [yc yc], '-', 'Color', gC, 'LineWidth', 0.5);
    end
end

if regionMode
    % ── Region-selection contour-only view ───────────────────────────────
    % centHighlightID is set by the linked "Region time course" figure's
    % Back/Next browse so the current animal's contour is drawn green.
    hlID = getappdata(figCent, 'centHighlightID');
    ttl = drawRegionContours(ax, S, regionSel, hlID);
elseif heatMode
    % ── Deficit-occurrence heatmap view ──────────────────────────────────
    ttl = drawDeficitOverlay(ax, S, mi, phIdx, vLo, vHi, inclDual, minCov);
    % Put the cluster outlines back if a stats run is on file for EXACTLY
    % these filters. Any change to the filters invalidates it, and the
    % outlines stay off until "Cluster stats" is pressed again — clusters
    % drawn over a map they were not computed from would be a lie.
    Rc = getappdata(figCent, 'centClusterR');
    if ~isempty(Rc) && isfield(Rc,'sig') && strcmp(Rc.sig, ...
            deficitStatsSignature(mi, phIdx, vLo, vHi, inclDual, minCov, ...
                                  deficitStatsOptsFromUI(figCent)))
        drawDeficitClusters(ax, Rc);
        ttl = sprintf('%s\n%s', ttl, deficitClusterTitleLine(Rc));
    end
else
% ── Lesion-centroid scatter view ─────────────────────────────────────────
% Marker area ∝ lesion volume, scaled by the size slider
sz       = max(6, sizeMult * S.sScale * S.vol);
edgeAlph = min(1, alphaV + 0.25);   % keep outlines a touch crisper than fills

% Color = total post-infarction value of the selected symptom; markers
% with no post-infarction data for it are drawn gray. Only lesions whose
% size is within the min/max-size slider range are shown. Markers from
% animals with more than one lesion get a red edge to flag them.
[~, ~, ic] = unique(S.ids);
isMultiAll = reshape(accumarray(ic(:), 1) > 1, [], 1);
isMultiAll = reshape(isMultiAll(ic), 1, []);   % per-marker, S.ids order
MULTI_EDGE = [0.85 0.10 0.10];

% Honor the "Dual centroids" toggle here too, with the same rule the deficit
% map uses: when Off, drop every lesion from an animal with >1 lesion so the
% scatter shows the same single-lesion cohort the map is computed from
% (previously the red-edged multi-lesion markers stayed on screen).
nDual = 0;
if ~inclDual
    nDual   = sum(inRange & isMultiAll);
    inRange = inRange & ~isMultiAll;
end

selC  = (~isnan(cval)) & inRange;     % colored (have metric data)
selG  = ( isnan(cval)) & inRange;     % gray (no metric data)
selCs = selC & ~isMultiAll;           % single-lesion, colored
selCm = selC &  isMultiAll;           % multi-lesion,  colored
selGs = selG & ~isMultiAll;           % single-lesion, gray
selGm = selG &  isMultiAll;           % multi-lesion,  gray

if any(selC)
    % Keep the color convention "yellower = more deficit" consistent across
    % metrics. "Regular hold" is the only metric where higher = better
    % performance (not a deficit index), so flip the colormap for it: low
    % hold time -> yellow, long hold time -> blue. The colorbar ticks still
    % run low->high; only the value-to-color mapping inverts.
    if strcmpi(mname, 'Regular hold')
        colormap(ax, flipud(parula));
    else
        colormap(ax, parula);
    end
    cb = colorbar(ax);
    if phIdx == 1
        cb.Label.String = sprintf('Mean post-infarction %s', lower(mname));
    else
        cb.Label.String = sprintf('Mean %s %s', phName, lower(mname));
    end
    % Fixed color scale per metric spanning ALL phases (not just the current
    % view). Otherwise each phase re-normalized to its own min/max, so a mild
    % residual deficit in Chronic — where most animals have recovered or have
    % no sessions — floated to the top of the local scale and rendered as
    % bright as a genuinely severe acute deficit. Anchoring to the whole-metric
    % range keeps color == absolute deficit magnitude, comparable across phases.
    slab = S.metricMat3d(:, mi, :);
    slab = slab(isfinite(slab));
    if numel(unique(slab)) > 1
        clim(ax, [min(slab) max(slab)]);
    elseif numel(unique(cval(selC))) > 1
        clim(ax, [min(cval(selC)) max(cval(selC))]);
    end
end
if any(selCs)
    scatter(ax, S.cx(selCs), S.cyF(selCs), sz(selCs), cval(selCs), 'filled', ...
        'MarkerFaceAlpha', alphaV, 'MarkerEdgeAlpha', edgeAlph, ...
        'MarkerEdgeColor', 'k', 'LineWidth', 0.75);
end
if any(selCm)
    scatter(ax, S.cx(selCm), S.cyF(selCm), sz(selCm), cval(selCm), 'filled', ...
        'MarkerFaceAlpha', alphaV, 'MarkerEdgeAlpha', 1, ...
        'MarkerEdgeColor', MULTI_EDGE, 'LineWidth', 1.2);
end
if any(selGs)
    scatter(ax, S.cx(selGs), S.cyF(selGs), sz(selGs), [0.6 0.6 0.6], 'filled', ...
        'MarkerFaceAlpha', alphaV, 'MarkerEdgeAlpha', edgeAlph, ...
        'MarkerEdgeColor', 'k', 'LineWidth', 0.75);
end
if any(selGm)
    scatter(ax, S.cx(selGm), S.cyF(selGm), sz(selGm), [0.6 0.6 0.6], 'filled', ...
        'MarkerFaceAlpha', alphaV, 'MarkerEdgeAlpha', 1, ...
        'MarkerEdgeColor', MULTI_EDGE, 'LineWidth', 1.2);
end

% Animal ID labels (toggleable) — only for the lesions currently shown
if showIDs
    for k = find(inRange)
        text(ax, S.cx(k) + 8, S.cyF(k), S.ids{k}, 'FontSize', 8, 'Color', 'k', ...
            'Clipping', 'on');
    end
end

% Size legend (reference volumes, upper-left) — reflects the shown range
vShown = S.vol(inRange);
if isempty(vShown), vShown = S.vol; end
vref = unique(round([min(vShown), median(vShown), max(vShown)], 2));
xL = 70;  yL0 = S.mapH + 1 - 60;
for k = 1:numel(vref)
    yk = yL0 - (k-1) * 42;
    scatter(ax, xL, yk, max(6, sizeMult * S.sScale * vref(k)), [1 1 1], ...
        'MarkerEdgeColor', 'k', 'LineWidth', 0.75);
    text(ax, xL + 45, yk, sprintf('%.2f mm³', vref(k)), ...
        'FontSize', 8, 'Color', 'k');
end

nShown = sum(inRange);
nTot   = numel(S.cx);
nNoFC  = sum(selG);
if nShown < nTot
    ttl = sprintf('Lesion centroids — %d of %d lesions (size %.2f–%.2f mm³)', ...
                  nShown, nTot, vLo, vHi);
else
    nAniShown = nTot;
    if isfield(S,'nAni'), nAniShown = S.nAni; end
    ttl = sprintf('Lesion centroids — %d lesions from %d infarction animals', ...
                  nTot, nAniShown);
end
if nNoFC > 0
    if phIdx == 1
        ttl = sprintf('%s  (%d gray = no post-infarction %s)', ttl, nNoFC, lower(mname));
    else
        ttl = sprintf('%s  (%d gray = no %s %s)', ttl, nNoFC, phName, lower(mname));
    end
end
if any(isMultiAll & inRange)
    ttl = sprintf('%s  (red edge = animal with multiple lesions)', ttl);
end
if nDual > 0
    ttl = sprintf('%s  (%d lesions hidden: dual centroids off)', ttl, nDual);
end
end   % end of centroid-view branch

% Bregma marker + 1 mm scale bar (common to both views)
plot(ax, 570, S.mapH + 1 - 540, 'k+', 'MarkerSize', 12, 'LineWidth', 1.5);
plot(ax, [100, 200], (S.mapH + 1 - 740) * [1 1], 'k-', 'LineWidth', 2);
text(ax, 150, S.mapH + 1 - 760, '1 mm', 'HorizontalAlignment','center', ...
    'FontSize', 8, 'Color', 'k');

title(ax, ttl, 'FontSize', 10);
end

function onCentShapeChange(figCent)
% Swap the In/Out defaults when the selection shape changes: Circle uses
% inner/outer DIAMETERS (300/600 µm), Line uses inner/outer corridor WIDTHS
% (100/800 µm). Keeps the boxes at sensible per-shape defaults.
hShape = findobj(figCent, 'Tag','popCentShape');
if isempty(hShape), return; end
strs = get(hShape(1),'String');
vi   = round(get(hShape(1),'Value'));
isLine = iscell(strs) && vi >= 1 && vi <= numel(strs) ...
    && strcmpi(strtrim(strs{vi}), 'Line');
if isLine
    inDef = '100';  outDef = '800';
else
    inDef = '300';  outDef = '600';
end
hIn  = findobj(figCent, 'Tag','edCentDiam');
hOut = findobj(figCent, 'Tag','edSurDiam');
if ~isempty(hIn),  set(hIn(1),  'String', inDef);  end
if ~isempty(hOut), set(hOut(1), 'String', outDef); end
end

function onCentSizeChange(figCent)
% Min/Max size sliders, on release: normal redraw, plus — while a "Select
% region" selection is on file — live-refresh the linked Region+Surround
% companion figures against the new size range.
refreshRegionSelectionLive(figCent);
redrawCentroidScatter(figCent);
end

function onCentSizeChangeLive(figCent)
% Min/Max size sliders, on every drag tick: normal scatter redraw, plus a
% live refresh of just the (cheap) linked lesion-volume bar chart. See
% refreshRegionSelectionLive for the release-only refresh that also updates
% the linked time-course figure (too expensive — full ANOVA/LME — to re-run
% on every tick).
refreshRegionVolumeLive(figCent);
redrawCentroidScatter(figCent);
end

function [ok, S, selIDs, surIDs, vLo, vHi, volReg, volSur, volStr] = regionVolumeState(figCent)
% Shared by refreshRegionSelectionLive (on release) and refreshRegionVolumeLive
% (every drag tick): current Min/Max range, the Region/Surround GROUP
% MEMBERSHIP fixed by the original "Select region" click (sel.selIDs /
% sel.surIDs) — never changes afterward — and each member's total lesion
% volume against the CURRENT range, plus the resulting volume-match string.
% ok=false (toggle Off / nothing selected / no data) means both callers
% should no-op.
ok = false;  S = [];  selIDs = {};  surIDs = {};
vLo = -inf;  vHi = inf;  volReg = [];  volSur = [];  volStr = '';
hTgl = findobj(figCent, 'Tag','tglCentSelReg');
if isempty(hTgl) || ~logical(get(hTgl(1),'Value')), return; end
sel = getappdata(figCent, 'centRegionSel');
if isempty(sel) || ~isfield(sel,'inSel'), return; end
S = getappdata(figCent, 'centData');
if isempty(S), return; end

hMn = findobj(figCent, 'Tag','sldCentMinVol');
hMx = findobj(figCent, 'Tag','sldCentMaxVol');
if ~isempty(hMn), vLo = get(hMn(1),'Value'); end
if ~isempty(hMx), vHi = get(hMx(1),'Value'); end
if vLo > vHi, tmp = vLo;  vLo = vHi;  vHi = tmp; end

% Derived from sel.inSel/inSur (present since the very first "Select
% region" implementation) rather than sel.selIDs/surIDs, so this keeps
% working even against a selection made before selIDs/surIDs started being
% stored — an already-open Lesion Centroids figure from an older session
% would otherwise silently no-op here on every slider move.
if isfield(sel,'selIDs') && isfield(sel,'surIDs')
    selIDs = sel.selIDs;  surIDs = sel.surIDs;
else
    selIDs = unique(S.ids(sel.inSel));
    surIDs = unique(S.ids(sel.inSur));
end
volReg = animalTotalLesionVol(S, selIDs);
volSur = animalTotalLesionVol(S, surIDs);
if sel.hasSurround && ~isempty(surIDs)
    volStr = lesionVolumeCompareStr(S, selIDs, 'Region', surIDs, 'Surround', vLo, vHi);
end
ok = true;
end

function refreshRegionVolumeLive(figCent)
% Cheap half of refreshRegionSelectionLive, safe to call on every Min/Max
% slider drag tick: redraws only the linked lesion-volume bar chart against
% the current range. Does not touch the linked time-course figure (see
% refreshRegionSelectionLive for that, on release only).
[ok, ~, ~, ~, vLo, vHi, volReg, volSur, volStr] = regionVolumeState(figCent);
if ~ok, return; end
figHist = getappdata(figCent, 'centLinkedVolFig');
if ~isempty(figHist) && isgraphics(figHist, 'figure') && ~isempty(volStr)
    drawLesionVolumeBarPlot(figHist, volReg, 'Region', volSur, 'Surround', volStr, vLo, vHi);
end
end

function refreshRegionSelectionLive(figCent)
% Called when the Min/Max size sliders change (on release). The Region and
% Surround GROUP MEMBERSHIP is fixed by the original click (sel.selIDs /
% sel.surIDs) and never changes afterward — only which of those animals
% count as "in range" does, judged by each animal's own total lesion volume
% against the CURRENT Min/Max range. That in-range subset is pushed to any
% still-open Region+Surround companion figures: the time-course figure's
% Region/Surround membership is restricted to it, while the lesion-volume
% figure keeps every originally selected animal and just redraws the
% out-of-range ones as open circles (drawLesionVolumeBarPlot) — so moving
% the sliders never makes a point disappear, only recolors it and updates
% the group median. A no-op when the toggle is Off or nothing is selected.
[ok, S, selIDs, surIDs, vLo, vHi, volReg, volSur, volStr] = regionVolumeState(figCent);
if ~ok, return; end
BehData = getappdata(figCent, 'BehData');
if isempty(BehData), return; end

regInThr = volReg >= vLo & volReg <= vHi;
surInThr = volSur >= vLo & volSur <= vHi;
infMask = strcmp({BehData.Group}, 'Infarction') & ismember({BehData.ID}, selIDs(regInThr));
surMask = strcmp({BehData.Group}, 'Infarction') & ismember({BehData.ID}, surIDs(surInThr));

figNew = getappdata(figCent, 'centLinkedTCFig');
if ~isempty(figNew) && isgraphics(figNew, 'figure')
    filterStr = getappdata(figCent, 'centLinkedFilterStr');
    StdPOD    = getappdata(figCent, 'StdPOD');
    drawPopulationFigure(BehData, figNew, StdPOD, {}, [], false, [], 'original', ...
        infMask, filterStr, surMask, 'Surround');
    set(figNew, 'Name', sprintf('Region+Surround time course (Region n=%d, Surround n=%d)', ...
        sum(infMask), sum(surMask)));
    setappdata(figNew, 'tcInfMask', infMask | surMask);
    if ~isempty(volStr)
        appendVolumeMatchTitle(figNew, volStr);
    end
end

figHist = getappdata(figCent, 'centLinkedVolFig');
if ~isempty(figHist) && isgraphics(figHist, 'figure') && ~isempty(volStr)
    drawLesionVolumeBarPlot(figHist, volReg, 'Region', volSur, 'Surround', volStr, vLo, vHi);
end
if ~isempty(volStr)
    fprintf('%s\n', volStr);
end
end

function selectCentroidRegion(figCent)
% "Select region" toggle on the Lesion Centroids figure.
%   Toggle On  → prompt for a centre click, place a circle of the diameter
%                (µm) from the edit box (100 px = 1 mm, so 1 px = 10 µm),
%                select every lesion whose AREA (top-view polygon) overlaps
%                it within the current Min/Max size range, switch the axes to
%                a clean contour-only view (circle + selected lesion outlines
%                over the brain map, no scatter/heatmap clutter), and open a
%                "Days post-infarction vs Deficits" time-course figure for the
%                matching animals (same drawPopulationFigure path as the
%                M1/M2/S1 figure's "Time course" button) with a "Lesion map"
%                companion button.
%   Toggle Off → clear the selection and restore the normal scatter/heatmap.
% Area overlap (not centroid-in-circle) is used so the count matches the
% deficit heatmap's per-pixel coverage: a pixel covered by N animals' lesion
% areas selects those N animals, even when their centroids sit outside.
onoff = {'Off','On'};
hTgl  = findobj(figCent, 'Tag','tglCentSelReg');
isOn  = true;
if ~isempty(hTgl), isOn = logical(get(hTgl(1),'Value')); end
if ~isempty(hTgl), set(hTgl(1), 'String', ['Select region: ' onoff{isOn+1}]); end

% Toggle turned Off → drop contour-only mode, unlink the companion figures
% (so a later Min/Max drag has nothing stale to push updates into), and
% repaint the normal view.
if ~isOn
    setappdata(figCent, 'centRegionSel', []);
    setappdata(figCent, 'centLinkedTCFig',  []);
    setappdata(figCent, 'centLinkedVolFig', []);
    redrawCentroidScatter(figCent);
    return
end

S = getappdata(figCent, 'centData');
if isempty(S) || ~isfield(S,'cx') || isempty(S.cx)
    warning('LeverPullTask:noCentData', ...
        'Select region: no lesion-centroid data — reopen Lesion Centroids.');
    resetSelToggle(hTgl);  return
end
BehData = getappdata(figCent, 'BehData');
StdPOD  = getappdata(figCent, 'StdPOD');
if isempty(BehData) || isempty(StdPOD)
    warning('LeverPullTask:noBehData', ...
        'Select region: BehData/StdPOD not found — reopen Lesion Centroids.');
    resetSelToggle(hTgl);  return
end

% Diameter (µm) from the edit box → radius in atlas pixels (100 px = 1 mm).
PX_PER_MM = 100;
diamUM = 300;
hEd = findobj(figCent, 'Tag','edCentDiam');
if ~isempty(hEd)
    v = str2double(get(hEd(1),'String'));
    if isfinite(v) && v > 0
        diamUM = v;
    else
        set(hEd(1), 'String', '300');   % restore a sane value on bad input
    end
end
radPx = (diamUM/1000) * PX_PER_MM / 2;

% Outer size (µm) of the surrounding zone from its edit box. The surround set
% = lesions overlapping the zone between the inner region and this outer bound
% that do NOT overlap the inner region. surUM <= diamUM (or <= 0) disables it.
surUM = 2 * diamUM;
hSur = findobj(figCent, 'Tag','edSurDiam');
if ~isempty(hSur)
    v = str2double(get(hSur(1),'String'));
    if isfinite(v) && v > 0
        surUM = v;
    else
        set(hSur(1), 'String', sprintf('%g', 2*diamUM));   % restore sane value
        surUM = 2 * diamUM;
    end
end
outRadPx = (surUM/1000) * PX_PER_MM / 2;

% Selection shape from the shape popup: 'circle' (default) or 'line'. Circle
% uses diamUM/surUM as inner/outer DIAMETERS; line uses them as the inner/outer
% corridor WIDTHS (a thick line segment of the given width).
selShape = 'circle';
hShape = findobj(figCent, 'Tag','popCentShape');
if ~isempty(hShape)
    strs = get(hShape(1),'String');
    vi   = round(get(hShape(1),'Value'));
    if iscell(strs) && vi >= 1 && vi <= numel(strs)
        selShape = lower(strtrim(strs{vi}));
    end
end
isLine   = strcmp(selShape, 'line');
widthPx  = (diamUM/1000) * PX_PER_MM;      % full corridor width  (line mode)
outWidPx = (surUM/1000)  * PX_PER_MM;      % full outer width     (line mode)
if isLine
    hasSurround = outWidPx > widthPx;
else
    hasSurround = outRadPx > radPx;
end

ax = findobj(figCent, 'Type','axes', 'Tag','centAx');
if isempty(ax), resetSelToggle(hTgl);  return; end
ax = ax(1);

% Prompt for the selection geometry inside the atlas axes. Line endpoints
% default to 0 (unused/stored as-is in circle mode); xc/yc are set in both
% branches (ginput centre, or the segment midpoint).
x1 = 0; y1 = 0; x2 = 0; y2 = 0;
if isLine
    title(ax, sprintf('Click the two endpoints of the %g µm-wide line…', diamUM), ...
          'FontSize', 10, 'Color', [0.6 0 0]);
    [xL, yL] = ginput(2);
    if numel(xL) < 2
        resetSelToggle(hTgl);  redrawCentroidScatter(figCent);  return
    end
    x1 = xL(1);  y1 = yL(1);  x2 = xL(2);  y2 = yL(2);
    xc = (x1 + x2) / 2;  yc = (y1 + y2) / 2;   % midpoint for AP/LR labels
else
    title(ax, sprintf('Click the centre of the %g µm region…', diamUM), ...
          'FontSize', 10, 'Color', [0.6 0 0]);
    [xc, yc] = ginput(1);
    if isempty(xc)
        % Cancelled (Enter/Esc) — pop the toggle back off and restore the view.
        resetSelToggle(hTgl);
        redrawCentroidScatter(figCent);
        return
    end
end

% Size-range filter (Min/Max sliders) so the selection matches what's shown.
% Stashed on `sel` (below) and re-read live by refreshRegionSelectionLive
% whenever these sliders move afterward, so tightening/loosening the range
% doesn't require re-clicking the region.
hMn = findobj(figCent, 'Tag','sldCentMinVol');
hMx = findobj(figCent, 'Tag','sldCentMaxVol');
vLo = -inf;  vHi = inf;
if ~isempty(hMn), vLo = get(hMn(1),'Value'); end
if ~isempty(hMx), vHi = get(hMx(1),'Value'); end
if vLo > vHi, tmp = vLo;  vLo = vHi;  vHi = tmp; end

% Honor the "Dual centroids" toggle, exactly as the deficit heatmap does:
% when Off, drop lesions from animals with >1 lesion (multi-centroid) so the
% selection can't pull in dual-lesion animals.
hDual = findobj(figCent, 'Tag','tglCentDual');
inclDual = true;
if ~isempty(hDual), inclDual = logical(get(hDual(1),'Value')); end

% Line-shape drawing outlines (plot coords) — purely geometric, independent
% of the size range, so computed once here and never touched again.
innerPolyPlot = [];  outerPolyPlot = [];
if isLine
    p1 = [x1, S.mapH + 1 - y1];  p2 = [x2, S.mapH + 1 - y2];
    innerPolyOrig = corridorRect(p1, p2, widthPx/2);
    innerPolyPlot = [innerPolyOrig(:,1), S.mapH + 1 - innerPolyOrig(:,2)];
    if hasSurround
        outerPolyOrig = corridorRect(p1, p2, outWidPx/2);
        outerPolyPlot = [outerPolyOrig(:,1), S.mapH + 1 - outerPolyOrig(:,2)];
    end
end

% AP/LR of the region centre (mm from bregma) for the labels.
bx = 570;  by = S.mapH + 1 - 540;
AP_mm = (yc - by) / PX_PER_MM;
LR_mm = (xc - bx) / PX_PER_MM;

% Selection geometry (independent of the size range) — kept in appdata so
% refreshRegionSelectionLive can re-run the overlap test below against a
% later size range without re-prompting for a click.
sel = struct('shape',selShape, 'xc',xc, 'yc',yc, 'radPx',radPx, 'diamUM',diamUM, ...
             'AP',AP_mm, 'LR',LR_mm, 'outRadPx',outRadPx, 'surUM',surUM, ...
             'hasSurround',hasSurround, 'x1',x1, 'y1',y1, 'x2',x2, 'y2',y2, ...
             'widthPx',widthPx, 'outWidPx',outWidPx, ...
             'innerPoly',innerPolyPlot, 'outerPoly',outerPolyPlot);

% Overlap test (see computeRegionMasks): which lesions/animals fall inside
% the inner region ("Region" group) and, if enabled, the surrounding zone
% ("Surround" group) — restricted to lesions within [vLo, vHi].
[inSel, inSur, selIDs, surIDs, infMask, surMask] = ...
    computeRegionMasks(S, BehData, sel, vLo, vHi, inclDual);

% Stash the selection (now complete) so redrawCentroidScatter can render the
% contour-only view (and keep it across slider redraws while the toggle
% stays On). selIDs/surIDs is the FIXED Region/Surround membership: later
% Min/Max moves (refreshRegionSelectionLive) only reclassify these same
% animals in/out of range — they never add or drop an animal.
sel.inSel = inSel;  sel.inSur = inSur;
sel.selIDs = selIDs;  sel.surIDs = surIDs;
sel.nAni  = sum(infMask);  sel.nSur = sum(surMask);
setappdata(figCent, 'centRegionSel', sel);
redrawCentroidScatter(figCent);   % draw the contour-only view now

% Shape-aware descriptor used in figure names / titles.
if isLine
    shapeStr = sprintf('%g µm line @ AP %+.2f, LR %+.2f mm', diamUM, AP_mm, LR_mm);
else
    shapeStr = sprintf('%g µm circle @ AP %+.2f, LR %+.2f mm', diamUM, AP_mm, LR_mm);
end

if isempty(selIDs) || ~any(infMask)
    warning('LeverPullTask:emptyRegion', ...
        'Select region: no lesion areas overlap the %s.', shapeStr);
    if ~(hasSurround && any(surMask))
        return   % nothing inner AND nothing surrounding → nothing to plot
    end
end

% ── Combined time-course figure: Region + Surround overlaid (plus Sham) ────
% A single figure draws the inner-region animals ("Region", red) and the
% surround animals ("Surround", orange) on the same axes via the overlay path
% of drawPopulationFigure, instead of the two separate figures used before.
ccfRoot = getappdata(figCent, 'CCF_root_beh');
if isLine
    filterStr = sprintf('Region+Surround (line): %s', shapeStr);
else
    filterStr = sprintf('Region+Surround: %s', shapeStr);
end
figNew = figure('Name', ...
    sprintf('Region+Surround time course (Region n=%d, Surround n=%d)', ...
        sum(infMask), sum(surMask)), ...
    'Position', [140 90 1150 840]);
% Link back to this Lesion Centroids figure so Back/Next recolors the current
% animal's contour here. Set BEFORE drawPopulationFigure so the first
% highlightAnimalInPop already syncs.
setappdata(figNew, 'srcFigCent', figCent);
drawPopulationFigure(BehData, figNew, StdPOD, {}, [], false, [], 'original', ...
    infMask, filterStr, surMask, 'Surround');

% Volume-match check: confirm the Region and Surround groups don't differ in
% total per-animal lesion volume, so a deficit difference between them can't
% just be a lesion-size confound. Appended to the population figure's own
% title (not a separate figure) so it travels with "Apply marks to plot".
figHist = [];
if hasSurround && any(surMask)
    [volStr, volReg, volSur] = lesionVolumeCompareStr(S, selIDs, 'Region', surIDs, 'Surround', vLo, vHi);
    appendVolumeMatchTitle(figNew, volStr);
    fprintf('%s\n', volStr);
    figHist = openLesionVolumeHistFigure(volReg, 'Region', volSur, 'Surround', volStr, vLo, vHi);
end

% Link this Lesion Centroids figure to its Region+Surround companions so
% refreshRegionSelectionLive (Min/Max sliders, on release) can push updated
% masks/thresholds into them without re-clicking the region.
setappdata(figCent, 'centLinkedTCFig',    figNew);
setappdata(figCent, 'centLinkedVolFig',   figHist);
setappdata(figCent, 'centLinkedFilterStr', filterStr);

% "Lesion map" companion button (shows both sets via the contour view).
setappdata(figNew, 'BehData',      BehData);
setappdata(figNew, 'CCF_root_beh', ccfRoot);
setappdata(figNew, 'tcInfMask',    infMask | surMask);
setappdata(figNew, 'tcFilterStr',  filterStr);
setappdata(figNew, 'tcLabel',      shapeStr);
uicontrol(figNew, 'Style','pushbutton', 'String','Lesion map', ...
    'Units','normalized', 'Position',[0.86 0.005 0.13 0.03], ...
    'FontSize',9, 'Tag','btnTCLesionMap', ...
    'Callback', @(~,~) tcOpenLesionMap(figNew));

fprintf('Region select (%s): %s captured %d lesions from %d animals: %s\n', ...
    selShape, shapeStr, sum(inSel), numel(selIDs), strjoin(selIDs, ', '));
if hasSurround
    fprintf('Surround: outer %g µm captured %d lesions from %d animals: %s\n', ...
        surUM, sum(inSur), numel(surIDs), strjoin(surIDs, ', '));
end
end

function poly = corridorRect(p1, p2, half)
% Rectangle (4 corners, closed by the caller/poly2mask) covering a corridor of
% half-width `half` around the segment p1→p2. Both points are [x y] in the same
% frame; the rectangle spans the segment length and 2*half across it. A
% degenerate (zero-length) segment falls back to a horizontal axis.
d = p2 - p1;
L = hypot(d(1), d(2));
if L < eps
    u = [1 0];
else
    u = d / L;
end
n = [-u(2), u(1)];               % unit normal
poly = [p1 + n*half; p2 + n*half; p2 - n*half; p1 - n*half];
end

function [inSel, inSur, selIDs, surIDs, infMask, surMask] = ...
    computeRegionMasks(S, BehData, sel, vLo, vHi, inclDual)
% Re-run the "Select region" geometric overlap test — which lesions fall
% inside the inner region ("Region" group) and, if enabled, the surrounding
% zone ("Surround" group) — against a given [vLo, vHi] size range, using the
% selection geometry already stored in `sel` (shape/xc/yc/radPx/outRadPx or
% x1/y1/x2/y2/widthPx/outWidPx). Shared by the initial click in
% selectCentroidRegion and by refreshRegionSelectionLive (Min/Max sliders,
% after the click) so tightening/loosening the size range doesn't require
% re-clicking the region. See selectCentroidRegion for the frame-convention
% notes (clicks are in flipped plot coords; masks are built in the original
% atlas frame, matching the deficit heatmap's per-pixel coverage).
isLine      = strcmp(sel.shape, 'line');
hasSurround = sel.hasSurround;

inRange = S.vol >= vLo & S.vol <= vHi;
if ~inclDual
    [~, ~, ic] = unique(S.ids);
    isMultiAll = reshape(accumarray(ic(:), 1) > 1, [], 1);
    isMultiAll = reshape(isMultiAll(ic), 1, []);   % per-marker, S.ids order
    inRange = inRange & ~isMultiAll;
end

[gx, gy] = meshgrid(1:S.mapW, 1:S.mapH);
if isLine
    p1 = [sel.x1, S.mapH + 1 - sel.y1];  p2 = [sel.x2, S.mapH + 1 - sel.y2];
    innerPolyOrig = corridorRect(p1, p2, sel.widthPx/2);
    innerMask = poly2mask(innerPolyOrig(:,1), innerPolyOrig(:,2), S.mapH, S.mapW);
    if hasSurround
        outerPolyOrig = corridorRect(p1, p2, sel.outWidPx/2);
        outerMask = poly2mask(outerPolyOrig(:,1), outerPolyOrig(:,2), S.mapH, S.mapW);
        annMask   = outerMask & ~innerMask;
    else
        annMask = false(S.mapH, S.mapW);
    end
else
    ycOrig   = S.mapH + 1 - sel.yc;
    dist2    = (gx - sel.xc).^2 + (gy - ycOrig).^2;
    innerMask = dist2 <= sel.radPx^2;
    if hasSurround
        annMask = (dist2 <= sel.outRadPx^2) & (dist2 > sel.radPx^2);
    else
        annMask = false(S.mapH, S.mapW);
    end
end

inSel = false(1, numel(S.cx));
inSur = false(1, numel(S.cx));
if isfield(S,'polyPts') && ~isempty(S.polyPts)
    for k = 1:numel(S.cx)
        if ~inRange(k), continue; end
        pts = S.polyPts{k};
        if isempty(pts), continue; end
        lm = poly2mask(pts(:,1), pts(:,2), S.mapH, S.mapW);
        inInner = any(lm(:) & innerMask(:));
        inSel(k) = inInner;
        if hasSurround && ~inInner
            inSur(k) = any(lm(:) & annMask(:));
        end
    end
else
    % No polygons cached: sample the masks at each centroid pixel (older data).
    cxr = round(S.cx(:).');
    cyr = round(S.mapH + 1 - S.cyF(:).');   % original-frame y of the centroid
    for k = 1:numel(S.cx)
        if ~inRange(k), continue; end
        if cxr(k) < 1 || cxr(k) > S.mapW || cyr(k) < 1 || cyr(k) > S.mapH, continue; end
        if innerMask(cyr(k), cxr(k))
            inSel(k) = true;
        elseif hasSurround && annMask(cyr(k), cxr(k))
            inSur(k) = true;
        end
    end
end
selIDs = unique(S.ids(inSel));
surIDs = unique(S.ids(inSur));
infMask = strcmp({BehData.Group}, 'Infarction') & ismember({BehData.ID}, selIDs);
surMask = strcmp({BehData.Group}, 'Infarction') & ismember({BehData.ID}, surIDs);
end

function appendVolumeMatchTitle(figNew, volStr)
% Append the Region-vs-Surround volume-match line to a population figure's
% own title (popTitleLine1), so it survives "Apply marks to plot" title
% rebuilds and any later drawPopulationFigure redraw (refreshRegionSelectionLive
% re-appends it after each such redraw, since drawPopulationFigure resets
% popTitleLine1 from scratch).
line1 = getappdata(figNew, 'popTitleLine1');
if isempty(line1), return; end
setappdata(figNew, 'popTitleLine1', sprintf('%s\n%s', line1, volStr));
popStats = getappdata(figNew, 'popStats');
spec     = getappdata(figNew, 'popMarkSpec');
if ~isempty(popStats) && ~isempty(spec)
    setPopMarkTitle(figNew, spec, popStats.k_holm);
end
end

function [str, volA, volB] = lesionVolumeCompareStr(S, idsA, labelA, idsB, labelB, vLo, vHi)
% Wilcoxon rank-sum comparison of TOTAL per-animal lesion volume (mm³,
% summed across all of that animal's sub-lesions in the centroid data S)
% between two animal-ID lists — e.g. the Region vs Surround groups from
% "Select region". Used to confirm the two groups are volume-matched before
% attributing a behavioral difference between them to lesion location rather
% than lesion size. Also returns the per-animal volume vectors (volA, volB,
% UNFILTERED — every originally selected animal) so the caller can plot them
% (e.g. the volume-match figure, which needs the full set to draw open
% circles for the ones outside [vLo, vHi]).
%
% The reported mean/SD/p-value, however, are computed on just the animals
% CURRENTLY inside [vLo, vHi] (default: no limit), so this text tracks the
% Lesion Centroids Min/Max sliders exactly like the bar figure's median —
% refreshRegionSelectionLive re-calls this on every slider release.
if nargin < 6 || isempty(vLo), vLo = -inf; end
if nargin < 7 || isempty(vHi), vHi = inf;  end
volA = animalTotalLesionVol(S, idsA);
volB = animalTotalLesionVol(S, idsB);
volAThr = volA(volA >= vLo & volA <= vHi);
volBThr = volB(volB >= vLo & volB <= vHi);
if numel(volAThr) >= 2 && numel(volBThr) >= 2
    p = ranksum(volAThr, volBThr);
    pStr = sprintf('p=%.3f (ranksum)', p);
else
    pStr = 'p=n/a (n<2)';
end
muA = NaN;  if ~isempty(volAThr), muA = mean(volAThr); end
muB = NaN;  if ~isempty(volBThr), muB = mean(volBThr); end
sdA = 0;    if numel(volAThr) >= 2, sdA = std(volAThr); end
sdB = 0;    if numel(volBThr) >= 2, sdB = std(volBThr); end
rangeStr = '';
if isfinite(vLo) || isfinite(vHi)
    rangeStr = sprintf(' (%.2f-%.2f mm³ range)', vLo, vHi);
end
str = sprintf(['Volume match check%s — %s %.3f\x00B1%.3f mm³ (n=%d) vs %s ' ...
               '%.3f\x00B1%.3f mm³ (n=%d): %s'], ...
    rangeStr, labelA, muA, sdA, numel(volAThr), labelB, muB, sdB, numel(volBThr), pStr);
end

function figHist = openLesionVolumeHistFigure(volA, labelA, volB, labelB, volStr, vLo, vHi)
% Creates the Region-vs-Surround lesion-volume companion figure and draws
% its first frame. See drawLesionVolumeBarPlot for the plot itself and for
% how it's refreshed in place when the Lesion Centroids Min/Max sliders
% move afterward.
if nargin < 6, vLo = -inf; end
if nargin < 7, vHi = inf;  end
figHist = figure('Name', sprintf('Lesion volume — %s vs %s', labelA, labelB), ...
    'Position', [900 850 480 420]);
drawLesionVolumeBarPlot(figHist, volA, labelA, volB, labelB, volStr, vLo, vHi);
end

function drawLesionVolumeBarPlot(figHist, volA, labelA, volB, labelB, volStr, vLo, vHi)
% (Re)draws the Region vs Surround lesion-volume panel into figHist in
% place (no new figure): one bar per group at the MEAN (whiskers = ±SD) of
% that group's animals currently inside the Lesion Centroids Min/Max size
% range [vLo, vHi], every animal's own total lesion volume overlaid as a
% jittered dot — filled when inside that range, open (hollow) when outside
% it, so moving the Min/Max sliders after "Select region" visibly
% excludes/restores points and updates the mean/whiskers without needing
% a new figure. Colors match Region=red / Surround=blue used throughout the
% Region+Surround time-course figure (cInf/cOvl there).
if nargin < 7 || isempty(vLo), vLo = -inf; end
if nargin < 8 || isempty(vHi), vHi = inf;  end
cA = [0.85, 0.15, 0.15];   % Region
cB = [0.00, 0.35, 0.85];   % Surround

hAx = findobj(figHist, 'Type','axes');
if isempty(hAx)
    ax = axes('Parent', figHist);
else
    ax = hAx(1);
    cla(ax);
end
axis(ax, 'on');
hold(ax, 'on');
if isempty(volA) && isempty(volB)
    text(ax, 0.5, 0.5, 'No lesion volumes to show', 'Units','normalized', ...
        'HorizontalAlignment','center', 'FontSize', 11);
    axis(ax, 'off');
    return
end

groups = {volA(:), volB(:)};
colors = {cA, cB};
JITTER = 0.12;
for g = 1:2
    v = groups{g};
    n = numel(v);
    if n == 0, continue; end
    inThr = v >= vLo & v <= vHi;
    if any(inThr)
        vThr = v(inThr);
        mu   = mean(vThr);
        bar(ax, g, mu, 0.6, 'FaceColor', colors{g}, 'FaceAlpha', 0.35, ...
            'EdgeColor', colors{g}, 'LineWidth', 1.5);
        if numel(vThr) > 1
            sd = std(vThr);
            errorbar(ax, g, mu, sd, sd, 'Color', 'k', ...
                'LineWidth', 1.2, 'CapSize', 10, 'LineStyle', 'none');
        end
    end
    jitterX = g + (rand(n,1) - 0.5) * 2 * JITTER;
    if any(inThr)
        scatter(ax, jitterX(inThr), v(inThr), 45, colors{g}, 'filled', ...
            'MarkerEdgeColor', 'k', 'MarkerFaceAlpha', 0.85);
    end
    if any(~inThr)
        scatter(ax, jitterX(~inThr), v(~inThr), 45, ...
            'MarkerFaceColor', 'none', 'MarkerEdgeColor', colors{g}, 'LineWidth', 1.3);
    end
end
set(ax, 'XTick', [1 2], 'XTickLabel', ...
    {sprintf('%s (n=%d)', labelA, numel(volA)), sprintf('%s (n=%d)', labelB, numel(volB))});
xlim(ax, [0.4 2.6]);
ylabel(ax, 'Total lesion volume per animal (mm³)');
set(ax, 'TickDir','out', 'Box','off');
title(ax, {volStr, ['bar = mean (whiskers = ±SD) of filled (in Min/Max range) ' ...
    'points; open circles = outside range']}, 'FontSize', 9, 'Interpreter','none');
end

function v = animalTotalLesionVol(S, ids)
% Sum of S.vol (per sub-lesion, mm³) across all sub-lesions belonging to
% each animal ID in `ids`, one total per animal.
v = zeros(1, numel(ids));
for k = 1:numel(ids)
    v(k) = sum(S.vol(strcmp(S.ids, ids{k})));
end
end

function resetSelToggle(hTgl)
% Pop the "Select region" toggle back to the Off state (used when the click
% is cancelled or prerequisites are missing).
if ~isempty(hTgl)
    set(hTgl(1), 'Value', 0, 'String', 'Select region: Off');
end
end

function ttl = drawRegionContours(ax, S, sel, hlID)
% Contour-only view for the "Select region" toggle: the selection circle, the
% surrounding ring, and the outlines of the lesions overlapping each —
% nothing else — so the contours are easy to read. Distinct colors: the inner
% selection circle is red, the inner (selected) lesion outlines are red; the
% outer surround ring is blue (dashed) and the surround lesion outlines are
% blue. When hlID is a non-empty animal ID (set by a linked time-course
% figure's Back/Next browse), that animal's lesion outlines are drawn green so
% the currently-browsed animal is highlighted here in sync. The caller has
% already drawn the atlas/grid and locked the axis limits.
if nargin < 4, hlID = ''; end
CIRCLE_COLOR = [0.85 0.00 0.00];   % inner selection region outline
LESION_COLOR = [0.85 0.15 0.15];   % inner (selected) lesion areas (red)
SUR_COLOR    = [0.00 0.35 0.85];   % surround ring + surround lesion areas (blue)
HILITE_COLOR = [0.00 0.70 0.20];   % currently-browsed animal's lesion(s)
inSel = false(1, numel(S.cx));
if isfield(sel,'inSel') && ~isempty(sel.inSel)
    inSel = sel.inSel;
end
inSur = false(1, numel(S.cx));
if isfield(sel,'inSur') && ~isempty(sel.inSur)
    inSur = sel.inSur;
end
hasSurround = isfield(sel,'hasSurround') && sel.hasSurround ...
    && isfield(sel,'outRadPx') && sel.outRadPx > sel.radPx;
% Per-lesion highlight flag: true for the animal currently browsed in a
% linked time-course figure.
isHL = false(1, numel(S.cx));
if ~isempty(hlID)
    isHL = strcmp(S.ids, hlID);
end
% Draw order (each layer on top of the previous): surround lesion outlines
% (orange) → inner lesion outlines (blue) → highlighted animal's outlines
% (green) → surround ring (orange dashed) → inner selection circle (red). So
% the red circle is never hidden and the green highlight sits above the rest.
havePoly = isfield(S,'polyPts') && ~isempty(S.polyPts);
if havePoly
    for k = find(inSur & ~isHL)
        pts = S.polyPts{k};
        if isempty(pts), continue; end
        plot(ax, [pts(:,1); pts(1,1)], ...
                 S.mapH + 1 - [pts(:,2); pts(1,2)], '-', ...
             'Color', SUR_COLOR, 'LineWidth', 1.5);
    end
    for k = find(inSel & ~isHL)
        pts = S.polyPts{k};
        if isempty(pts), continue; end
        plot(ax, [pts(:,1); pts(1,1)], ...
                 S.mapH + 1 - [pts(:,2); pts(1,2)], '-', ...
             'Color', LESION_COLOR, 'LineWidth', 1.5);
    end
    for k = find((inSel | inSur) & isHL)
        pts = S.polyPts{k};
        if isempty(pts), continue; end
        plot(ax, [pts(:,1); pts(1,1)], ...
                 S.mapH + 1 - [pts(:,2); pts(1,2)], '-', ...
             'Color', HILITE_COLOR, 'LineWidth', 2.5);
    end
end
% Selection outline: a line corridor (rectangles) or a circle/annulus.
isLine = isfield(sel,'shape') && strcmp(sel.shape,'line');
if isLine
    if hasSurround && isfield(sel,'outerPoly') && ~isempty(sel.outerPoly)
        op = sel.outerPoly;
        plot(ax, [op(:,1); op(1,1)], [op(:,2); op(1,2)], '--', ...
             'Color', SUR_COLOR, 'LineWidth', 2.0);
    end
    if isfield(sel,'innerPoly') && ~isempty(sel.innerPoly)
        ip = sel.innerPoly;
        plot(ax, [ip(:,1); ip(1,1)], [ip(:,2); ip(1,2)], '-', ...
             'Color', CIRCLE_COLOR, 'LineWidth', 2.0);
    end
    % Also draw the clicked centre line for reference.
    if isfield(sel,'x1')
        plot(ax, [sel.x1 sel.x2], [sel.y1 sel.y2], ':', ...
             'Color', CIRCLE_COLOR, 'LineWidth', 1.0);
    end
else
    th = linspace(0, 2*pi, 120);
    if hasSurround
        plot(ax, sel.xc + sel.outRadPx*cos(th), sel.yc + sel.outRadPx*sin(th), '--', ...
             'Color', SUR_COLOR, 'LineWidth', 2.0);
    end
    plot(ax, sel.xc + sel.radPx*cos(th), sel.yc + sel.radPx*sin(th), '-', ...
         'Color', CIRCLE_COLOR, 'LineWidth', 2.0);
end
shapeWord = 'region';
if isLine, shapeWord = 'line corridor'; end
nLes = sum(inSel);
nSur = sum(inSur);
% Two-line title (cellstr) so the counts + position don't run off the figure:
%   line 1 = animal/lesion counts, line 2 = shape size & AP/LR position.
if nLes == 0 && nSur == 0
    ttl = {'No lesion area overlaps the selection', ...
           sprintf('%g µm %s @ AP %+.2f, LR %+.2f mm', ...
                   sel.diamUM, shapeWord, sel.AP, sel.LR)};
else
    line1 = sprintf('%d inner lesions (%d animals)', nLes, sel.nAni);
    if hasSurround
        nSurAni = 0;
        if isfield(sel,'nSur'), nSurAni = sel.nSur; end
        line1 = sprintf('%s  |  %d surround lesions (%d animals)', ...
            line1, nSur, nSurAni);
    end
    if hasSurround
        line2 = sprintf('%g µm %s, out to %g µm @ AP %+.2f, LR %+.2f mm  (toggle Off to restore)', ...
            sel.diamUM, shapeWord, sel.surUM, sel.AP, sel.LR);
    else
        line2 = sprintf('%g µm %s @ AP %+.2f, LR %+.2f mm  (toggle Off to restore)', ...
            sel.diamUM, shapeWord, sel.AP, sel.LR);
    end
    if ~isempty(hlID) && any((inSel | inSur) & isHL)
        line1 = sprintf('%s  [green = %s]', line1, hlID);
    end
    ttl = {line1, line2};
end
end

function drawRegionRelationFigure(figRF, S)
% Six panels (3 columns M1/M2/S1 x 2 rows): lesion size (mm³) vs total
% post-infarction symptom mean, each column restricted to lesions whose
% centroid pixel lies inside that region on the Allen top-view. Row 1
% plots the primary x (total or per-region per the X-axis toggle); row 2
% plots the SAME lesions against the volume share of a user-chosen region
% (Row 2 x: dropdown, default S1) — useful for inspecting cross-region
% involvement (e.g. S1 portion of M1-centroid lesions vs deficit).
clf(figRF);
% The 3x2 layout needs more vertical room than the original 3x1 figure
% size (520 px). Stretch any cached figure stuck at the old short height.
pos = get(figRF, 'Position');
if pos(4) < 700
    pos(4) = 880;
    set(figRF, 'Position', pos);
end

if isempty(S) || ~isfield(S, 'cx') || isempty(S.cx)
    ax = axes('Parent', figRF, 'Position', [0.1 0.1 0.8 0.8]); axis(ax, 'off');
    text(ax, 0.5, 0.5, 'No lesion-map data for any infarction animal', ...
        'Units','normalized', 'HorizontalAlignment','center', 'FontSize', 11);
    return
end

RM = getRegionTopViewMasks();   % struct .M1/.M2/.S1 (each [nAP x nML]) or []
if isempty(RM)
    ax = axes('Parent', figRF, 'Position', [0.1 0.1 0.8 0.8]); axis(ax, 'off');
    text(ax, 0.5, 0.5, sprintf(['Cannot test centroid region:\n' ...
        'AllenCCF annotation volume / structure tree not found.\n' ...
        '(See the MATLAB command window for details.)']), ...
        'Units','normalized', 'HorizontalAlignment','center', 'FontSize', 11);
    return
end

% Symptom selector — mirrors the Lesion Centroids "Color by" dropdown.
% Selection persists across redraws via figRF appdata.
metricNames = {'metric'};
if isfield(S, 'metricNames') && ~isempty(S.metricNames)
    metricNames = S.metricNames;
end
mi = getappdata(figRF, 'rfMetricIdx');
if isempty(mi)
    mi = find(strcmp(metricNames, 'Fall count'), 1);
    if isempty(mi), mi = 1; end
end
mi = max(1, min(mi, numel(metricNames)));
setappdata(figRF, 'rfMetricIdx', mi);
mname = metricNames{mi};

% Controls live on a clean top row at y=0.955 so they don't overlap the
% (centered) title text below.
uicontrol(figRF, 'Style','text', 'String','Color by:', ...
    'Units','normalized', 'Position',[0.015 0.955 0.06 0.035], ...
    'FontSize',9, 'HorizontalAlignment','left', ...
    'BackgroundColor',get(figRF,'Color'));
uicontrol(figRF, 'Style','popupmenu', 'String',metricNames, 'Value',mi, ...
    'Units','normalized', 'Position',[0.075 0.955 0.14 0.04], ...
    'FontSize',9, 'Tag','popRFMetric', ...
    'Callback', @(src,~) rfPickMetric(figRF, S, src));

% Animal-ID On/Off toggle (state persists across redraws via appdata)
showIDs = getappdata(figRF, 'rfShowIDs');
if isempty(showIDs), showIDs = true; end
onoff = {'Off','On'};
uicontrol(figRF, 'Style','togglebutton', ...
    'String',['Animal IDs: ' onoff{showIDs+1}], 'Value',showIDs, ...
    'Units','normalized', 'Position',[0.23 0.955 0.13 0.04], ...
    'FontSize',9, 'Tag','tglRFIDs', ...
    'Callback', @(src,~) rfToggleIDs(figRF, S, src));

% Read the X-axis source toggle early — the size sliders are wired to the
% chosen x source (their data range and persisted state depend on it).
xPerReg = getappdata(figRF, 'rfXPerRegion');
if isempty(xPerReg), xPerReg = false; end
setappdata(figRF, 'rfXPerRegion', xPerReg);

% Min/Max lesion-size sliders — range filter for the panels.
% In per-region mode the sliders filter each panel by ITS region's volume
% share, so the range spans all per-region volumes (union across M1/M2/S1)
% and the persisted state lives under separate appdata keys so toggling
% doesn't clobber the total-mode filter (different units / ranges).
hasPR = xPerReg && isfield(S,'volByRegion') && ~isempty(S.volByRegion);
if hasPR
    vR = S.volByRegion(:);  vR = vR(~isnan(vR));
    if ~isempty(vR), vmin = min(vR);  vmax = max(vR); else, vmin = 0; vmax = 1; end
    minKey = 'rfMinVolPR';  maxKey = 'rfMaxVolPR';
    defLo  = vmin;          defHi  = vmax;              % default: full range
else
    vmin   = min(S.vol);    vmax   = max(S.vol);
    minKey = 'rfMinVol';    maxKey = 'rfMaxVol';
    defLo  = vmin;          defHi  = min(1.0, vmax);    % prior default
end
if ~(isfinite(vmin) && isfinite(vmax) && vmax > vmin)
    vmin = 0;  vmax = max(1, vmin + 1e-3);
end
vLo = getappdata(figRF, minKey);
vHi = getappdata(figRF, maxKey);
if isempty(vLo), vLo = defLo; end
if isempty(vHi), vHi = defHi; end
vLo = min(max(vLo, vmin), vmax);
vHi = min(max(vHi, vmin), vmax);
if vLo > vHi, tmp = vLo;  vLo = vHi;  vHi = tmp; end
setappdata(figRF, minKey, vLo);
setappdata(figRF, maxKey, vHi);

bg = get(figRF, 'Color');
uicontrol(figRF, 'Style','text', 'String','Min size', ...
    'Units','normalized', 'Position',[0.38 0.955 0.06 0.035], ...
    'FontSize',9, 'HorizontalAlignment','left', 'BackgroundColor',bg);
uicontrol(figRF, 'Style','slider', 'Min',vmin, 'Max',vmax, 'Value',vLo, ...
    'Units','normalized', 'Position',[0.44 0.96 0.13 0.03], ...
    'Tag','sldRFMinVol', ...
    'Callback', @(src,~) rfPickMinVol(figRF, S, src));
uicontrol(figRF, 'Style','text', 'String',sprintf('%.2f mm³',vLo), ...
    'Units','normalized', 'Position',[0.575 0.955 0.065 0.035], ...
    'FontSize',9, 'HorizontalAlignment','left', 'BackgroundColor',bg);

uicontrol(figRF, 'Style','text', 'String','Max size', ...
    'Units','normalized', 'Position',[0.65 0.955 0.06 0.035], ...
    'FontSize',9, 'HorizontalAlignment','left', 'BackgroundColor',bg);
uicontrol(figRF, 'Style','slider', 'Min',vmin, 'Max',vmax, 'Value',vHi, ...
    'Units','normalized', 'Position',[0.71 0.96 0.13 0.03], ...
    'Tag','sldRFMaxVol', ...
    'Callback', @(src,~) rfPickMaxVol(figRF, S, src));
uicontrol(figRF, 'Style','text', 'String',sprintf('%.2f mm³',vHi), ...
    'Units','normalized', 'Position',[0.845 0.955 0.065 0.035], ...
    'FontSize',9, 'HorizontalAlignment','left', 'BackgroundColor',bg);

% Phase dropdown — restricts post-infarction sums to the selected stroke
% phase. Default "All (POD>0)" preserves prior behavior. Row 2 (y=0.905).
phaseNames = {'All (POD>0)'};
if isfield(S,'phaseNames') && ~isempty(S.phaseNames), phaseNames = S.phaseNames; end
phIdx = getappdata(figRF, 'rfPhaseIdx');
if isempty(phIdx), phIdx = 1; end
phIdx = max(1, min(phIdx, numel(phaseNames)));
setappdata(figRF, 'rfPhaseIdx', phIdx);
phName = phaseNames{phIdx};
uicontrol(figRF, 'Style','text', 'String','Phase:', ...
    'Units','normalized', 'Position',[0.015 0.905 0.06 0.035], ...
    'FontSize',9, 'HorizontalAlignment','left', 'BackgroundColor',bg);
uicontrol(figRF, 'Style','popupmenu', 'String', phaseNames, 'Value', phIdx, ...
    'Units','normalized', 'Position',[0.075 0.905 0.20 0.04], ...
    'FontSize',9, 'Tag','popRFPhase', ...
    'Callback', @(src,~) rfPickPhase(figRF, S, src));

% X-axis source toggle: when on, each panel plots its own region's per-lesion
% volume (M1 panel -> volM1 of each lesion, etc.) instead of the lesion's
% total volume; the size sliders above also switch to filtering on that
% per-region value (with separate persisted state per mode). Off (default)
% = total volume — preserves prior behavior. State is read at the top of
% this function so the slider block can react to it.
xOnoff = {'total','per-region'};
uicontrol(figRF, 'Style','togglebutton', ...
    'String',['X-axis: ' xOnoff{double(xPerReg)+1}], 'Value',xPerReg, ...
    'Units','normalized', 'Position',[0.295 0.905 0.16 0.04], ...
    'FontSize',9, 'Tag','tglRFXPerRegion', ...
    'Callback', @(src,~) rfToggleXPerRegion(figRF, S, src));

% Per-column Row 2 secondary x-axis: each centroid column has its own
% dropdown picking which region's per-lesion volume goes on x for the
% bottom panel. Defaults reflect the common comparisons:
%   M1col -> S1 portion   (how much S1 is in M1-centroid lesions)
%   M2col -> M1 portion   (how much M1 is in M2-centroid lesions)
%   S1col -> M1 portion   (how much M1 is in S1-centroid lesions)
% Row 2 plots the same lesions as row 1 (same selection), only with a
% different x value. State persists as a length-3 vector (rfRow2Vec).
keysAll = {'M1','M2','S1'};
r2Vec = getappdata(figRF, 'rfRow2Vec');
if isempty(r2Vec) || numel(r2Vec) ~= 3
    r2Vec = [3, 1, 1];   % [M1col=S1, M2col=M1, S1col=M1]
end
r2Vec = max(1, min(r2Vec(:).', numel(keysAll)));
setappdata(figRF, 'rfRow2Vec', r2Vec);
uicontrol(figRF, 'Style','text', 'String','Row 2 x:', ...
    'Units','normalized', 'Position',[0.475 0.905 0.06 0.035], ...
    'FontSize',9, 'HorizontalAlignment','left', 'BackgroundColor',bg);
xR2c = [0.540, 0.655, 0.770];   % left edges of (M1col, M2col, S1col) groups
for c = 1:3
    uicontrol(figRF, 'Style','text', 'String',[keysAll{c} 'col:'], ...
        'Units','normalized', 'Position',[xR2c(c) 0.905 0.043 0.035], ...
        'FontSize',9, 'HorizontalAlignment','left', 'BackgroundColor',bg);
    uicontrol(figRF, 'Style','popupmenu', 'String', keysAll, 'Value', r2Vec(c), ...
        'Units','normalized', 'Position',[xR2c(c)+0.045 0.905 0.06 0.04], ...
        'FontSize',9, 'Tag',sprintf('popRFRow2_%d',c), ...
        'Callback', @(src,~) rfPickRow2Region(figRF, S, src, c));
end

% "Time course" button — opens a new window with a drawPopulationFigure-style
% "Days post-infarction vs Deficits" plot, restricted to the union of
% animals shown in the upper (row-1) panels with the current slider filter.
uicontrol(figRF, 'Style','pushbutton', 'String','Time course', ...
    'Units','normalized', 'Position',[0.880 0.905 0.115 0.04], ...
    'FontSize',9, 'Tag','btnRFTimeCourse', ...
    'Callback', @(~,~) rfOpenTimeCourse(figRF, S));

if isfield(S,'metricMat3d') && ~isempty(S.metricMat3d)
    fc = S.metricMat3d(:, mi, phIdx).';
else
    fc = nan(1, numel(S.cx));
end

% Centroid pixel -> mask indices (masks share one size; scale defensively)
[nAPm, nMLm] = size(RM.M1);
apIdx = min(max(round(S.cy(:) / max(S.mapH,1) * nAPm), 1), nAPm);
mlIdx = min(max(round(S.cx(:) / max(S.mapW,1) * nMLm), 1), nMLm);
lin   = sub2ind([nAPm, nMLm], apIdx, mlIdx);

% Lesion-size range is now controlled by the Min/Max sliders above
% (defaults: data min … 1 mm³, the prior "spans other areas" cutoff).

keys   = {'M1','M2','S1'};
labels = {'M1 (MOp)','M2 (MOs)','S1 (SSp)'};
cols   = {[0.20 0.40 0.80], [0.20 0.60 0.30], [0.85 0.45 0.10]};
xs     = [0.07 0.40 0.73];  w  = 0.25;
% 3 columns x 2 rows: row 1 = primary x (today's view), row 2 = secondary
% x = volByRegion(:, r2Vec(p)) so each centroid column can be re-plotted
% against any chosen region's volume share (e.g. M1col with x=S1 vol,
% M2col with x=M1 vol, S1col with x=M1 vol).
% Tuned for the 880-px figure: row 1 sits below the title (y=0.85) with a
% comfortable gap, row 2 sits above the bottom margin, ~0.12 between rows.
yRow   = [0.50, 0.07];   % row 1 y0 (top), row 2 y0 (bottom)
hRow   = 0.30;

% Row 2's secondary x is now per-column (picked inside the loop from
% r2Vec(p)); volByRegion presence is checked there too. The fallback when
% volByRegion is absent is total volume with a hint in the xlabel.

% Mark lesions whose animal has more than one lesion (multiple centroids).
[~, ~, ic]  = unique(S.ids);
cntPerU     = accumarray(ic(:), 1);
isMultiAll  = reshape(cntPerU(ic) > 1, 1, []);   % per-marker, S.ids order
MULTI_COLOR = [0.85 0.10 0.10];                   % red

axAll = gobjects(2, 3);
yMin  =  inf;   % track data range across all 6 panels for shared y-limit
yMax  = -inf;   % (z-score metrics go negative, so don't pin the floor at 0)
row1IDs       = {};         % union of S.ids across all row-1 selections
row1IDsByCol  = cell(1, 3); % per-column row-1 ID lists for per-centroid TC
for p = 1:3
    % Primary (row 1) x source: total vol or panel-own per-region volume.
    if xPerReg && isfield(S,'volByRegion') && ~isempty(S.volByRegion) ...
            && size(S.volByRegion, 2) >= p
        xAll    = S.volByRegion(:, p).';
        xLabel1 = sprintf('%s lesion size (mm³)', keys{p});
    else
        xAll    = S.vol;
        xLabel1 = 'Lesion size (mm³)';
    end

    % Marker selection: gate by primary x (so the sliders behave exactly as
    % before for row 1). Row 2 uses the SAME selection so the bottom plot
    % shows how those same lesions distribute on the secondary region — a
    % lesion with near-zero secondary volume still appears at small x.
    inReg = RM.(keys{p})(lin);
    inReg = inReg(:).';
    sel   = inReg & ~isnan(fc) & ~isnan(xAll) ...
            & (xAll >= vLo) & (xAll <= vHi);

    % ── Row 1: primary x ─────────────────────────────────────────────────
    ax1 = axes('Parent', figRF, 'Position', [xs(p) yRow(1) w hRow]);
    axAll(1, p) = ax1;
    xlabel(ax1, xLabel1);
    if phIdx == 1
        ylabel(ax1, sprintf('Mean post-infarction %s', lower(mname)));
    else
        ylabel(ax1, sprintf('Mean %s %s', phName, lower(mname)));
    end
    x = xAll(sel);  y = fc(sel);  idSel = S.ids(sel);
    mSel = isMultiAll(sel);
    row1IDs           = [row1IDs, idSel];   %#ok<AGROW>
    row1IDsByCol{p}   = unique(idSel);
    renderRFPanel(ax1, x, y, idSel, mSel, cols{p}, labels{p}, ...
                  showIDs, MULTI_COLOR);
    if vHi > vLo
        xlim(ax1, [vLo, vHi]);    % x-limit follows the Min/Max sliders
    end
    if ~isempty(y)
        yMin = min(yMin, min(y));  yMax = max(yMax, max(y));
    end

    % ── Row 2: secondary x (same lesions, region picked per-column) ──────
    r2c = r2Vec(p);   % which region's per-lesion volume goes on x for col p
    if isfield(S,'volByRegion') && ~isempty(S.volByRegion) ...
            && size(S.volByRegion, 2) >= r2c
        x2All  = S.volByRegion(:, r2c).';
        xLab2  = sprintf('%s lesion size (mm³)', keysAll{r2c});
    else
        x2All  = S.vol;
        xLab2  = 'Lesion size (mm³, total — volByRegion unavailable)';
    end
    ax2 = axes('Parent', figRF, 'Position', [xs(p) yRow(2) w hRow]);
    axAll(2, p) = ax2;
    xlabel(ax2, xLab2);
    if phIdx == 1
        ylabel(ax2, sprintf('Mean post-infarction %s', lower(mname)));
    else
        ylabel(ax2, sprintf('Mean %s %s', phName, lower(mname)));
    end
    x2  = x2All(sel);
    renderRFPanel(ax2, x2, y, idSel, mSel, cols{p}, labels{p}, ...
                  showIDs, MULTI_COLOR);
    % Row 2 xlim auto-fits to its own data range (sliders don't bind here).
    if ~isempty(x2)
        xspan = max(x2) - min(x2);
        if xspan <= 0, xspan = max(abs(max(x2)), 0.01); end
        xlim(ax2, [min(x2) - 0.05*xspan, max(x2) + 0.05*xspan]);
    end
end

% Stash the row-1 IDs (union and per-column), the slider range that
% produced them, and the set of "dual centroid" animal IDs (>1 lesion
% shown — same as the red-edge markers) for the "Time course" button.
% Recomputing here keeps the button's callback simple — it just reads
% what the current draw selected.
setappdata(figRF, 'row1IDsUnion',     unique(row1IDs));
setappdata(figRF, 'row1IDsByCol',     row1IDsByCol);
setappdata(figRF, 'row1SliderRange',  [vLo, vHi]);
setappdata(figRF, 'row1XMode',        xPerReg);
setappdata(figRF, 'multiCentroidIDs', unique(S.ids(isMultiAll)));

% Shared y-limit across all 6 panels = common data range, with a little
% headroom so markers aren't clipped. Keep the 0 baseline for non-negative
% metrics; extend below 0 when the metric (e.g. the zFT+zFC severity score)
% has negative values.
if isfinite(yMin) && isfinite(yMax)
    loData = min(yMin, 0);            % 0 floor unless data goes negative
    span   = yMax - loData;
    if span <= 0, span = max(abs(yMax), 1); end
    pad    = 0.05 * span;
    loLim  = loData - (loData < 0) * pad;   % pad the floor only when negative
    hiLim  = yMax + pad;
    if hiLim <= loLim, hiLim = loLim + 1; end
    for rr = 1:2
        for p = 1:3
            if isgraphics(axAll(rr, p)), ylim(axAll(rr, p), [loLim, hiLim]); end
        end
    end
end

% Use annotation (not sgtitle) so the title sits below the control row
% and never overlaps the dropdown/toggle, regardless of metric name length.
if xPerReg, sizeLabel = 'Per-region lesion size'; else, sizeLabel = 'Lesion size'; end
row2Tag = sprintf('row 2 x = M1col:%s, M2col:%s, S1col:%s', ...
    keysAll{r2Vec(1)}, keysAll{r2Vec(2)}, keysAll{r2Vec(3)});
if phIdx == 1
    ttlStr = sprintf(['%s vs mean post-infarction %s, by centroid region   ' ...
        '(%s; red = animal with multiple lesions)'], sizeLabel, lower(mname), row2Tag);
else
    ttlStr = sprintf(['%s vs mean %s %s, by centroid region   ' ...
        '(%s; red = animal with multiple lesions)'], sizeLabel, phName, lower(mname), row2Tag);
end
annotation(figRF, 'textbox', [0.00 0.850 1.00 0.045], ...
    'String', ttlStr, ...
    'HorizontalAlignment','center', 'VerticalAlignment','middle', ...
    'FontSize', 11, 'EdgeColor','none', 'FitBoxToText','off');
end

function rfPickMetric(figRF, S, src)
% "Color by" dropdown callback for the M1/M2/S1 region-relation figure.
setappdata(figRF, 'rfMetricIdx', get(src, 'Value'));
drawRegionRelationFigure(figRF, S);
end

function rfToggleIDs(figRF, S, src)
% Animal-ID On/Off toggle callback for the M1/M2/S1 region-relation figure.
setappdata(figRF, 'rfShowIDs', logical(get(src, 'Value')));
drawRegionRelationFigure(figRF, S);
end

function rfPickMinVol(figRF, S, src)
% Min-lesion-size slider callback. Writes to the appdata key that matches
% the current X-axis mode so the total-mode and per-region-mode filters
% don't overwrite each other.
xPerReg = getappdata(figRF, 'rfXPerRegion');
if isempty(xPerReg), xPerReg = false; end
if xPerReg, k = 'rfMinVolPR'; else, k = 'rfMinVol'; end
setappdata(figRF, k, get(src, 'Value'));
drawRegionRelationFigure(figRF, S);
end

function rfPickMaxVol(figRF, S, src)
% Max-lesion-size slider callback (see rfPickMinVol).
xPerReg = getappdata(figRF, 'rfXPerRegion');
if isempty(xPerReg), xPerReg = false; end
if xPerReg, k = 'rfMaxVolPR'; else, k = 'rfMaxVol'; end
setappdata(figRF, k, get(src, 'Value'));
drawRegionRelationFigure(figRF, S);
end

function rfPickPhase(figRF, S, src)
% Phase dropdown callback for the M1/M2/S1 region-relation figure.
setappdata(figRF, 'rfPhaseIdx', get(src, 'Value'));
drawRegionRelationFigure(figRF, S);
end

function rfToggleXPerRegion(figRF, S, src)
% X-axis source toggle callback (total vs per-region lesion size).
setappdata(figRF, 'rfXPerRegion', logical(get(src, 'Value')));
drawRegionRelationFigure(figRF, S);
end

function rfPickRow2Region(figRF, S, src, colIdx)
% Per-column "Row 2 x:" dropdown — picks which region's per-lesion volume
% goes on x for the bottom row of the given centroid column
% (1=M1col, 2=M2col, 3=S1col). State is a length-3 vector under rfRow2Vec.
r2Vec = getappdata(figRF, 'rfRow2Vec');
if isempty(r2Vec) || numel(r2Vec) ~= 3, r2Vec = [3, 1, 1]; end
r2Vec(colIdx) = get(src, 'Value');
setappdata(figRF, 'rfRow2Vec', r2Vec);
drawRegionRelationFigure(figRF, S);
end

function rfOpenTimeCourse(figRF, ~)
% "Time course" button on the M1/M2/S1 figure: opens THREE new windows,
% one per centroid group (M1, M2, S1). Each is a drawPopulationFigure-
% style "Days post-infarction vs Deficits" plot, restricted to the
% animals shown in the corresponding upper (row-1) panel under the current
% slider filter. Sham is unchanged (all Sham) in every window so each
% centroid group is compared against the same baseline.
BehData = getappdata(figRF, 'BehData');
StdPOD  = getappdata(figRF, 'StdPOD');
if isempty(BehData) || isempty(StdPOD)
    warning('LeverPullTask:noBehData', ...
        'Time course: BehData/StdPOD not found on figRF — reopen Lesion Centroids.');
    return
end
idsByCol = getappdata(figRF, 'row1IDsByCol');
range    = getappdata(figRF, 'row1SliderRange');
perReg   = getappdata(figRF, 'row1XMode');
multiIDs = getappdata(figRF, 'multiCentroidIDs');
if isempty(idsByCol)
    warning('LeverPullTask:noRow1Animals', ...
        'Time course: per-panel row-1 IDs not found — adjust the size sliders and let the figure redraw.');
    return
end
if isempty(range), range = [NaN NaN]; end
modeTag = 'total vol';
if ~isempty(perReg) && perReg, modeTag = 'per-region vol'; end

% Ask whether animals with multiple centroids ("dual centroid", red-edge
% markers in figRF) should be included. Same single choice applies to all
% three centroid-group windows so they stay comparable. Default No so the
% time course attributes the deficit to a single lesion unless the user
% explicitly opts in to mixing in the multi-lesion animals.
yesStr = 'Yes (include all)';
noStr  = 'No (single-centroid only)';
choice = questdlg(...
    {'Include animals with dual centroids in the time course?', '', ...
     '"Dual centroid" = animals with >1 lesion shown (red-edge markers).', ...
     'Excluding them attributes the time-course deficit to a single lesion.'}, ...
    'Time course — dual centroids', yesStr, noStr, 'Cancel', noStr);
if isempty(choice) || strcmp(choice, 'Cancel'), return; end
inclDual = strcmp(choice, yesStr);

if ~inclDual && ~isempty(multiIDs)
    for p = 1:numel(idsByCol)
        idsByCol{p} = idsByCol{p}(~ismember(idsByCol{p}, multiIDs));
    end
end
dualTag = 'incl dual';
if ~inclDual, dualTag = 'single-centroid only'; end

keysAll   = {'M1','M2','S1'};
labelsAll = {'M1 (MOp)','M2 (MOs)','S1 (SSp)'};
opened    = 0;
allGroupNames = {BehData.Group};
allIDs        = {BehData.ID};
for p = 1:3
    IDs_p = idsByCol{p};
    if isempty(IDs_p)
        fprintf('Time course: no animals in %s centroid panel — skipping.\n', keysAll{p});
        continue
    end
    infMask_p = strcmp(allGroupNames, 'Infarction') & ismember(allIDs, IDs_p);
    if ~any(infMask_p)
        fprintf('Time course: %s centroid row-1 IDs did not match any Infarction animal in BehData — skipping.\n', keysAll{p});
        continue
    end
    filterStr_p = sprintf('%s-centroid lesions  (n=%d, row-1 %s in %.2f–%.2f mm³, %s)', ...
        labelsAll{p}, sum(infMask_p), modeTag, range(1), range(2), dualTag);
    % Cascade windows ~30 px so the three don't perfectly overlap; a new
    % figure each click matches the "new figure in a new window" intent.
    figNew = figure('Name', ...
        sprintf('%s-centroid time course (n=%d)', keysAll{p}, sum(infMask_p)), ...
        'Position', [120 + (p-1)*40, 80 - (p-1)*30, 1100, 820]);
    drawPopulationFigure(BehData, figNew, StdPOD, {}, [], false, [], 'original', ...
        infMask_p, filterStr_p);

    % "Lesion map" companion: a small button at the bottom-right opens a
    % new drawLesionSummaryFigure window for the same animal subset, so
    % the user can see where these animals' lesions actually sit.
    ccfRoot = getappdata(figRF, 'CCF_root_beh');
    setappdata(figNew, 'BehData',      BehData);
    setappdata(figNew, 'CCF_root_beh', ccfRoot);
    setappdata(figNew, 'tcInfMask',    infMask_p);
    setappdata(figNew, 'tcFilterStr',  filterStr_p);
    setappdata(figNew, 'tcLabel',      sprintf('%s-centroid', keysAll{p}));
    uicontrol(figNew, 'Style','pushbutton', 'String','Lesion map', ...
        'Units','normalized', 'Position',[0.86 0.005 0.13 0.03], ...
        'FontSize',9, 'Tag','btnTCLesionMap', ...
        'Callback', @(~,~) tcOpenLesionMap(figNew));

    opened = opened + 1;
end
if opened == 0
    warning('LeverPullTask:noPanelsOpened', ...
        'Time course: every centroid panel was empty for the current slider range.');
end
end

function tcOpenLesionMap(figTC, ~)
% "Lesion map" button on a centroid time-course figure: opens a new
% drawLesionSummaryFigure window restricted to the same Infarction
% subset this time course was drawn for (the inf mask was stashed on
% figTC by rfOpenTimeCourse). Lets the user check WHERE these animals'
% lesions sit without restating the filter.
BehData   = getappdata(figTC, 'BehData');
ccfRoot   = getappdata(figTC, 'CCF_root_beh');
infMask   = getappdata(figTC, 'tcInfMask');
filterStr = getappdata(figTC, 'tcFilterStr');
label     = getappdata(figTC, 'tcLabel');
if isempty(BehData) || isempty(ccfRoot) || isempty(infMask)
    warning('LeverPullTask:noTCData', ...
        'Lesion map: required data missing on the time-course figure.');
    return
end
if ~any(infMask)
    warning('LeverPullTask:noTCInf', ...
        'Lesion map: time-course inf mask is empty.');
    return
end
if isempty(label), label = 'centroid time course'; end
figMap = figure('Name', sprintf('Lesion map — %s', label), ...
    'Position', [200 100 760 760]);
drawLesionSummaryFigure(BehData, {}, [], false, [], ccfRoot, figMap, ...
    infMask, filterStr);
end

function renderRFPanel(ax, x, y, idSel, mSel, panelColor, panelLabel, ...
                       showIDs, MULTI_COLOR)
% One panel of the M1/M2/S1 region-relation figure: scatter (red-edge for
% multi-lesion animals), optional animal-ID labels, "with red" and
% "w/o red" linear regression overlays, and a title with the counts.
% Shared between row 1 (primary x) and row 2 (secondary x) so they render
% identically apart from the x source the caller picks.
hold(ax, 'on');
set(ax, 'TickDir','out', 'Box','off');
axis(ax, 'square');
grid(ax, 'on');

if isempty(x)
    text(ax, 0.5, 0.5, sprintf('No lesion centroid in %s', panelLabel), ...
        'Units','normalized', 'HorizontalAlignment','center', 'FontSize', 10);
    title(ax, sprintf('%s: n = 0', panelLabel), 'FontSize', 10);
    return
end

if any(~mSel)
    scatter(ax, x(~mSel), y(~mSel), 55, 'filled', 'MarkerFaceAlpha', 0.7, ...
        'MarkerFaceColor', panelColor, 'MarkerEdgeColor', 'k');
end
if any(mSel)
    scatter(ax, x(mSel), y(mSel), 55, 'filled', 'MarkerFaceAlpha', 0.7, ...
        'MarkerFaceColor', MULTI_COLOR, 'MarkerEdgeColor', 'k');
end
if showIDs
    for k = 1:numel(x)
        text(ax, x(k), y(k), ['  ' idSel{k}], 'FontSize', 7, ...
            'Color', [0.3 0.3 0.3]);
    end
end

% Two regression fits per panel:
%   "with red"  — all selected lesions (incl. multi-lesion animals)
%   "w/o red"   — single-lesion animals only (drawn only when red exist)
nRed   = sum(mSel);
nNoRed = numel(x) - nRed;
ttl = sprintf('%s: n = %d  (red %d / others %d)', panelLabel, ...
              numel(x), nRed, nNoRed);
yEq = 0.96;

if numel(x) >= 3 && numel(unique(x)) >= 2
    pf = polyfit(x, y, 1);
    xf = linspace(min(x), max(x), 50);
    plot(ax, xf, polyval(pf, xf), '-', 'Color', MULTI_COLOR, 'LineWidth', 1.5);
    [r, pv] = corr(x(:), y(:));
    text(ax, 0.04, yEq, sprintf('with red:  y = %.3gx %+.3g   (r=%.2f, p=%.3g)', ...
            pf(1), pf(2), r, pv), ...
        'Units','normalized', 'VerticalAlignment','top', ...
        'HorizontalAlignment','left', 'FontSize', 8, 'Color', MULTI_COLOR);
    yEq = yEq - 0.075;
end

if any(mSel)
    xn = x(~mSel);  yn = y(~mSel);
    if numel(xn) >= 3 && numel(unique(xn)) >= 2
        pf2 = polyfit(xn, yn, 1);
        xf2 = linspace(min(xn), max(xn), 50);
        plot(ax, xf2, polyval(pf2, xf2), '--', 'Color', 'k', 'LineWidth', 1.2);
        [r2, pv2] = corr(xn(:), yn(:));
        text(ax, 0.04, yEq, sprintf('w/o red:   y = %.3gx %+.3g   (r=%.2f, p=%.3g)', ...
                pf2(1), pf2(2), r2, pv2), ...
            'Units','normalized', 'VerticalAlignment','top', ...
            'HorizontalAlignment','left', 'FontSize', 8, 'Color', 'k');
    end
end
title(ax, ttl, 'FontSize', 9);
end

function RM = getRegionTopViewMasks()
% Struct of logical [nAP x nML] top-view masks, true where the Allen surface
% voxel is in that region:  .M1 = MOp, .M2 = MOs, .S1 = SSp* (any SSp
% subfield, matching the volS1 definition used elsewhere). Built once from
% the AllenCCF annotation volume using the same surface-projection indexing
% as AllenMapTopView.m, then cached to disk (and memory) since the build
% reads a ~2 GB volume.
persistent CACHE
if ~isempty(CACHE), RM = CACHE; return; end
RM = [];

% Locate the AllenCCF data folder. Prefer this script's own directory
% (where AllenCCF/ lives), then fall back to AllenMapTopView's location.
baseDir = '';
cand = { fileparts(mfilename('fullpath')) };
mfAV = which('AllenMapTopView');
if ~isempty(mfAV), cand{end+1} = fileparts(fileparts(mfAV)); end
for c = 1:numel(cand)
    if exist(fullfile(cand{c}, 'AllenCCF', 'annotation_volume_10um_by_index.npy'), 'file')
        baseDir = cand{c};  break
    end
end
if isempty(baseDir)
    warning('getRegionTopViewMasks: AllenCCF folder not found near script or AllenMapTopView');
    return
end
cacheFn = fullfile(baseDir, 'AllenCCF', 'Region_topview_masks.mat');
if exist(cacheFn, 'file')
    try
        Sm = load(cacheFn, 'RM');
        RM = Sm.RM;  CACHE = RM;  return
    catch
    end
end

avFn = fullfile(baseDir, 'AllenCCF', 'annotation_volume_10um_by_index.npy');
stFn = fullfile(baseDir, 'AllenCCF', 'structure_tree_safe_2017.csv');
if ~exist(avFn,'file') || ~exist(stFn,'file')
    warning('getRegionTopViewMasks: AllenCCF annotation volume or structure tree missing');
    return
end

% loadStructureTree ships in the bundled AP_histology repo; add it if needed
if isempty(which('loadStructureTree'))
    stDir = fullfile(baseDir, 'AP_histology-master', 'allenCCF_repo_functions');
    if isfolder(stDir), addpath(stDir); end
end
if isempty(which('loadStructureTree'))
    warning('getRegionTopViewMasks: loadStructureTree not found');
    return
end
st = loadStructureTree(stFn);
isM1Row = cellfun(@(a) strcmp(stripLayerSuffix(a), 'MOp'), st.acronym);
isM2Row = cellfun(@(a) strcmp(stripLayerSuffix(a), 'MOs'), st.acronym);
isS1Row = cellfun(@(a) startsWith(a, 'SSp'),               st.acronym);
nRow    = numel(isM1Row);

% Read the .npy directly (no npy-matlab dependency), one slab at a time
% so the ~2 GB volume never has to be held in memory at once.
fid = fopen(avFn, 'r', 'ieee-le');
if fid < 0
    warning('getRegionTopViewMasks: cannot open %s', avFn);
    return
end
closer = onCleanup(@() fclose(fid));
magic = fread(fid, 6, '*uint8')';
if ~isequal(magic, uint8([147 78 85 77 80 89]))   % \x93 N U M P Y
    warning('getRegionTopViewMasks: not a valid .npy file');
    return
end
verMaj = fread(fid, 1, 'uint8');  fread(fid, 1, 'uint8');   % major, minor
if verMaj >= 2, hlen = fread(fid, 1, 'uint32'); else, hlen = fread(fid, 1, 'uint16'); end
hdr = fread(fid, double(hlen), '*char')';
dataOffset = ftell(fid);
dsc = regexp(hdr, '''descr''\s*:\s*''([^'']+)''', 'tokens', 'once');
frt = regexp(hdr, '''fortran_order''\s*:\s*(\w+)', 'tokens', 'once');
shp = regexp(hdr, '''shape''\s*:\s*\(([^)]*)\)',  'tokens', 'once');
if isempty(dsc) || isempty(shp)
    warning('getRegionTopViewMasks: cannot parse .npy header');
    return
end
shape = str2double(regexp(shp{1}, '\d+', 'match'));
fortranOrder = ~isempty(frt) && strcmpi(frt{1}, 'True');
dt = dsc{1};   % e.g. '<u2'
switch dt(max(end-1,1):end)
    case 'u1', prec = 'uint8';   case 'u2', prec = 'uint16';
    case 'u4', prec = 'uint32';  case 'i2', prec = 'int16';
    case 'i4', prec = 'int32';   case 'f4', prec = 'single';
    case 'f8', prec = 'double';
    otherwise
        warning('getRegionTopViewMasks: unsupported .npy dtype %s', dt);
        return
end
if numel(shape) ~= 3
    warning('getRegionTopViewMasks: unexpected annotation-volume shape');
    return
end
nAPfull = shape(1);  nDV = shape(2);  nMLfull = shape(3);
nAP = min(1320, nAPfull);
nML = min(1080, nMLfull);

fprintf('Building M1/M2/S1 top-view masks (one-time; reading annotation volume)...\n');
fseek(fid, dataOffset, 'bof');
M1 = false(nAP, nML);  M2 = false(nAP, nML);  S1 = false(nAP, nML);

% Depth window + offset that AllenMapTopView uses to find the cortical
% surface voxel: first index >1 within DV 10:300, then sample at +50.
if fortranOrder
    % Column-major: a fixed ML index is one contiguous AP-by-DV block.
    elemsPerML = nAPfull * nDV;
    for k = 1:nML
        raw = fread(fid, elemsPerML, [prec '=>double']);
        if numel(raw) < elemsPerML, break; end
        B = reshape(raw, [nAPfull, nDV]);     % B(i,j) = AV(i,j,k)
        B = B(1:nAP, :);
        win = B(:, 10:300) > 1;               % [nAP x 291]
        [hasAny, firstRel] = max(win, [], 2);
        rows = find(hasAny);
        if isempty(rows), continue; end
        d   = min(max(firstRel(rows) + 50, 1), nDV);
        val = B(sub2ind(size(B), rows(:), d(:)));
        good = val >= 1 & val <= nRow;
        gr = rows(good);  gv = val(good);
        M1(gr, k) = isM1Row(gv);
        M2(gr, k) = isM2Row(gv);
        S1(gr, k) = isS1Row(gv);
    end
else
    % Row-major (C order): a fixed AP index is one contiguous DV-by-ML block.
    elemsPerAP = nDV * nMLfull;
    for i = 1:nAP
        raw = fread(fid, elemsPerAP, [prec '=>double']);
        if numel(raw) < elemsPerAP, break; end
        slab = reshape(raw, [nMLfull, nDV]).';   % slab(j,k) = AV(i,j,k)
        win  = slab(10:300, :) > 1;
        [hasAny, firstRel] = max(win, [], 1);
        cols = find(hasAny);
        cols = cols(cols <= nML);
        if isempty(cols), continue; end
        d = min(max(firstRel(cols) + 50, 1), nDV);
        v = slab(sub2ind(size(slab), d(:), cols(:)));
        good = v >= 1 & v <= nRow;
        gc = cols(good);  gv = v(good);
        M1(i, gc) = isM1Row(gv);
        M2(i, gc) = isM2Row(gv);
        S1(i, gc) = isS1Row(gv);
    end
end

RM = struct('M1', M1, 'M2', M2, 'S1', S1);
try
    save(cacheFn, 'RM');
    fprintf('Saved region top-view mask cache: %s\n', cacheFn);
catch ME
    fprintf('Could not save region mask cache (%s); will rebuild next session.\n', ME.message);
end
CACHE = RM;
end

function drawLesionSummaryFigure(BehData, filterFields, thresholds, useAnd, maxVol, CCF_root_beh, figSum, infMaskOverride, filterStrOverride)
% Overlay lesion top-views of filtered infarction animals + mean density heatmap.
% Back/Next buttons loop: animal1 → animal2 → ... → animalN → Summary → animal1
%
% infMaskOverride  : optional logical mask over BehData (same length as
%   numel(BehData)). When non-empty it REPLACES the filterFields-based
%   inf-mask construction, so callers (e.g. the "Lesion map" button on a
%   centroid time-course figure) can specify an explicit animal subset.
% filterStrOverride: optional human-readable label for the override case.

if nargin < 3 || isempty(thresholds), thresholds.M1=0; thresholds.M2=0; thresholds.S1=0; end
if nargin < 4 || isempty(useAnd),     useAnd = false; end
if nargin < 5 || isempty(maxVol),     maxVol.M1=Inf; maxVol.M2=Inf; maxVol.S1=Inf; end
if nargin < 8, infMaskOverride   = []; end
if nargin < 9, filterStrOverride = ''; end

% ── Build infMask ────────────────────────────────────────────────────────
regionMap = struct( ...
    'hasM1', struct('volField','volM1','thresh',thresholds.M1,'maxVol',maxVol.M1), ...
    'hasM2', struct('volField','volM2','thresh',thresholds.M2,'maxVol',maxVol.M2), ...
    'hasS1', struct('volField','volS1','thresh',thresholds.S1,'maxVol',maxVol.S1));

allInf = strcmp({BehData.Group}, 'Infarction');
if ~isempty(infMaskOverride)
    % Caller supplied an explicit subset (e.g. animals shown in a
    % centroid time-course window). AND with allInf defensively so a
    % stray Sham can't slip in if the override included one.
    infMask = logical(infMaskOverride(:).') & allInf;
    if ~isempty(filterStrOverride)
        filterStr = filterStrOverride;
    else
        filterStr = sprintf('custom (n=%d)', sum(infMask));
    end
elseif isempty(filterFields)
    infMask  = allInf;
    filterStr = 'All Infarction';
else
    infMask = false(size(allInf));
    for i = find(allInf)
        nPass = 0;
        for k = 1:length(filterFields)
            fld = filterFields{k};
            if ~isfield(regionMap, fld), continue; end
            rm = regionMap.(fld);
            if rm.thresh > 0 || ~isinf(rm.maxVol)
                vol = 0;
                if isfield(BehData, rm.volField), vol = BehData(i).(rm.volField); end
                passes = (vol > rm.thresh) && (vol <= rm.maxVol);
            else
                passes = isfield(BehData, fld) && BehData(i).(fld);
            end
            if passes, nPass = nPass + 1; end
        end
        if useAnd, infMask(i) = (nPass == length(filterFields));
        else,      infMask(i) = (nPass >= 1); end
    end
    labels = cell(size(filterFields));
    for k = 1:length(filterFields)
        fld = filterFields{k}; name = strrep(fld,'has',''); rm = regionMap.(fld);
        if rm.thresh > 0 && ~isinf(rm.maxVol)
            labels{k} = sprintf('%s(%.2f-%.2fmm3)', name, rm.thresh, rm.maxVol);
        elseif rm.thresh > 0
            labels{k} = sprintf('%s(>%.2fmm3)', name, rm.thresh);
        elseif ~isinf(rm.maxVol)
            labels{k} = sprintf('%s(<=%.2fmm3)', name, rm.maxVol);
        else, labels{k} = name; end
    end
    sep = ' or '; if useAnd, sep = ' and '; end
    filterStr = strjoin(labels, sep);
end

nFiltered = sum(infMask);
infIdx    = find(infMask);

% ── Load CCF data for each matched animal ───────────────────────────────
slice_width_mm = 50 * 0.001;
Area_mapRGB = [];  mapH = 0;  mapW = 0;
animals = struct('id',{},'lesion_ccf',{},'totalVol',{});

for k = 1:length(infIdx)
    i = infIdx(k);
    ccfF = findCCFFiles(CCF_root_beh, BehData(i).ID);
    if isempty(ccfF), continue; end
    try
        Sc = load(fullfile(ccfF(1).folder, ccfF(1).name));
    catch
        continue
    end
    if isempty(Area_mapRGB) && isfield(Sc, 'Area_mapRGB')
        Area_mapRGB = Sc.Area_mapRGB;
        [mapH, mapW, ~] = size(Area_mapRGB);
    end
    totalVol = 0;
    for lsn = 1:length(Sc.lesion_ccf)
        totalVol = totalVol + ...
            sum(Sc.lesion_ccf(lsn).lesion_area_size) * 0.010 * 0.010 * slice_width_mm;
    end
    entry.id         = BehData(i).ID;
    entry.lesion_ccf = Sc.lesion_ccf;
    entry.totalVol   = totalVol;
    animals(end+1)   = entry;
end

% ── Precompute density map ───────────────────────────────────────────────
densityMap = zeros(mapH, mapW);
for k = 1:length(animals)
    for lsn = 1:length(animals(k).lesion_ccf)
        pts = animals(k).lesion_ccf(lsn).lesionArea_TopView;
        if isempty(pts) || mapH == 0, continue; end
        mask = poly2mask(pts(:,1), pts(:,2), mapH, mapW);
        densityMap = densityMap + double(mask);
    end
end

% ── Build filter string with CCF note if counts differ ──────────────────
nCCF = length(animals);
if nCCF ~= nFiltered
    filterStrFull = sprintf('%s  (%d/%d with lesion map)', filterStr, nCCF, nFiltered);
else
    filterStrFull = filterStr;
end

% ── Store state in figSum ────────────────────────────────────────────────
ld.animals       = animals;
ld.Area_mapRGB   = Area_mapRGB;
ld.densityMap    = densityMap;
ld.mapH          = mapH;
ld.mapW          = mapW;
ld.filterStr     = filterStrFull;
ld.pageIdx       = nCCF + 1;   % start at Summary
setappdata(figSum, 'lesionData', ld);

% ── Create / recreate navigation buttons ────────────────────────────────
delete(findobj(figSum, 'Tag', 'btnLesionBack'));
delete(findobj(figSum, 'Tag', 'btnLesionNext'));
delete(findobj(figSum, 'Tag', 'txtLesionPage'));
uicontrol(figSum, 'Style', 'pushbutton', 'String', '< Back', ...
    'Units', 'normalized', 'Position', [0.02 0.01 0.12 0.04], ...
    'FontSize', 9, 'Tag', 'btnLesionBack', ...
    'Callback', @(~,~) stepLesionPage(figSum, -1));
uicontrol(figSum, 'Style', 'pushbutton', 'String', 'Next >', ...
    'Units', 'normalized', 'Position', [0.86 0.01 0.12 0.04], ...
    'FontSize', 9, 'Tag', 'btnLesionNext', ...
    'Callback', @(~,~) stepLesionPage(figSum, +1));
uicontrol(figSum, 'Style', 'text', 'String', '', ...
    'Units', 'normalized', 'Position', [0.16 0.01 0.68 0.04], ...
    'FontSize', 9, 'Tag', 'txtLesionPage', ...
    'HorizontalAlignment', 'center', ...
    'BackgroundColor', get(figSum, 'Color'));

if nCCF == 0
    delete(findobj(figSum, 'Type', 'axes'));
    ax = axes('Parent', figSum, 'Position', [0.05 0.08 0.9 0.88]);
    text(0.5, 0.5, sprintf('No lesion map data\n(%d animals matched filter)', nFiltered), ...
        'Units','normalized', 'HorizontalAlignment','center', 'Parent', ax);
    axis(ax,'off');
    return
end

redrawLesionPage(figSum);
end

function redrawLesionPage(figSum)
% Redraw the current page (individual animal or summary) in figSum.
ld = getappdata(figSum, 'lesionData');
if isempty(ld), return; end

nAni    = length(ld.animals);
pageIdx = ld.pageIdx;

% Clear axes only (preserve buttons)
delete(findobj(figSum, 'Type', 'axes'));
ax = axes('Parent', figSum, 'Position', [0.05 0.08 0.9 0.88]);
hold(ax, 'on'); axis(ax, 'equal'); axis(ax, 'off');
set(ax, 'TickDir', 'out', 'Box', 'off');

% Atlas background
if ~isempty(ld.Area_mapRGB)
    imagesc(ax, flipud(ld.Area_mapRGB));
end

if pageIdx <= nAni
    % ── Individual animal ────────────────────────────────────────────────
    animal = ld.animals(pageIdx);
    for lsn = 1:length(animal.lesion_ccf)
        pts = animal.lesion_ccf(lsn).lesionArea_TopView;
        if isempty(pts) || ld.mapH == 0, continue; end
        pts_yf = ld.mapH + 1 - pts(:,2);
        patch(ax, pts(:,1), pts_yf, 'r', ...
            'FaceAlpha', 0.30, 'EdgeColor', [0.8 0 0], 'EdgeAlpha', 0.8, 'LineWidth', 1.0);
    end
    title(ax, sprintf('%s  —  Vol = %.2f mm³', animal.id, animal.totalVol), 'FontSize', 10);
    hTxt = findobj(figSum, 'Tag', 'txtLesionPage');
    if ~isempty(hTxt), set(hTxt, 'String', sprintf('%d / %d', pageIdx, nAni)); end

else
    % ── Summary (density overlay + all contours) ─────────────────────────
    if ~isempty(ld.densityMap) && any(ld.densityMap(:) > 0) && ld.mapH > 0
        densityFrac = ld.densityMap / nAni;
        redLayer = zeros(ld.mapH, ld.mapW, 3, 'uint8');
        redLayer(:,:,1) = uint8(densityFrac * 255);
        hDens = image(ax, flipud(redLayer));
        set(hDens, 'AlphaData', flipud(uint8(densityFrac * 200)));
    end
    for k = 1:nAni
        for lsn = 1:length(ld.animals(k).lesion_ccf)
            pts = ld.animals(k).lesion_ccf(lsn).lesionArea_TopView;
            if isempty(pts) || ld.mapH == 0, continue; end
            pts_yf = ld.mapH + 1 - pts(:,2);
            patch(ax, pts(:,1), pts_yf, 'r', ...
                'FaceAlpha', 0.08, 'EdgeColor', [0.8 0 0], 'EdgeAlpha', 0.5, 'LineWidth', 0.8);
        end
    end
    allVols = [ld.animals.totalVol];
    meanVol = mean(allVols);
    semVol  = std(allVols) / sqrt(nAni);
    title(ax, sprintf('Lesion map: %s  (n=%d)\nTotal vol = %.2f +/- %.2f mm3 (mean+/-SEM)', ...
        ld.filterStr, nAni, meanVol, semVol), 'FontSize', 9);
    hTxt = findobj(figSum, 'Tag', 'txtLesionPage');
    if ~isempty(hTxt), set(hTxt, 'String', 'Summary'); end
end

% Bregma marker + scale bar
if ld.mapH > 0
    plot(ax, 570, ld.mapH + 1 - 540, 'k+', 'MarkerSize', 12, 'LineWidth', 1.5);
    plot(ax, [100, 200], (ld.mapH + 1 - 740) * [1 1], 'k-', 'LineWidth', 2);
    text(ax, 150, ld.mapH + 1 - 760, '1 mm', 'HorizontalAlignment','center', 'FontSize', 8, 'Color','k');
end
end

function stepLesionPage(figSum, delta)
% Advance page index with wrapping: animals 1..N then Summary.
ld = getappdata(figSum, 'lesionData');
if isempty(ld), return; end
nPages      = length(ld.animals) + 1;   % N animals + 1 summary
ld.pageIdx  = mod(ld.pageIdx - 1 + delta, nPages) + 1;
setappdata(figSum, 'lesionData', ld);
redrawLesionPage(figSum);
end

function stepBehaviorDay(fig7, delta)
% Move the selected behavior day by delta and refresh marker + label.
pod_sess = getappdata(fig7, 'behPOD_sess');
if isempty(pod_sess), return; end
idx = getappdata(fig7, 'behDayIdx');
if isempty(idx), idx = 1; end
idx = max(1, min(idx + delta, length(pod_sess)));
setappdata(fig7, 'behDayIdx', idx);
drawDayMarker(fig7);
updateBehDayLabel(fig7);
drawEventScatter(fig7);
end

function drawDayMarker(fig7)
% Draw a red circle on the selected day in all three single-animal subplots.
pod_sess = getappdata(fig7, 'behPOD_sess');
idx      = getappdata(fig7, 'behDayIdx');
bd       = getappdata(fig7, 'selBehData');
if isempty(pod_sess) || isempty(idx) || isempty(bd), return; end
idx = max(1, min(idx, length(pod_sess)));
selPOD = pod_sess(idx);

axTags = {'singleAx1', 'singleAx2', 'singleAx3', 'singleAx4'};
fields = getappdata(fig7, 'metricSessFields');
if isempty(fields)
    fields = {'FT_sess', 'CC_sess', 'RHT_sess', 'SV_sess'};
end
for k = 1:min(length(axTags), length(fields))
    ax = findobj(fig7, 'Type', 'axes', 'Tag', axTags{k});
    if isempty(ax), continue; end
    delete(findall(ax, 'Tag', 'dayMarker'));
    if ~isfield(bd, fields{k}), continue; end
    ydata = bd.(fields{k});
    if idx <= length(ydata) && ~isnan(ydata(idx))
        plot(ax, selPOD, ydata(idx), 'ro', ...
            'MarkerSize', 10, 'LineWidth', 2, 'Tag', 'dayMarker', 'HandleVisibility', 'off');
    end
end
end

function drawEventScatter(fig7)
% Draw PCA/GMM or Dur+Zdot event scatter for the currently selected session day.
ax = findobj(fig7, 'Tag', 'singleAxEventScatter');
if isempty(ax) || ~all(isvalid(ax)), return; end

hMet = findobj(fig7, 'Tag', 'popMetric');
if isempty(hMet), return; end
metricMethods = {'original','dv','gmm'};
metricMethod = metricMethods{get(hMet,'Value')};
if strcmp(metricMethod,'original'), return; end

cla(ax); hold(ax,'on');

% Locate FallCount.mat for the current day via behMovies
behMovies = getappdata(fig7, 'behMovies');
idx       = getappdata(fig7, 'behDayIdx');
if isempty(behMovies) || isempty(idx) || idx > length(behMovies)
    text(ax,0.5,0.5,'No session selected','HorizontalAlignment','center', ...
        'Units','normalized','FontSize',7); set(ax,'Box','off','TickDir','out'); return;
end
moviePath = behMovies{idx};
if isempty(moviePath)
    text(ax,0.5,0.5,'No labeled movie','HorizontalAlignment','center', ...
        'Units','normalized','FontSize',7); set(ax,'Box','off','TickDir','out'); return;
end
% Labeled video: 'base_name DLC_model_labeled.mp4' → mat: 'base_name_FallCount.mat'
[matFolder, matName, ~] = fileparts(moviePath);
matName = regexprep(matName, 'DLC_.*_labeled$', '');  % strip DLC model suffix
matName = regexprep(matName, '_labeled$', '');          % strip plain _labeled suffix
matPath = fullfile(matFolder, [matName '_FallCount.mat']);
if ~exist(matPath,'file')
    text(ax,0.5,0.5,'No FallCount.mat','HorizontalAlignment','center', ...
        'Units','normalized','FontSize',7); set(ax,'Box','off','TickDir','out'); return;
end
try
    sm = load(matPath);
catch
    text(ax,0.5,0.5,'Load error','HorizontalAlignment','center', ...
        'Units','normalized','FontSize',7); set(ax,'Box','off','TickDir','out'); return;
end

fallCol    = [0.85 0.15 0.15];
releaseCol = [0.15 0.70 0.15];

switch metricMethod
    case 'gmm'
        if ~isfield(sm,'event_pca') || size(sm.event_pca,1) < 2
            text(ax,0.5,0.5,'Too few events for PCA','HorizontalAlignment','center', ...
                'Units','normalized','FontSize',7);
        else
            pca = sm.event_pca;
            lbl = double(sm.event_labels_gmm);
            for k = 0:1
                mask = lbl == k;
                if ~any(mask), continue; end
                col  = releaseCol; lname = 'release';
                if k == 1, col = fallCol; lname = 'fall'; end
                scatter(ax, pca(mask,1), pca(mask,2), 20, col, 'filled', ...
                    'DisplayName', sprintf('%s n=%d', lname, sum(mask)));
            end
            xlabel(ax,'PC1','FontSize',7); ylabel(ax,'PC2','FontSize',7);
            ft  = 0; cc = 0;
            if isfield(sm,'FallTime_10min_gmm'),  ft = sm.FallTime_10min_gmm; end
            if isfield(sm,'CrossCount_10min_gmm'), cc = sm.CrossCount_10min_gmm; end
            title(ax, sprintf('PCA/GMM  FT=%.1f  CC=%.1f', ft, cc), 'FontSize', 7);
            legend(ax,'FontSize',6,'Location','best');
        end
    case 'dv'
        if ~isfield(sm,'event_features') || size(sm.event_features,1) < 1
            text(ax,0.5,0.5,'No events','HorizontalAlignment','center', ...
                'Units','normalized','FontSize',7);
        else
            feats = sm.event_features;  % n×7: [dur_s, max_d, z_pk, xy_pk, z_xy, zdot, mean_z]
            lbl   = double(sm.event_labels_dv);
            dur   = feats(:,1);
            zdot  = feats(:,6);
            for k = 0:1
                mask = lbl == k;
                if ~any(mask), continue; end
                col  = releaseCol; lname = 'release';
                if k == 1, col = fallCol; lname = 'fall'; end
                scatter(ax, dur(mask), zdot(mask), 20, col, 'filled', ...
                    'DisplayName', sprintf('%s n=%d', lname, sum(mask)));
            end
            xlabel(ax,'Duration (s)','FontSize',7); ylabel(ax,'Z-vel onset','FontSize',7);
            xline(ax, 0.3, '--k', 'LineWidth', 0.8);   % MIN_FALL_DUR_S threshold
            yline(ax, 0,   '--k', 'LineWidth', 0.8);   % zdot=0 threshold
            ft  = 0; cc = 0;
            if isfield(sm,'FallTime_10min_dv'),  ft = sm.FallTime_10min_dv; end
            if isfield(sm,'CrossCount_10min_dv'), cc = sm.CrossCount_10min_dv; end
            title(ax, sprintf('Dur+Zdot  FT=%.1f  CC=%.1f', ft, cc), 'FontSize', 7);
            legend(ax,'FontSize',6,'Location','best');
        end
end
set(ax,'TickDir','out','Box','off','FontSize',7);
end

function updateBehDayLabel(fig7)
% Update the day label text next to the Behavior button.
pod_sess  = getappdata(fig7, 'behPOD_sess');
idx       = getappdata(fig7, 'behDayIdx');
behMovies = getappdata(fig7, 'behMovies');
hTxt = findobj(fig7, 'Tag', 'txtBehDay');
if isempty(hTxt) || isempty(pod_sess) || isempty(idx), return; end
idx = max(1, min(idx, length(pod_sess)));
pod = pod_sess(idx);
if pod < 0
    podStr = sprintf('Pre (%d)', pod);
else
    podStr = sprintf('POD %d', pod);
end
hasMovie = ~isempty(behMovies) && idx <= length(behMovies) && ~isempty(behMovies{idx});
if hasMovie
    set(hTxt, 'String', podStr, 'ForegroundColor', [0 0 0]);
else
    set(hTxt, 'String', [podStr '  (no movie)'], 'ForegroundColor', [0.55 0.55 0.55]);
end
end

function playBehaviorVideo(fig7)
% Open a custom video player: labeled mp4 + distance trace + controls.
behMovies = getappdata(fig7, 'behMovies');
dayIdx    = getappdata(fig7, 'behDayIdx');
hList     = findobj(fig7, 'Tag', 'listboxAnimals');
anIdx     = get(hList, 'Value');   % capture now; listbox may change while video is open
if isempty(behMovies) || isempty(dayIdx), return; end
dayIdx = max(1, min(dayIdx, length(behMovies)));
moviePath = behMovies{dayIdx};
if isempty(moviePath)
    msgbox('No labeled movie for this session day.', 'Behavior'); return
end
if ~exist(moviePath, 'file')
    msgbox(sprintf('Movie file not found:\n%s', moviePath), 'Behavior', 'error'); return
end

% ── VideoReader ───────────────────────────────────────────────────────────
try
    vr = VideoReader(moviePath);
catch ME
    msgbox(sprintf('Cannot open video:\n%s', ME.message), 'Behavior', 'error'); return
end
fps_native = vr.FrameRate;
nFrames    = max(1, round(vr.Duration * fps_native));

% ── Load distance data from matching *_FallCount.mat ─────────────────────
[movDir, movBase] = fileparts(moviePath);
distData = []; distRaw = []; distZ = []; distZFiltered = false; distFps = fps_native;
matFile   = '';
% Match by base name: strip DLC/labeled suffix then look for <base>_FallCount.mat.
% This correctly disambiguates multiple recordings on the same day (different times).
matBase = regexprep(movBase, '\s*DLC_.*$', '');
matBase = regexprep(matBase, '\s*_labeled$', '');
matBase = strtrim(matBase);
directMat = fullfile(movDir, [matBase '_FallCount.mat']);
if exist(directMat, 'file')
    matFile = directMat;
else
    % Fallback: date-based search (handles unlabeled or renamed files)
    movieDate = parseDateFromFilename(movBase);
    matCands  = dir(fullfile(movDir, '*_FallCount.mat'));
    for jj = 1:length(matCands)
        matDate = parseDateFromFilename(matCands(jj).name);
        if ~isnat(movieDate) && ~isnat(matDate) && movieDate == matDate
            matFile = fullfile(matCands(jj).folder, matCands(jj).name);
            break;
        end
    end
end
fallConfFrames = []; holdConfFrames = [];
if ~isempty(matFile)
    try
        Sm = load(matFile);
        if isfield(Sm, 'distance_mm_filtered')
            distData = double(Sm.distance_mm_filtered(:));
        end
        if isfield(Sm, 'distance_mm')
            distRaw = double(Sm.distance_mm(:));
        end
        if isfield(Sm, 'distanceZ_mm_filtered')
            distZ = double(Sm.distanceZ_mm_filtered(:));
            distZFiltered = true;
        elseif isfield(Sm, 'distanceZ_mm')
            distZ = double(Sm.distanceZ_mm(:));
        end
        if isfield(Sm, 'fall_confidence_frames')
            fallConfFrames = double(Sm.fall_confidence_frames(:));
        end
        if isfield(Sm, 'hold_confidence_frames')
            holdConfFrames = double(Sm.hold_confidence_frames(:));
        end
    catch ME
        fprintf('playBehaviorVideo: could not load %s: %s\n', matFile, ME.message);
    end
end

% Left forelimb distance (loaded separately to keep right-side variables clean)
distData_L = [];
if ~isempty(matFile)
    try
        SmL = load(matFile, 'distance_mm_filtered_L', 'distance_mm_L');
        if isfield(SmL, 'distance_mm_filtered_L')
            distData_L = double(SmL.distance_mm_filtered_L(:));
        elseif isfield(SmL, 'distance_mm_L')
            distData_L = double(SmL.distance_mm_L(:));
        end
    catch, end
else
    fprintf('playBehaviorVideo: no *_FallCount.mat found in %s\n', movDir);
end

% ── Load / initialise correction state ────────────────────────────────────
correctionPath = '';
corrections    = struct('start_frame',{},'end_frame',{},'label',{},'features',{});
if ~isempty(matFile)
    correctionPath = strrep(matFile, '_FallCount.mat', '_corrections.mat');
    if exist(correctionPath, 'file')
        try
            Sc = load(correctionPath);
            if isfield(Sc, 'corrections'), corrections = Sc.corrections; end
        catch, end
    end
end

% ── Migrate legacy category names ─────────────────────────────────────────
LEGACY_MERGE = {'HoldCaseEgde','HoldCaseEdge'};   % both spellings → 'Case Holding'
for kk = 1:length(corrections)
    if any(strcmp(corrections(kk).label, LEGACY_MERGE))
        corrections(kk).label = 'Case Holding';
    end
end

% ── Correction category list ───────────────────────────────────────────────
corrCatDefaults = {'Fall', 'Case Holding', 'Regular Hold', 'Release', 'OtherNormBehavior'};
customCats = loadSharedCustomCats();
% Remove legacy names from persisted custom list (only write back if something changed)
nBefore = length(customCats);
customCats = customCats(~cellfun(@(c) any(strcmp(c, LEGACY_MERGE)), customCats));
% Drop any custom entries that duplicate a built-in default (e.g. a name
% later promoted to a default), so it isn't listed twice in the dropdown.
customCats = customCats(~ismember(customCats, corrCatDefaults));
if length(customCats) < nBefore
    saveSharedCustomCats(customCats);
end
corrCatAll = [corrCatDefaults, customCats];
% Color map (struct: safe field-name → [r g b])
corrColorSrc = {'Fall',[1 0.2 0.2]; 'Case Holding',[1 0.55 0]; ...
                'Regular Hold',[0.2 0.75 0.2]; 'Release',[0.6 0.6 0.6]; ...
                'OtherNormBehavior',[0.2 0.45 0.85]};
autoColors   = {[0.4 0.4 0.9],[0.9 0.4 0.9],[0.4 0.9 0.9],[0.9 0.9 0.4]};
corrColorMap = struct();
for ci = 1:size(corrColorSrc,1)
    corrColorMap.(matlab.lang.makeValidName(corrColorSrc{ci,1})) = corrColorSrc{ci,2};
end
for ci = 1:length(customCats)
    fn = matlab.lang.makeValidName(customCats{ci});
    if ~isfield(corrColorMap, fn)
        corrColorMap.(fn) = autoColors{mod(ci-1,4)+1};
    end
end

% ── Load LVM behavioral data ──────────────────────────────────────────────
bd      = getappdata(fig7, 'selBehData');
lvmData = struct('tSec',[],'leverR',[],'rewardTimes',[],'pullTimes',[],'triggerTimes',[]);
if ~isempty(matFile)
    lvmData = loadLVMForSession(matFile, bd.ID);
end
hasLVM  = ~isempty(lvmData.tSec);

% ── Figure layout ─────────────────────────────────────────────────────────
% Left: video  |  Right: distance trace
% Bottom strip: full-width slider + controls + correction panel
pod = getappdata(fig7, 'behPOD_sess');  pod = pod(dayIdx);
figV = figure('Name', sprintf('Behavior — %s  POD %d', bd.ID, pod), ...
    'Position', [80 20 1650 860], ...
    'MenuBar', 'none', 'ToolBar', 'none', 'NumberTitle', 'off');
set(figV, 'CloseRequestFcn', @(~,~) closeVideoFig(figV));

% ── Left: video axes ──────────────────────────────────────────────────────
axV = axes('Parent', figV, 'Position', [0.01 0.185 0.28 0.800]);
axis(axV, 'off');
firstFrame = readFirstFrame(vr, fps_native);
hImg = imshow(firstFrame, 'Parent', axV);

% Status overlay on video (top-left corner of image)
hDistText = text(axV, 0.02, 0.97, '', ...
    'Units', 'normalized', 'FontSize', 18, 'FontWeight', 'bold', ...
    'Color', 'w', 'BackgroundColor', [0 0 0 0.5], ...
    'VerticalAlignment', 'top', 'HorizontalAlignment', 'left', ...
    'Tag', 'distOverlay');

% ── Right: distance trace axes ───────────────────────────────────────────
hasTrace = ~isempty(distData);
if hasTrace
    % Use camera trigger times as true frame time axis when available.
    % Fallback priority: LVM-derived fps (nFrames/lvm_duration) > mp4 header fps.
    nDist = length(distData);
    if hasLVM && length(lvmData.triggerTimes) == nDist
        tSec = lvmData.triggerTimes;
        fprintf('playBehaviorVideo: using %d LVM trigger times for time axis\n', nDist);
    elseif hasLVM && ~isempty(lvmData.tSec) && lvmData.tSec(end) > 0 && nDist > 0
        lvm_fps = nDist / lvmData.tSec(end);
        tSec = (0:nDist-1)' / lvm_fps;
        fprintf('playBehaviorVideo: no matching triggers (%d found, %d needed) — LVM-derived fps = %.4f\n', ...
            length(lvmData.triggerTimes), nDist, lvm_fps);
    else
        tSec = (0:nDist-1)' / distFps;
        fprintf('playBehaviorVideo: no LVM — using mp4 fps = %.4f\n', distFps);
    end
    yMax    = max(max(distData, [], 'omitnan') * 1.1, 10);
    yMin    = 0;

    if hasLVM
        axD = axes('Parent', figV, 'Position', [0.34 0.315 0.64 0.670]);
    else
        axD = axes('Parent', figV, 'Position', [0.34 0.202 0.64 0.783]);
    end
    hold(axD, 'on');
    if hasLVM
        axSeg = axes('Parent', figV, 'Position', [0.34 0.290 0.64 0.022], ...
            'XTick', [], 'YTick', [], 'Box', 'off', 'Color', [0.92 0.92 0.92]);
    else
        axSeg = axes('Parent', figV, 'Position', [0.34 0.176 0.64 0.022], ...
            'XTick', [], 'YTick', [], 'Box', 'off', 'Color', [0.92 0.92 0.92]);
    end

    % distanceZ_mm — lighter trace behind
    if ~isempty(distZ) && length(distZ) == length(distData)
        tSecZ = tSec;   % same frames as distData — use trigger-based time axis
        if distZFiltered
            distZLabel = 'distanceZ (filtered)';
        else
            distZLabel = 'distanceZ (raw)';
        end
        plot(axD, tSecZ, distZ, 'Color', [0.7 0.7 0.7], 'LineWidth', 0.8, ...
            'DisplayName', distZLabel);
        posZ = distZ(distZ > 0 & isfinite(distZ));
        if ~isempty(posZ), yMax = max(yMax, max(posZ) * 1.1); end
        negZ = distZ(distZ < 0 & isfinite(distZ));
        if ~isempty(negZ), yMin = min(yMin, min(negZ) * 1.1); end
    end
    yLimD = [yMin, yMax];

    % ── Segment color strip drawn later via buildSegmentImage (in axSeg) ────
    FALL_THR = 7.5;  HOLD_THR = 5.0;

    % ── Fall-count crossing markers (▼ at top of plot) ───────────────────
    crossUp = find(distData(1:end-1) <= FALL_THR & distData(2:end) > FALL_THR);
    if ~isempty(crossUp)
        plot(axD, tSec(crossUp), repmat(yLimD(2) * 0.97, size(crossUp)), ...
            'rv', 'MarkerSize', 7, 'MarkerFaceColor', [0.85 0 0], ...
            'LineStyle', 'none', 'Tag', 'crossUpMarker', ...
            'DisplayName', sprintf('Fall count (%d)', numel(crossUp)));
    end

    % distance_mm — unfiltered trace (thin, behind filtered)
    if ~isempty(distRaw) && length(distRaw) == length(distData)
        plot(axD, tSec, distRaw, 'Color', [0.75 0.85 1.0], 'LineWidth', 0.6, ...
            'DisplayName', 'distance (raw)');
    end

    % distance_mm_filtered — main trace (right forelimb)
    plot(axD, tSec, distData, 'Color', [0.2 0.4 0.8], 'LineWidth', 1.2, ...
        'DisplayName', 'R distance (filtered)');

    % Left forelimb distance overlay (if available)
    if ~isempty(distData_L) && length(distData_L) == length(distData)
        plot(axD, tSec, distData_L, 'Color', [0.85 0.35 0], 'LineWidth', 1.0, ...
            'LineStyle', '--', 'DisplayName', 'L distance (filtered)');
        yMax = max(yMax, max(distData_L, [], 'omitnan') * 1.1);
        yLimD = [yMin, yMax];
    end

    % Threshold lines
    plot(axD, [tSec(1) tSec(end)], [FALL_THR FALL_THR], 'r--', 'LineWidth', 1.2, ...
        'HandleVisibility', 'off');
    plot(axD, [tSec(1) tSec(end)], [HOLD_THR HOLD_THR], 'Color', [0 0.6 0], ...
        'LineStyle', '--', 'LineWidth', 1.2, 'HandleVisibility', 'off');
    text(axD, tSec(end)*0.02, FALL_THR + 0.3, '7.5 mm  fall', 'FontSize', 12, 'Color', 'r');
    text(axD, tSec(end)*0.02, HOLD_THR + 0.3, '5.0 mm  hold', 'FontSize', 12, 'Color', [0 0.5 0]);

    xlabel(axD, 'Time (s)');
    ylabel(axD, 'Distance from lever (mm)');
    title(axD, sprintf('%s  POD %d', bd.ID, pod), 'FontSize', 14);
    legend(axD, 'Location', 'northeast', 'FontSize', 11);
    set(axD, 'TickDir', 'out', 'Box', 'off', 'YLim', yLimD, 'FontSize', 11);
    % ── Scale bar: 1 sec ─────────────────────────────────────────────────
    sbX2D = tSec(end) - 0.2;   sbX1D = sbX2D - 60.0;
    sbYD  = yLimD(1) + (yLimD(2)-yLimD(1)) * 0.04;
    sbTkD = (yLimD(2)-yLimD(1)) * 0.035;
    line(axD, [sbX1D sbX2D], [sbYD sbYD], 'Color','k','LineWidth',2, ...
        'HandleVisibility','off','Tag','scaleBar');
    line(axD, [sbX1D sbX2D; sbX1D sbX2D], [sbYD sbYD; sbYD+sbTkD sbYD+sbTkD], ...
        'Color','k','LineWidth',2,'HandleVisibility','off','Tag','scaleBar');
    text(axD, (sbX1D+sbX2D)/2, sbYD + sbTkD*2.2, '1 min', ...
        'FontSize', 11, 'HorizontalAlignment','center','Tag','scaleBar');
    hCursor = plot(axD, [tSec(1) tSec(1)], yLimD, '-', 'Color', [1 0.5 0], ...
        'LineWidth', 2.5, 'HandleVisibility', 'off', 'Tag', 'cursorLine');
    hCursorDot = plot(axD, tSec(1), distData(1), 'o', 'Color', [1 0.5 0], ...
        'MarkerFaceColor', [1 0.5 0], 'MarkerSize', 7, ...
        'HandleVisibility', 'off', 'Tag', 'cursorDot');

    % ── LVM lever panel (axL) ────────────────────────────────────────────
    axL = [];
    if hasLVM
        axL = axes('Parent', figV, 'Position', [0.34 0.177 0.64 0.110]);
        hold(axL, 'on');
        tLVM = lvmData.tSec;
        plot(axL, tLVM, lvmData.leverR, 'Color', [0.5 0.5 0.5], 'LineWidth', 0.8, ...
            'DisplayName', 'Lever');
        set(axL, 'TickDir', 'out', 'Box', 'off', 'FontSize', 11);
        ylLVM = ylim(axL);
        ySpan = max(ylLVM(2) - ylLVM(1), 0.1);
        if ~isempty(lvmData.rewardTimes)
            yRew = repmat(ylLVM(2) - ySpan * 0.05, size(lvmData.rewardTimes));
            plot(axL, lvmData.rewardTimes, yRew, 'g^', ...
                'MarkerSize', 5, 'MarkerFaceColor', [0 0.7 0], 'LineStyle', 'none', ...
                'DisplayName', sprintf('Reward (%d)', numel(lvmData.rewardTimes)));
        end
        if ~isempty(lvmData.pullTimes)
            yPull = repmat(ylLVM(2) - ySpan * 0.20, size(lvmData.pullTimes));
            plot(axL, lvmData.pullTimes, yPull, 'rv', ...
                'MarkerSize', 5, 'MarkerFaceColor', [0.85 0 0], 'LineStyle', 'none', ...
                'DisplayName', sprintf('Pull onset (%d)', numel(lvmData.pullTimes)));
        end
        ylabel(axL, 'Lever (V)', 'FontSize', 11);
        legend(axL, 'Location', 'northeast', 'FontSize', 9);
        % End-of-LVM marker: filled triangle at top of lever axis
        ylLVM2 = ylim(axL);
        plot(axL, tLVM(end), ylLVM2(2), 'kv', ...
            'MarkerSize', 8, 'MarkerFaceColor', [0.2 0.2 0.2], ...
            'LineStyle', 'none', 'HandleVisibility', 'off', 'Tag', 'lvmEndMarker');
        % ── Scale bar: 1 sec ─────────────────────────────────────────────
        sbX2L = tLVM(end) - 0.2;   sbX1L = sbX2L - 60.0;
        sbYL  = ylLVM2(1) + (ylLVM2(2)-ylLVM2(1)) * 0.08;
        sbTkL = (ylLVM2(2)-ylLVM2(1)) * 0.10;
        line(axL, [sbX1L sbX2L], [sbYL sbYL], 'Color','k','LineWidth',2, ...
            'HandleVisibility','off','Tag','scaleBar');
        line(axL, [sbX1L sbX2L; sbX1L sbX2L], [sbYL sbYL; sbYL+sbTkL sbYL+sbTkL], ...
            'Color','k','LineWidth',2,'HandleVisibility','off','Tag','scaleBar');
        text(axL, (sbX1L+sbX2L)/2, sbYL + sbTkL*2.0, '1 min', ...
            'FontSize', 11, 'HorizontalAlignment','center','Tag','scaleBar');
        % ── Lever cursor dot ──────────────────────────────────────────────
        hCursorL = plot(axL, tSec(1), lvmData.leverR(1), 'o', 'Color', [1 0.5 0], ...
            'MarkerFaceColor', [1 0.5 0], 'MarkerSize', 7, ...
            'HandleVisibility', 'off', 'Tag', 'cursorDotL');
        linkaxes([axD axSeg axL], 'x');
        xlim(axD, [0, max(tSec(end), tLVM(end))]);
    else
        hCursorL = [];
        linkaxes([axD axSeg], 'x');
    end
else
    axD = []; axSeg = []; axL = []; hCursor = []; hCursorDot = []; hCursorL = []; yLimD = [0 10];
end

% ── Segment / Subsegment navigation buttons (left of slider, same row) ───
% Buttons shrunk to 80% width; slider starts at x=0.34 to align with plots.
uicontrol(figV, 'Style', 'pushbutton', 'String', '◀ Segment', ...
    'Units', 'normalized', 'Position', [0.010 0.150 0.084 0.024], ...
    'FontSize', 12, 'Tag', 'btnSegPrev', ...
    'Callback', @(~,~) stepSegment(figV, -1));
uicontrol(figV, 'Style', 'pushbutton', 'String', 'Segment ▶', ...
    'Units', 'normalized', 'Position', [0.099 0.150 0.084 0.024], ...
    'FontSize', 12, 'Tag', 'btnSegNext', ...
    'Callback', @(~,~) stepSegment(figV, +1));
uicontrol(figV, 'Style', 'pushbutton', 'String', '◀ Subseg', ...
    'Units', 'normalized', 'Position', [0.191 0.150 0.062 0.024], ...
    'FontSize', 12, 'Tag', 'btnSubsegPrev', ...
    'Callback', @(~,~) stepSubsegment(figV, -1));
uicontrol(figV, 'Style', 'pushbutton', 'String', 'Subseg ▶', ...
    'Units', 'normalized', 'Position', [0.258 0.150 0.062 0.024], ...
    'FontSize', 12, 'Tag', 'btnSubsegNext', ...
    'Callback', @(~,~) stepSubsegment(figV, +1));
% ── Subsegment step multiplier buttons (below Subseg▶) ───────────────────
uicontrol(figV, 'Style', 'togglebutton', 'String', 'x1', ...
    'Units', 'normalized', 'Position', [0.258 0.126 0.015 0.020], ...
    'FontSize', 10, 'FontWeight', 'bold', 'Tag', 'btnSubsegMx1', 'Value', 1, ...
    'Callback', @(~,~) setSubsegMultiplier(figV, 1));
uicontrol(figV, 'Style', 'togglebutton', 'String', 'x2', ...
    'Units', 'normalized', 'Position', [0.274 0.126 0.015 0.020], ...
    'FontSize', 10, 'Tag', 'btnSubsegMx2', 'Value', 0, ...
    'Callback', @(~,~) setSubsegMultiplier(figV, 2));
uicontrol(figV, 'Style', 'togglebutton', 'String', 'x4', ...
    'Units', 'normalized', 'Position', [0.290 0.126 0.015 0.020], ...
    'FontSize', 10, 'Tag', 'btnSubsegMx4', 'Value', 0, ...
    'Callback', @(~,~) setSubsegMultiplier(figV, 4));
uicontrol(figV, 'Style', 'togglebutton', 'String', 'x10', ...
    'Units', 'normalized', 'Position', [0.306 0.126 0.016 0.020], ...
    'FontSize', 9, 'Tag', 'btnSubsegMx10', 'Value', 0, ...
    'Callback', @(~,~) setSubsegMultiplier(figV, 10));

% ── Full-width frame slider ───────────────────────────────────────────────
hSlider = uicontrol(figV, 'Style', 'slider', ...
    'Units', 'normalized', 'Position', [0.34 0.150 0.64 0.024], ...
    'Min', 1, 'Max', max(nFrames, 2), 'Value', 1, ...
    'SliderStep', [1/max(nFrames-1,1), min(10/max(nFrames-1,1),1)], ...
    'Callback', @(src,~) seekToFrame(figV, round(get(src,'Value'))));

% ── Controls row ─────────────────────────────────────────────────────────
uicontrol(figV, 'Style', 'pushbutton', 'String', '▶  Play', ...
    'Units', 'normalized', 'Position', [0.01 0.102 0.065 0.044], ...
    'FontSize', 14, 'Tag', 'btnPlay', ...
    'Callback', @(~,~) togglePlay(figV));
uicontrol(figV, 'Style', 'pushbutton', 'String', 'Low', ...
    'Units', 'normalized', 'Position', [0.078 0.102 0.040 0.044], ...
    'FontSize', 14, 'Tag', 'btnFpsLow', ...
    'Callback', @(~,~) scaleFps(figV, 0.5));
uicontrol(figV, 'Style', 'pushbutton', 'String', 'High', ...
    'Units', 'normalized', 'Position', [0.121 0.102 0.040 0.044], ...
    'FontSize', 14, 'Tag', 'btnFpsHigh', ...
    'Callback', @(~,~) scaleFps(figV, 2.0));
uicontrol(figV, 'Style', 'text', 'String', sprintf('%.4g fps', fps_native), ...
    'Units', 'normalized', 'Position', [0.165 0.110 0.09 0.030], ...
    'FontSize', 14, 'Tag', 'txtFps', 'HorizontalAlignment', 'left');
uicontrol(figV, 'Style', 'text', 'String', '', ...
    'Units', 'normalized', 'Position', [0.37 0.110 0.30 0.030], ...
    'FontSize', 14, 'Tag', 'txtFrameInfo', 'HorizontalAlignment', 'left');
uicontrol(figV, 'Style', 'text', 'String', 'Lum:', ...
    'Units', 'normalized', 'Position', [0.68 0.110 0.04 0.030], ...
    'FontSize', 13, 'HorizontalAlignment', 'right');
uicontrol(figV, 'Style', 'slider', ...
    'Units', 'normalized', 'Position', [0.72 0.104 0.24 0.040], ...
    'Min', 0.1, 'Max', 3.0, 'Value', 1.0, ...
    'Tag', 'sliderLum', ...
    'Callback', @(src,~) applyLuminance(figV, src.Value));

% ── Correction panel — Row 1: Label selector + New category + Save/FindRules
uicontrol(figV, 'Style', 'text', 'String', 'Label:', ...
    'Units', 'normalized', 'Position', [0.01 0.062 0.05 0.026], ...
    'FontSize', 12, 'HorizontalAlignment', 'right');
uicontrol(figV, 'Style', 'popup', 'String', corrCatAll, ...
    'Units', 'normalized', 'Position', [0.07 0.055 0.18 0.036], ...
    'FontSize', 12, 'Tag', 'corrPopup');
uicontrol(figV, 'Style', 'text', 'String', 'New:', ...
    'Units', 'normalized', 'Position', [0.26 0.062 0.04 0.026], ...
    'FontSize', 12, 'HorizontalAlignment', 'right');
uicontrol(figV, 'Style', 'edit', 'String', '', ...
    'Units', 'normalized', 'Position', [0.31 0.055 0.14 0.036], ...
    'FontSize', 12, 'Tag', 'corrNewEdit');
uicontrol(figV, 'Style', 'pushbutton', 'String', 'Add', ...
    'Units', 'normalized', 'Position', [0.455 0.050 0.038 0.044], ...
    'FontSize', 12, ...
    'Callback', @(~,~) addCorrectionCategory(figV));
uicontrol(figV, 'Style', 'pushbutton', 'String', 'Find Rules', ...
    'Units', 'normalized', 'Position', [0.500 0.050 0.065 0.044], ...
    'FontSize', 11, ...
    'Callback', @(~,~) findCorrectionRules(figV));
uicontrol(figV, 'Style', 'text', 'String', '', ...
    'Units', 'normalized', 'Position', [0.570 0.055 0.425 0.030], ...
    'FontSize', 12, 'Tag', 'txtCorrStatus', ...
    'HorizontalAlignment', 'left', 'ForegroundColor', [0 0.5 0]);

% ── Correction panel — Row 2: Apply/Undo/Save buttons directly below Label popup
uicontrol(figV, 'Style', 'togglebutton', 'String', 'Apply: Range', ...
    'Units', 'normalized', 'Position', [0.010 0.008 0.055 0.038], ...
    'FontSize', 11, 'Tag', 'btnRangeLabel', 'Value', 0, ...
    'Callback', @(~,~) toggleRangeLabel(figV));
uicontrol(figV, 'Style', 'pushbutton', 'String', 'Apply: Segment', ...
    'Units', 'normalized', 'Position', [0.07 0.008 0.090 0.038], ...
    'FontSize', 11, 'Tag', 'btnApplyCorr', ...
    'Callback', @(~,~) applyCorrection(figV, false));
uicontrol(figV, 'Style', 'pushbutton', 'String', 'Apply: Subsegment', ...
    'Units', 'normalized', 'Position', [0.165 0.008 0.098 0.038], ...
    'FontSize', 11, 'Tag', 'btnApplySubCorr', ...
    'Callback', @(~,~) applyCorrection(figV, true));
uicontrol(figV, 'Style', 'pushbutton', 'String', 'Undo', ...
    'Units', 'normalized', 'Position', [0.268 0.008 0.044 0.038], ...
    'FontSize', 12, ...
    'Callback', @(~,~) undoCorrection(figV));
uicontrol(figV, 'Style', 'pushbutton', 'String', 'Save', ...
    'Units', 'normalized', 'Position', [0.317 0.008 0.040 0.038], ...
    'FontSize', 12, ...
    'Callback', @(~,~) saveCorrectionFile(figV));
uicontrol(figV, 'Style', 'pushbutton', 'String', 'Divide subseg', ...
    'Units', 'normalized', 'Position', [0.362 0.008 0.095 0.038], ...
    'FontSize', 11, 'Tag', 'btnDivideSubseg', ...
    'Callback', @(~,~) divideSubsegment(figV));
uicontrol(figV, 'Style', 'pushbutton', 'String', 'Export labels', ...
    'Units', 'normalized', 'Position', [0.462 0.008 0.090 0.038], ...
    'FontSize', 11, 'Tag', 'btnExportLabels', ...
    'Callback', @(~,~) exportFrameLabels(figV));

% ── Store state ───────────────────────────────────────────────────────────
setappdata(figV, 'vr',        vr);
setappdata(figV, 'nFrames',   nFrames);
setappdata(figV, 'curFrame',  1);
setappdata(figV, 'hImg',      hImg);
setappdata(figV, 'hSlider',   hSlider);
setappdata(figV, 'hCursor',    hCursor);
setappdata(figV, 'hCursorDot', hCursorDot);
setappdata(figV, 'hCursorL',   hCursorL);
setappdata(figV, 'lvmTSec',   lvmData.tSec);
setappdata(figV, 'lvmLeverR', lvmData.leverR);
setappdata(figV, 'axD',       axD);
setappdata(figV, 'axSeg',    axSeg);
setappdata(figV, 'axL',      axL);
setappdata(figV, 'tSec',           tSec);
setappdata(figV, 'distData',       distData);
setappdata(figV, 'fallConfFrames', fallConfFrames);
setappdata(figV, 'holdConfFrames', holdConfFrames);
setappdata(figV, 'distData_L',     distData_L);
setappdata(figV, 'luminance',      1.0);
% Cache distZ and angle_frames so applyCorrection never needs to re-read the mat file
angleFrames = [];
if exist('Sm','var')
    if isfield(Sm, 'distanceZ_mm_filtered')
        setappdata(figV, 'distZ_cached', double(Sm.distanceZ_mm_filtered(:)));
    elseif isfield(Sm, 'distanceZ_mm')
        setappdata(figV, 'distZ_cached', double(Sm.distanceZ_mm(:)));
    else
        setappdata(figV, 'distZ_cached', []);
    end
    if isfield(Sm, 'angle_frames')
        angleFrames = double(Sm.angle_frames(:));
    end
else
    setappdata(figV, 'distZ_cached', []);
end
setappdata(figV, 'angleFrames_cached', angleFrames);
setappdata(figV, 'hDistText', hDistText);
setappdata(figV, 'fps_native',fps_native);
setappdata(figV, 'fps',       fps_native);
setappdata(figV, 'isPlaying', false);
setappdata(figV, 'playTimer', []);
setappdata(figV, 'matFile',        matFile);
setappdata(figV, 'correctionPath', correctionPath);
setappdata(figV, 'corrections',    corrections);
setappdata(figV, 'corrColorMap',   corrColorMap);
setappdata(figV, 'undoStack',      {});
setappdata(figV, 'subsegSplits',   []);   % forced split frames (Divide subseg button)
setappdata(figV, 'subsegMultiplier',    1);  % step count for ◀Subseg / Subseg▶ buttons
setappdata(figV, 'rangeLabelStartFrame', []); % start frame for Range toggle labelling
setappdata(figV, 'fig7',           fig7);
setappdata(figV, 'dayIdx',         dayIdx);
setappdata(figV, 'anIdx',          anIdx);
% xLimMax: right edge for all linked axes.
% Must be >= tSec(end) (last distance frame) AND >= lvmData.tSec(end) (LVM end / triangle).
if hasLVM
    xLimMax = max(tSec(end), lvmData.tSec(end));
else
    xLimMax = tSec(end);
end
setappdata(figV, 'xLimMax', xLimMax);

% Draw any pre-existing correction overlays
refreshCorrectionOverlay(figV);   % also calls buildSegmentStarts/buildSubsegmentStarts
% Restore xlim after refresh (buildSegmentImage resets it to tSec(end))
if ~isempty(axD) && isgraphics(axD)
    xlim(axD, [0, xLimMax]);
end

% If this session already has saved corrections, recompute and preview
% their effect immediately (same computation "Save" runs) instead of
% leaving the status text blank until the user re-saves. Without this, a
% session reopened with pre-existing corrections looks unchanged even
% though the correction segments (drawn above) are correctly loaded.
if ~isempty(corrections)
    applyCorrectionsToBehData(figV);
end

updateFrameInfo(figV, 1, nFrames, fps_native);
end

% ── Video player helpers ───────────────────────────────────────────────────

function drawMaskRegions(ax, t, mask, ylims, color, alpha, labelStr)
% Shade contiguous regions where mask is true using patch calls.
% All patches are tagged 'confPatch' so they can be deleted and redrawn
% when corrections are applied.
mask = logical(mask(:));
d      = diff([false; mask; false]);
starts = find(d ==  1);
ends   = find(d == -1) - 1;
ylo = ylims(1);  yhi = ylims(2);
for k = 1:length(starts)
    ts = t(starts(k));
    te = t(min(ends(k), length(t)));
    hv = 'off';
    if k == 1, hv = 'on'; end
    patch(ax, [ts te te ts], [ylo ylo yhi yhi], color, ...
        'FaceAlpha', alpha, 'EdgeColor', 'none', ...
        'DisplayName', labelStr, 'HandleVisibility', hv, ...
        'Tag', 'confPatch');
end
end

function buildSegmentImage(figV)
% Render a single 1-row imagesc strip in axSeg showing segment classification.
% Fall confidence levels → shades of red; Hold → shades of green;
% Corrections → their assigned color; Transition frames → light gray.
% This replaces hundreds of patch objects with one image object.
if ~isgraphics(figV, 'figure'), return; end
axSeg          = getappdata(figV, 'axSeg');
distData       = getappdata(figV, 'distData');
fallConfFrames = getappdata(figV, 'fallConfFrames');
holdConfFrames = getappdata(figV, 'holdConfFrames');
corrections    = getappdata(figV, 'corrections');
corrColorMap   = getappdata(figV, 'corrColorMap');
fps_native     = getappdata(figV, 'fps_native');
if isempty(axSeg) || ~isgraphics(axSeg) || isempty(distData), return; end

nF = length(distData);
FALL_THR = 7.5;  HOLD_THR = 5.0;

% Start with gray (transition/unknown)
rgb = repmat(reshape([0.82 0.82 0.82], [1 1 3]), [1 nF 1]);

% Hold: lightest to darkest (each level overrides the previous)
holdColors = {[0.6 1 0.6],[0.3 0.85 0.3],[0.1 0.6 0.1]};
if ~isempty(holdConfFrames) && length(holdConfFrames) == nF
    for c = 1:3
        m = holdConfFrames(:)' >= c;
        if ~any(m), continue; end
        clr = holdColors{c};
        for ch = 1:3, rgb(1, m, ch) = clr(ch); end
    end
else
    m = distData(:)' < HOLD_THR;
    clr = holdColors{2};
    for ch = 1:3, rgb(1, m, ch) = clr(ch); end
end

% Fall: lightest to darkest (each level overrides the previous)
fallColors = {[1 0.6 0.6],[1 0.4 0.4],[1 0.2 0.2],[0.7 0 0]};
if ~isempty(fallConfFrames) && length(fallConfFrames) == nF
    for c = 1:4
        m = fallConfFrames(:)' >= c;
        if ~any(m), continue; end
        clr = fallColors{c};
        for ch = 1:3, rgb(1, m, ch) = clr(ch); end
    end
else
    m = distData(:)' > FALL_THR;
    clr = fallColors{2};
    for ch = 1:3, rgb(1, m, ch) = clr(ch); end
end

% Correction overrides (solid color, drawn last)
for k = 1:length(corrections)
    sf  = max(1, corrections(k).start_frame);
    ef  = min(nF, corrections(k).end_frame);
    lbl = corrections(k).label;
    clr = [0.5 0.5 0.8];
    fn  = matlab.lang.makeValidName(lbl);
    if ~isempty(corrColorMap) && isfield(corrColorMap, fn)
        clr = corrColorMap.(fn);
    end
    for ch = 1:3, rgb(1, sf:ef, ch) = clr(ch); end
end

% Update the strip: reuse existing imagesc object if present (much faster than delete+recreate)
tSecAll = getappdata(figV, 'tSec');
if ~isempty(tSecAll) && length(tSecAll) == nF
    tSec = tSecAll;
else
    tSec = (0:nF-1) / fps_native;
end
xLimMax = getappdata(figV, 'xLimMax');
if isempty(xLimMax), xLimMax = tSec(end); end
hStrip = findobj(axSeg, 'Tag', 'segStrip');
if ~isempty(hStrip) && isgraphics(hStrip(1)) && ...
        size(get(hStrip(1),'CData'), 2) == nF
    set(hStrip(1), 'CData', rgb);
else
    delete(hStrip);
    imagesc(axSeg, [tSec(1) xLimMax], [0 1], rgb, 'Tag', 'segStrip');
end
set(axSeg, 'YTick', [], 'XTick', [], 'Box', 'off', 'YLim', [0 1], ...
    'XLim', [tSec(1) xLimMax]);
end

function frame = readFirstFrame(vr, fps_native)
% Read the very first frame safely.
try
    vr.CurrentTime = 0;
    if hasFrame(vr), frame = readFrame(vr); return; end
catch, end
frame = zeros(max(vr.Height,1), max(vr.Width,1), 3, 'uint8');
end

function seekToFrame(figV, frameNum)
if ~isgraphics(figV, 'figure'), return; end
nFrames   = getappdata(figV, 'nFrames');
vr        = getappdata(figV, 'vr');
hImg      = getappdata(figV, 'hImg');
hSlider   = getappdata(figV, 'hSlider');
hCursor   = getappdata(figV, 'hCursor');
fps_native = getappdata(figV, 'fps_native');
frameNum = max(1, min(round(frameNum), nFrames));
setappdata(figV, 'curFrame', frameNum);
try
    vr.CurrentTime = (frameNum - 1) / fps_native;
    if hasFrame(vr)
        frame = readFrame(vr);
        lum = getappdata(figV, 'luminance');
        if ~isempty(lum) && lum ~= 1.0
            frame = uint8(min(double(frame) * lum, 255));
        end
        set(hImg, 'CData', frame);
    end
catch, end
set(hSlider, 'Value', frameNum);
if ~isempty(hCursor) && isgraphics(hCursor)
    tSecAll = getappdata(figV, 'tSec');
    if ~isempty(tSecAll) && frameNum <= length(tSecAll)
        tSec = tSecAll(frameNum);
    else
        tSec = (frameNum - 1) / fps_native;
    end
    axD        = getappdata(figV, 'axD');
    hCursorDot = getappdata(figV, 'hCursorDot');
    if ~isempty(axD) && isgraphics(axD)
        yl = ylim(axD);
        set(hCursor, 'XData', [tSec tSec], 'YData', yl);
        % Move dot to the filtered distance value at this frame
        if ~isempty(hCursorDot) && isgraphics(hCursorDot)
            distData = getappdata(figV, 'distData');
            if ~isempty(distData) && frameNum <= length(distData)
                dval = distData(frameNum);
            else
                dval = mean(yl);
            end
            set(hCursorDot, 'XData', tSec, 'YData', dval);
        end
    else
        set(hCursor, 'XData', [tSec tSec]);
    end
    % Update lever cursor dot
    hCursorL = getappdata(figV, 'hCursorL');
    if ~isempty(hCursorL) && isgraphics(hCursorL)
        lvmTSec   = getappdata(figV, 'lvmTSec');
        lvmLeverR = getappdata(figV, 'lvmLeverR');
        if ~isempty(lvmTSec) && ~isempty(lvmLeverR)
            [~, idx] = min(abs(lvmTSec - tSec));
            set(hCursorL, 'XData', lvmTSec(idx), 'YData', lvmLeverR(idx));
        else
            set(hCursorL, 'XData', tSec, 'YData', 0);
        end
        uistack(hCursorL, 'top');
    end
    % Keep cursor on top of all patches
    uistack([hCursor; hCursorDot(isgraphics(hCursorDot))], 'top');
end
updateFrameInfo(figV, frameNum, nFrames, fps_native);

% ── Distance overlay on video ─────────────────────────────────────────────
distData       = getappdata(figV, 'distData');
fallConfFrames = getappdata(figV, 'fallConfFrames');
holdConfFrames = getappdata(figV, 'holdConfFrames');
hDistText      = getappdata(figV, 'hDistText');
if ~isempty(distData) && ~isempty(hDistText) && isgraphics(hDistText)
    fi = min(frameNum, length(distData));
    d  = distData(fi);

    % Get per-frame confidence if available
    fConf = 0;  hConf = 0;
    if ~isempty(fallConfFrames) && fi <= length(fallConfFrames)
        fConf = fallConfFrames(fi);
    end
    if ~isempty(holdConfFrames) && fi <= length(holdConfFrames)
        hConf = holdConfFrames(fi);
    end

    % Check for manual correction at this frame
    corrLbl = '';
    corrections = getappdata(figV, 'corrections');
    if ~isempty(corrections)
        for kc = 1:length(corrections)
            if fi >= corrections(kc).start_frame && fi <= corrections(kc).end_frame
                corrLbl = corrections(kc).label;
                break;
            end
        end
    end

    confLabels = {'(weak)','(maybe)','(medium)','(strong)'};
    if ~isempty(corrLbl)
        % Manual correction takes precedence — show in orange box
        corrColorMap = getappdata(figV, 'corrColorMap');
        clr = [1 0.55 0];
        fn  = matlab.lang.makeValidName(corrLbl);
        if ~isempty(corrColorMap) && isfield(corrColorMap, fn)
            clr = corrColorMap.(fn);
        end
        str = sprintf('✎ %s\n%.1f mm', corrLbl, d);
    elseif fConf > 0
        clr = [1 0.3 0.3];
        str = sprintf('● FALL [%d] %s\n%.1f mm', fConf, confLabels{fConf}, d);
    elseif hConf > 0
        clr = [0.3 1.0 0.3];
        str = sprintf('● HOLD [%d] %s\n%.1f mm', hConf, confLabels{min(hConf,4)}, d);
    elseif d > 7.5
        clr = [1 0.5 0.5];
        str = sprintf('● FALL [?]\n%.1f mm', d);
    elseif d < 5.0
        clr = [0.5 1.0 0.5];
        str = sprintf('● HOLD [?]\n%.1f mm', d);
    else
        clr = [1 0.9 0.2];
        str = sprintf('%.1f mm', d);
    end
    set(hDistText, 'String', str, 'Color', clr);
end

drawnow limitrate;
end

function updateFrameInfo(figV, frameNum, nFrames, fps)
hTxt = findobj(figV, 'Tag', 'txtFrameInfo');
if isempty(hTxt), return; end
tSec = (frameNum - 1) / fps;
set(hTxt, 'String', sprintf('Frame %d / %d   %.2f s', frameNum, nFrames, tSec));
end

function togglePlay(figV)
if ~isgraphics(figV, 'figure'), return; end
isPlaying = getappdata(figV, 'isPlaying');
if isPlaying
    tim = getappdata(figV, 'playTimer');
    if ~isempty(tim) && isvalid(tim), stop(tim); delete(tim); end
    setappdata(figV, 'isPlaying', false);
    setappdata(figV, 'playTimer', []);
    hBtn = findobj(figV, 'Tag', 'btnPlay');
    if ~isempty(hBtn), set(hBtn, 'String', '▶  Play'); end
else
    fps        = getappdata(figV, 'fps');
    fps_native = getappdata(figV, 'fps_native');
    if isempty(fps) || fps <= 0, fps = 60; end
    if isempty(fps_native) || fps_native <= 0, fps_native = 60; end
    setappdata(figV, 'isPlaying', true);
    hBtn = findobj(figV, 'Tag', 'btnPlay');
    if ~isempty(hBtn), set(hBtn, 'String', '⏸  Pause'); end
    % Timer fires at native fps rate (capped at ~60 Hz display limit).
    % Frame step > 1 when fps exceeds native, achieving true speed-up by skipping frames.
    timerFps = min(fps, fps_native);
    period   = max(0.016, 1/timerFps);
    tim = timer('ExecutionMode', 'fixedRate', 'Period', period, ...
        'TimerFcn', @(~,~) advanceFrame(figV));
    setappdata(figV, 'playTimer', tim);
    start(tim);
end
end

function advanceFrame(figV)
if ~isgraphics(figV, 'figure')
    return
end
nFrames    = getappdata(figV, 'nFrames');
curFrame   = getappdata(figV, 'curFrame');
fps        = getappdata(figV, 'fps');
fps_native = getappdata(figV, 'fps_native');
if isempty(fps) || fps <= 0, fps = 60; end
if isempty(fps_native) || fps_native <= 0, fps_native = 60; end
% Skip frames proportionally when playing faster than native.
frameStep = max(1, round(fps / fps_native));
if curFrame >= nFrames
    togglePlay(figV); return
end
seekToFrame(figV, min(curFrame + frameStep, nFrames));
end

function scaleFps(figV, factor)
% Multiply current FPS by factor (0.5 = half, 2.0 = double).
if ~isgraphics(figV, 'figure'), return; end
fps = getappdata(figV, 'fps');
fps = max(0.25, fps * factor);   % floor at 0.25 fps
setappdata(figV, 'fps', fps);
hTxt = findobj(figV, 'Tag', 'txtFps');
if ~isempty(hTxt), set(hTxt, 'String', sprintf('%.4g fps', fps)); end
if getappdata(figV, 'isPlaying')
    togglePlay(figV);   % stop
    togglePlay(figV);   % restart with new period
end
end

function closeVideoFig(figV)
if ~isgraphics(figV, 'figure'), return; end
tim = getappdata(figV, 'playTimer');
if ~isempty(tim) && isvalid(tim), stop(tim); delete(tim); end
delete(figV);
end

function applyLuminance(figV, val)
if ~isgraphics(figV, 'figure'), return; end
setappdata(figV, 'luminance', val);
seekToFrame(figV, getappdata(figV, 'curFrame'));
end

% ── Manual correction helpers ──────────────────────────────────────────────

function autoLbl = getFrameAutoLabel(distData, fallConfFrames, holdConfFrames, fi)
% Return the auto-classified label for frame fi.
FALL_THR = 7.5;  HOLD_THR = 5.0;
autoLbl = 'Transition';
if ~isempty(fallConfFrames) && fi <= length(fallConfFrames) && fallConfFrames(fi) > 0
    autoLbl = 'Fall';
elseif ~isempty(holdConfFrames) && fi <= length(holdConfFrames) && holdConfFrames(fi) > 0
    autoLbl = 'Regular Hold';
elseif ~isempty(distData) && fi <= length(distData)
    if distData(fi) > FALL_THR,     autoLbl = 'Fall';
    elseif distData(fi) < HOLD_THR, autoLbl = 'Regular Hold';
    end
end
end

function exportFrameLabels(figV)
% "Export labels" button on the Behavior figure: write per-frame label
% codes for the current session to a sharable triplet of files in the
% movie folder:
%   <session>_labels.mat  — labels (uint16, length nFrames) + labelNames
%                            (cell) + fps + nFrames + movieFile
%   <session>_labels.npy  — same labels array, NumPy little-endian uint16
%                            for collaborators in Python
%   <session>_labels.txt  — human-readable "code  name" mapping
%
% Per-frame label = the same value the segment strip shows: if a
% correction covers the frame, its label wins; otherwise the auto label
% (Fall / Regular Hold / Transition) from getFrameAutoLabel. Codes are
% canonical so they're identical across sessions: 0=Transition,
% 1=Fall, 2=Case Holding, 3=Regular Hold, 4=Release, 5..=custom labels
% (in the order they were added to the shared category list).
distData       = getappdata(figV, 'distData');
fallConfFrames = getappdata(figV, 'fallConfFrames');
holdConfFrames = getappdata(figV, 'holdConfFrames');
corrections    = getappdata(figV, 'corrections');
fps            = getappdata(figV, 'fps_native');
matFile        = getappdata(figV, 'matFile');
if isempty(distData) || isempty(matFile)
    warning('exportFrameLabels: required figure state missing.');
    return
end

nF = length(distData);

% Per-frame correction label (empty string = "use the auto label").
corrLabel = repmat({''}, nF, 1);
for k = 1:length(corrections)
    s = max(1, corrections(k).start_frame);
    e = min(nF, corrections(k).end_frame);
    [corrLabel{s:e}] = deal(corrections(k).label);
end

% Effective label per frame (corrections win; otherwise auto).
effLabel = cell(nF, 1);
for fi = 1:nF
    if ~isempty(corrLabel{fi})
        effLabel{fi} = corrLabel{fi};
    else
        effLabel{fi} = getFrameAutoLabel(distData, fallConfFrames, holdConfFrames, fi);
    end
end

% Canonical code ordering — keep stable across sessions so a code in
% animal A's export means the same thing in animal B's. The built-in
% categories come from drawPopulationFigure (corrCatDefaults), 'Transition'
% is the no-label baseline, customs come last in load order.
labelNames = {'Transition', 'Fall', 'Case Holding', 'Regular Hold', 'Release', 'OtherNormBehavior'};
customCats = loadSharedCustomCats();
for k = 1:numel(customCats)
    if ~any(strcmp(labelNames, customCats{k}))
        labelNames{end+1} = customCats{k}; %#ok<AGROW>
    end
end
% Map any label in effLabel that's NOT already in labelNames into a new
% trailing slot (defensive: a legacy/edited label could exist on a session
% that isn't in the current shared category list).
uniqEff = unique(effLabel(~cellfun('isempty', effLabel)));
for k = 1:numel(uniqEff)
    if ~any(strcmp(labelNames, uniqEff{k}))
        labelNames{end+1} = uniqEff{k}; %#ok<AGROW>
    end
end

% Code map (case-insensitive lookup) + per-frame codes.
nameToCode = containers.Map('KeyType','char','ValueType','double');
for k = 1:numel(labelNames)
    nameToCode(lower(labelNames{k})) = k - 1;   % 0-based codes
end
labels = zeros(nF, 1, 'uint16');
for fi = 1:nF
    key = lower(effLabel{fi});
    if isKey(nameToCode, key)
        labels(fi) = nameToCode(key);
    else
        labels(fi) = 0;   % shouldn't happen after the defensive pass above
    end
end

% Output paths — alongside the source FallCount.mat in the movie folder.
[movDir, base, ~] = fileparts(matFile);
base   = regexprep(base, '_FallCount$', '');   % strip the suffix
matOut = fullfile(movDir, [base '_labels.mat']);
npyOut = fullfile(movDir, [base '_labels.npy']);
txtOut = fullfile(movDir, [base '_labels.txt']);

% --- .mat ----------------------------------------------------------------
movieFile = [base '.mp4']; %#ok<NASGU>   stored for traceability
nFrames   = nF;            %#ok<NASGU>
save(matOut, 'labels', 'labelNames', 'fps', 'nFrames', 'movieFile');

% --- .npy (NumPy v1.0, little-endian uint16, 1-D, C-order) ---------------
writeNpyUint16(npyOut, labels);

% --- .txt mapping ---------------------------------------------------------
fid = fopen(txtOut, 'w');
if fid > 0
    fprintf(fid, '# Per-frame label code -> name (export from %s)\n', base);
    fprintf(fid, '# Format: <code>\\t<name>\n');
    for k = 1:numel(labelNames)
        fprintf(fid, '%d\t%s\n', k - 1, labelNames{k});
    end
    fclose(fid);
end

fprintf('exportFrameLabels: wrote\n  %s\n  %s\n  %s\n', matOut, npyOut, txtOut);
fprintf('  %d frames, %d label codes used: %s\n', nF, ...
    numel(unique(labels)), strjoin(arrayfun(@(c) ...
        sprintf('%d=%s', c, labelNames{c+1}), ...
        unique(labels), 'UniformOutput', false), ', '));
end

function writeNpyUint16(fname, arr)
% Minimal writer for a 1-D uint16 NumPy .npy v1.0 file (little-endian).
% No npy-matlab dependency — just the format spec from numpy docs:
%   magic(6) + version(2) + header_len(uint16 LE) + header(ASCII, '\n'-
%   terminated, space-padded so the total preamble is a multiple of 64) +
%   raw little-endian data.
arr = uint16(arr(:));   % 1-D column → flat
% sprintf with a single-quoted format keeps the result a char array
% (numel == number of characters). Double quotes would return a string
% scalar and numel() would be 1 — wrong for the header length math.
hdrBase = sprintf('{''descr'': ''<u2'', ''fortran_order'': False, ''shape'': (%d,), }', numel(arr));
preamble = 6 + 2 + 2;   % magic + version + header-length field
% Pad header (incl. trailing \n) so preamble+headerLen is a multiple of 64.
hdrLen0  = numel(hdrBase) + 1;
total0   = preamble + hdrLen0;
pad      = mod(-total0, 64);
header   = [hdrBase, repmat(' ', 1, pad), char(10)];

fid = fopen(fname, 'w', 'ieee-le');
if fid < 0, error('writeNpyUint16: cannot open %s for writing', fname); end
cleanup = onCleanup(@() fclose(fid));
fwrite(fid, uint8([147 78 85 77 80 89]), 'uint8');   % \x93 N U M P Y
fwrite(fid, uint8([1 0]),                'uint8');   % v1.0
fwrite(fid, uint16(numel(header)),       'uint16');  % header length (LE)
fwrite(fid, uint8(header),               'uint8');   % header
fwrite(fid, arr,                         'uint16');             % data (LE)
end

function [segStart, segEnd] = findSegmentBounds(distData, fallConfFrames, holdConfFrames, fi)
% Find the contiguous segment with the same auto-label as frame fi.
nF = length(distData);
thisLbl = getFrameAutoLabel(distData, fallConfFrames, holdConfFrames, fi);
segStart = fi;
while segStart > 1
    lbl = getFrameAutoLabel(distData, fallConfFrames, holdConfFrames, segStart-1);
    if ~strcmp(lbl, thisLbl), break; end
    segStart = segStart - 1;
end
segEnd = fi;
while segEnd < nF
    lbl = getFrameAutoLabel(distData, fallConfFrames, holdConfFrames, segEnd+1);
    if ~strcmp(lbl, thisLbl), break; end
    segEnd = segEnd + 1;
end
end

function toggleRangeLabel(figV)
% Range toggle button callback.
% First press (ON):  record the current frame as the range start.
% Second press (OFF): apply the selected label to [start, current] frame range
%                     (direction-independent — works forward AND backward).
if ~isgraphics(figV, 'figure'), return; end
hBtn = findobj(figV, 'Tag', 'btnRangeLabel');
if isempty(hBtn), return; end
hSt  = findobj(figV, 'Tag', 'txtCorrStatus');

if get(hBtn, 'Value') == 1
    % ── Turned ON: mark start frame ──────────────────────────────────────
    curFrame = getappdata(figV, 'curFrame');
    setappdata(figV, 'rangeLabelStartFrame', curFrame);
    set(hBtn, 'FontWeight', 'bold');
    if ~isempty(hSt)
        set(hSt, 'String', sprintf('Range start: frame %d — navigate then press Range again', curFrame));
    end
else
    % ── Turned OFF: apply label over [startFrame, curFrame] ──────────────
    startFrame = getappdata(figV, 'rangeLabelStartFrame');
    set(hBtn, 'FontWeight', 'normal');
    if isempty(startFrame)
        if ~isempty(hSt), set(hSt, 'String', 'Range: no start frame set'); end
        return;
    end
    curFrame = getappdata(figV, 'curFrame');
    segStart = min(startFrame, curFrame);
    segEnd   = max(startFrame, curFrame);
    setappdata(figV, 'rangeLabelStartFrame', []);

    % Get selected label
    hPop = findobj(figV, 'Tag', 'corrPopup');
    if isempty(hPop), return; end
    cats = get(hPop, 'String');
    selLabel = cats{get(hPop, 'Value')};

    % Save undo snapshot
    corrections = getappdata(figV, 'corrections');
    undoStack   = getappdata(figV, 'undoStack');
    undoStack{end+1} = corrections;
    if length(undoStack) > 20, undoStack = undoStack(end-19:end); end
    setappdata(figV, 'undoStack', undoStack);

    % Build feature summary for the range
    fps_native = getappdata(figV, 'fps_native');
    distData   = getappdata(figV, 'distData');
    feat = struct('dist_mean',0,'distZ_mean',0,'angle_mean',NaN,'duration_s',0,'dist_max',0);
    if ~isempty(distData) && segEnd <= length(distData)
        seg = distData(segStart:segEnd);
        feat.dist_mean  = mean(seg, 'omitnan');
        feat.dist_max   = max(seg, [], 'omitnan');
        feat.duration_s = (segEnd - segStart + 1) / fps_native;
    end
    dz  = getappdata(figV, 'distZ_cached');
    ang = getappdata(figV, 'angleFrames_cached');
    if ~isempty(dz)  && segEnd <= length(dz)
        feat.distZ_mean = mean(dz(segStart:segEnd),  'omitnan');
    end
    if ~isempty(ang) && segEnd <= length(ang)
        feat.angle_mean = mean(ang(segStart:segEnd), 'omitnan');
    end

    % Remove overlapping corrections, add new one
    keep = true(1, length(corrections));
    for k = 1:length(corrections)
        if corrections(k).end_frame >= segStart && corrections(k).start_frame <= segEnd
            keep(k) = false;
        end
    end
    corrections = corrections(keep);
    corrections(end+1) = struct('start_frame', segStart, 'end_frame', segEnd, ...
                                'label', selLabel, 'features', feat);
    setappdata(figV, 'corrections', corrections);

    refreshCorrectionOverlay(figV);

    nSeg = segEnd - segStart + 1;
    if ~isempty(hSt)
        set(hSt, 'String', sprintf('Range: applied "%s" to frames %d–%d (%d frames)', ...
            selLabel, segStart, segEnd, nSeg));
    end
end
end

function applyCorrection(figV, useSubsegment)
if nargin < 2, useSubsegment = false; end
if ~isgraphics(figV, 'figure'), return; end
curFrame       = getappdata(figV, 'curFrame');
distData       = getappdata(figV, 'distData');
fallConfFrames = getappdata(figV, 'fallConfFrames');
holdConfFrames = getappdata(figV, 'holdConfFrames');
corrections    = getappdata(figV, 'corrections');
fps_native     = getappdata(figV, 'fps_native');
undoStack      = getappdata(figV, 'undoStack');

% Get selected label from popup
hPop = findobj(figV, 'Tag', 'corrPopup');
if isempty(hPop), return; end
cats = get(hPop, 'String');
selLabel = cats{get(hPop, 'Value')};

% Find segment / subsegment bounds
if ~isempty(distData)
    if useSubsegment
        subsegSplits = getappdata(figV, 'subsegSplits');
        [segStart, segEnd] = findSubsegmentBounds( ...
            distData, fallConfFrames, holdConfFrames, corrections, curFrame, subsegSplits);
    else
        [segStart, segEnd] = findSegmentBounds( ...
            distData, fallConfFrames, holdConfFrames, curFrame);
    end
else
    segStart = curFrame;  segEnd = curFrame;
end

% Save undo snapshot
undoStack{end+1} = corrections;
if length(undoStack) > 20, undoStack = undoStack(end-19:end); end
setappdata(figV, 'undoStack', undoStack);

% Extract summary features for this segment
feat = struct('dist_mean',0,'distZ_mean',0,'angle_mean',NaN,'duration_s',0,'dist_max',0);
if ~isempty(distData)
    seg = distData(segStart:segEnd);
    feat.dist_mean  = mean(seg,'omitnan');
    feat.dist_max   = max(seg,[],'omitnan');
    feat.duration_s = (segEnd - segStart + 1) / fps_native;
end
% Use cached distZ / angle data (loaded once at startup — avoids per-Apply disk read)
dz  = getappdata(figV, 'distZ_cached');
ang = getappdata(figV, 'angleFrames_cached');
if ~isempty(dz) && segEnd <= length(dz)
    feat.distZ_mean = mean(dz(segStart:segEnd), 'omitnan');
end
if ~isempty(ang) && segEnd <= length(ang)
    feat.angle_mean = mean(ang(segStart:segEnd), 'omitnan');
end

% Remove any existing corrections overlapping this range, then add new one
keep = true(1, length(corrections));
for k = 1:length(corrections)
    if corrections(k).end_frame >= segStart && corrections(k).start_frame <= segEnd
        keep(k) = false;
    end
end
corrections = corrections(keep);
newCorr = struct('start_frame', segStart, 'end_frame', segEnd, ...
                 'label', selLabel, 'features', feat);
corrections(end+1) = newCorr;
setappdata(figV, 'corrections', corrections);

refreshCorrectionOverlay(figV);

nSeg = segEnd - segStart + 1;
hSt = findobj(figV, 'Tag', 'txtCorrStatus');
if ~isempty(hSt)
    set(hSt, 'String', sprintf('Applied "%s" to %d frames', selLabel, nSeg));
end

% After labelling a subsegment, advance to the next subsegment automatically.
if useSubsegment
    stepSubsegment(figV, +1);
else
    seekToFrame(figV, curFrame);  % refresh overlay text
end
end

function undoCorrection(figV)
if ~isgraphics(figV, 'figure'), return; end
undoStack = getappdata(figV, 'undoStack');
if isempty(undoStack)
    hSt = findobj(figV, 'Tag', 'txtCorrStatus');
    if ~isempty(hSt), set(hSt,'String','Nothing to undo'); end
    return;
end
corrections = undoStack{end};
undoStack   = undoStack(1:end-1);
setappdata(figV, 'corrections', corrections);
setappdata(figV, 'undoStack',   undoStack);
refreshCorrectionOverlay(figV);
axD = getappdata(figV, 'axD');
xLimMax = getappdata(figV, 'xLimMax');
if ~isempty(axD) && isgraphics(axD) && ~isempty(xLimMax)
    xlim(axD, [0, xLimMax]);
end
seekToFrame(figV, getappdata(figV,'curFrame'));
hSt = findobj(figV, 'Tag', 'txtCorrStatus');
if ~isempty(hSt), set(hSt,'String','Undo done'); end
end

function addCorrectionCategory(figV)
if ~isgraphics(figV, 'figure'), return; end
hEdit = findobj(figV, 'Tag', 'corrNewEdit');
hPop  = findobj(figV, 'Tag', 'corrPopup');
if isempty(hEdit) || isempty(hPop), return; end
newName = strtrim(get(hEdit, 'String'));
if isempty(newName), return; end
current = get(hPop, 'String');
if ismember(newName, current)
    set(hEdit, 'String', '');  return;
end
current{end+1} = newName;
set(hPop, 'String', current, 'Value', length(current));
set(hEdit, 'String', '');
% Add auto-color
corrColorMap = getappdata(figV, 'corrColorMap');
autoColors   = {[0.4 0.4 0.9],[0.9 0.4 0.9],[0.4 0.9 0.9],[0.9 0.9 0.4]};
fn = matlab.lang.makeValidName(newName);
if ~isfield(corrColorMap, fn)
    nCustom = length(fieldnames(corrColorMap));
    corrColorMap.(fn) = autoColors{mod(nCustom,4)+1};
    setappdata(figV, 'corrColorMap', corrColorMap);
end
% Persist to shared file (visible to all PCs)
saved = loadSharedCustomCats();
if ~ismember(newName, saved)
    saved{end+1} = newName;
    saveSharedCustomCats(saved);
end
hSt = findobj(figV, 'Tag', 'txtCorrStatus');
if ~isempty(hSt), set(hSt,'String',sprintf('Added category "%s"', newName)); end
end

function saveCorrectionFile(figV)
if ~isgraphics(figV, 'figure'), return; end
correctionPath = getappdata(figV, 'correctionPath');
corrections    = getappdata(figV, 'corrections');
if isempty(correctionPath)
    hSt = findobj(figV, 'Tag', 'txtCorrStatus');
    if ~isempty(hSt), set(hSt,'String','No FallCount.mat — cannot save'); end
    return;
end
try
    save(correctionPath, 'corrections', '-v7');
    hSt = findobj(figV, 'Tag', 'txtCorrStatus');
    n   = length(corrections);
    if ~isempty(hSt), set(hSt,'String',sprintf('Saved %d correction(s)', n)); end
catch ME
    hSt = findobj(figV, 'Tag', 'txtCorrStatus');
    if ~isempty(hSt), set(hSt,'String',['Save error: ' ME.message]); end
    return;
end
% Update Single Animal figure with corrected metrics
applyCorrectionsToBehData(figV);
end

function applyCorrectionsToBehData(figV)
% Recompute FallTime/CrossCount for the current session using corrections
% and refresh the Single Animal figure.
if ~isgraphics(figV,'figure'), return; end
hSt    = findobj(figV, 'Tag', 'txtCorrStatus');
fig7   = getappdata(figV, 'fig7');
dayIdx = getappdata(figV, 'dayIdx');
if isempty(fig7) || ~isgraphics(fig7,'figure')
    if ~isempty(hSt), set(hSt,'String','Update skipped: Single Animal figure not found'); end
    return;
end

BehData = getappdata(fig7, 'BehData');
anIdx   = getappdata(figV, 'anIdx');     % index captured when behavior video was opened
if isempty(anIdx)
    hList = findobj(fig7, 'Tag', 'listboxAnimals');
    anIdx = get(hList, 'Value');         % fallback to current listbox
end
if isempty(BehData) || anIdx < 1 || anIdx > length(BehData)
    if ~isempty(hSt), set(hSt,'String','Update skipped: animal index out of range'); end
    return;
end
if isempty(dayIdx) || dayIdx < 1 || dayIdx > length(BehData(anIdx).FT_sess)
    if ~isempty(hSt), set(hSt,'String',sprintf('Update skipped: day index %d out of range (max %d)', ...
        dayIdx, length(BehData(anIdx).FT_sess))); end
    return;
end

corrections = getappdata(figV, 'corrections');
distData    = getappdata(figV, 'distData');
fps_native  = getappdata(figV, 'fps_native');

% If distData was not populated from distance_mm_filtered, load it now from the mat file.
if isempty(distData)
    matFile2 = getappdata(figV, 'matFile');
    if ~isempty(matFile2) && exist(matFile2, 'file')
        try
            Sm2 = load(matFile2, 'distance_mm_filtered', 'distance_mm');
            if isfield(Sm2, 'distance_mm_filtered')
                distData = double(Sm2.distance_mm_filtered(:));
            elseif isfield(Sm2, 'distance_mm')
                distData = double(Sm2.distance_mm(:));
            end
        catch ME
            if ~isempty(hSt), set(hSt,'String',['Update skipped: cannot load mat — ' ME.message(1:min(end,50))]); end
            return;
        end
    end
    if isempty(distData)
        if ~isempty(hSt), set(hSt,'String','Update skipped: no distance data available'); end
        return;
    end
end
nF = length(distData);
FALL_THR = 7.5;  HOLD_THR = 5.0;

% Build per-frame correction masks
corrNonFall  = false(nF, 1);   % frames that should NOT be counted as fall
corrForceFall = false(nF, 1);  % frames explicitly labeled 'Fall' by user
corrNonHold  = false(nF, 1);
for k = 1:length(corrections)
    s   = max(1, corrections(k).start_frame);
    e   = min(nF, corrections(k).end_frame);
    lbl = corrections(k).label;
    if strcmpi(lbl, 'fall')
        corrForceFall(s:e) = true;   % positively force as fall
    else
        corrNonFall(s:e) = true;     % override away from fall
    end
    if ~any(strcmpi(lbl, {'regular hold','hold'}))
        corrNonHold(s:e) = true;
    end
end

% Use threshold-based base for both masks (same as s.List(1/2) baseline),
% so corrected values stay on the same scale and non-hold labels visibly reduce RHT.
fallMask = ((distData(:) > FALL_THR) | corrForceFall) & ~corrNonFall;
holdMask = (distData(:) < HOLD_THR) & ~corrNonHold;

totalMin = nF / fps_native / 60;
if totalMin <= 0, return; end

FT_corr  = sum(fallMask)  / fps_native / 60 / totalMin * 10;
RHT_corr = sum(holdMask)  / fps_native / 60 / totalMin * 10;

% Cross count: natural crossings + forced-fall segment onsets
effDist = distData(:);
effDist(corrNonFall)   = 0;            % exclude non-fall corrections
effDist(corrForceFall) = FALL_THR + 1; % force-fall segments count as above threshold
CC_corr = sum(effDist(1:end-1) <= FALL_THR & effDist(2:end) > FALL_THR) / totalMin * 10;

% Case Holding count = number of Case Holding correction segments
CH_corr = 0;
for k = 1:length(corrections)
    if strcmpi(corrections(k).label, 'Case Holding')
        CH_corr = CH_corr + 1;
    end
end

% Update BehData for this session
prevFT  = BehData(anIdx).FT_sess(dayIdx);
prevRHT = BehData(anIdx).RHT_sess(dayIdx);
BehData(anIdx).FT_sess(dayIdx)  = FT_corr;
BehData(anIdx).RHT_sess(dayIdx) = RHT_corr;
BehData(anIdx).CC_sess(dayIdx)  = CC_corr;
if isfield(BehData, 'CaseHold_sess')
    BehData(anIdx).CaseHold_sess(dayIdx) = CH_corr;
    BehData(anIdx).Release_sess(dayIdx)  = CC_corr + CH_corr;
end
setappdata(fig7, 'BehData', BehData);

% Also push updated BehData into population figure appdata
figPop = getappdata(fig7, 'figPop');
if isgraphics(figPop, 'figure')
    setappdata(figPop, 'popBehData', BehData);
end

% Force metric selector to 'original' so corrections are visible
hMet = findobj(fig7, 'Tag', 'popMetric');
if ~isempty(hMet)
    metStrs = get(hMet, 'String');
    origIdx = find(strcmpi(metStrs, 'original'), 1);
    if ~isempty(origIdx), set(hMet, 'Value', origIdx); end
end

% Refresh plot, then restore the selected day (plotSingleAnimal resets it to 1)
try
    plotSingleAnimal(anIdx, BehData, fig7);
    setappdata(fig7, 'behDayIdx', dayIdx);
    drawDayMarker(fig7);
    updateBehDayLabel(fig7);
    drawnow;
    if ~isempty(hSt), set(hSt,'String',sprintf('FT:%.2f→%.2f  RHT:%.2f→%.2f  CC:%.1f  (FF:%d)', ...
        prevFT, FT_corr, prevRHT, RHT_corr, CC_corr, sum(corrForceFall))); end
catch ME
    if ~isempty(hSt), set(hSt,'String',['Update error: ' ME.message(1:min(end,60))]); end
end

% Redraw population figure with updated BehData
try
    if isgraphics(figPop, 'figure')
        updatePopulationFromFig7(fig7);
    end
catch, end
end

function refreshCorrectionOverlay(figV)
% Rebuild all distance-plot overlays to reflect current corrections:
%   1. Rebuild segment color strip in axSeg (corrections shown as colored bands)
%   2. Draw correction labels as text in axSeg (no semi-transparent patches on axD)
%   3. Redraw fall-onset markers (▼) in axD accounting for corrections
if ~isgraphics(figV, 'figure'), return; end
axD            = getappdata(figV, 'axD');
axSeg          = getappdata(figV, 'axSeg');
distData       = getappdata(figV, 'distData');
corrections    = getappdata(figV, 'corrections');
fps_native     = getappdata(figV, 'fps_native');
corrColorMap   = getappdata(figV, 'corrColorMap');
if isempty(axD) || ~isgraphics(axD) || isempty(distData), return; end

nF      = length(distData);
tSecAll = getappdata(figV, 'tSec');
if ~isempty(tSecAll) && length(tSecAll) == nF
    tSec = tSecAll;
else
    tSec = (0:nF-1) / fps_native;
end
yl = ylim(axD);

% ── Rebuild segment color strip (single imagesc in axSeg) ─────────────────
buildSegmentImage(figV);   % also deletes old corrLabel text tagged 'corrLabel'

% Label text in axSeg is intentionally not drawn — color alone identifies the correction.

% ── Redraw fall-onset markers (▼) accounting for corrections ─────────────
delete(findobj(axD, 'Tag', 'crossUpMarker'));
FALL_THR_ro = 7.5;
corrNonFall_ro   = false(nF, 1);
corrForceFall_ro = false(nF, 1);
for k = 1:length(corrections)
    s2 = max(1, corrections(k).start_frame);
    e2 = min(nF, corrections(k).end_frame);
    if strcmpi(corrections(k).label, 'fall')
        corrForceFall_ro(s2:e2) = true;
    else
        corrNonFall_ro(s2:e2) = true;
    end
end
effDist_ro = distData(:);
effDist_ro(corrNonFall_ro)   = 0;
effDist_ro(corrForceFall_ro) = FALL_THR_ro + 1;
crossUp_ro = find(effDist_ro(1:end-1) <= FALL_THR_ro & effDist_ro(2:end) > FALL_THR_ro);
if ~isempty(crossUp_ro)
    plot(axD, tSec(crossUp_ro), repmat(yl(2) * 0.97, size(crossUp_ro)), ...
        'rv', 'MarkerSize', 7, 'MarkerFaceColor', [0.85 0 0], ...
        'LineStyle', 'none', 'Tag', 'crossUpMarker', ...
        'DisplayName', sprintf('Fall count (%d)', numel(crossUp_ro)));
end

% Rebuild segment/subsegment-start lists so navigation buttons stay in sync
buildSegmentStarts(figV);
buildSubsegmentStarts(figV);
end

function buildSegmentStarts(figV)
% Compute start frame of every segment (contiguous block with same effective label)
% and store in figV appdata as 'segmentStarts'.
if ~isgraphics(figV, 'figure'), return; end
distData       = getappdata(figV, 'distData');
fallConfFrames = getappdata(figV, 'fallConfFrames');
holdConfFrames = getappdata(figV, 'holdConfFrames');
corrections    = getappdata(figV, 'corrections');
if isempty(distData)
    setappdata(figV, 'segmentStarts', 1);
    return;
end
nF = length(distData);

% Build per-frame correction label vector (empty string = use auto-label)
corrLabel = repmat({''}, nF, 1);
for k = 1:length(corrections)
    s = max(1, corrections(k).start_frame);
    e = min(nF, corrections(k).end_frame);
    [corrLabel{s:e}] = deal(corrections(k).label);
end

% Effective label for every frame
effLabel = cell(nF, 1);
for fi = 1:nF
    if ~isempty(corrLabel{fi})
        effLabel{fi} = corrLabel{fi};
    else
        effLabel{fi} = getFrameAutoLabel(distData, fallConfFrames, holdConfFrames, fi);
    end
end

% Segment starts: frame 1 plus any frame where label changes from previous
ps = 1;
for fi = 2:nF
    if ~strcmp(effLabel{fi}, effLabel{fi-1})
        ps(end+1) = fi; %#ok<AGROW>
    end
end
setappdata(figV, 'segmentStarts', ps);
end

function stepSegment(figV, dir)
% Jump to the previous (dir=-1) or next (dir=+1) segment start.
if ~isgraphics(figV, 'figure'), return; end
curFrame      = getappdata(figV, 'curFrame');
segmentStarts = getappdata(figV, 'segmentStarts');
if isempty(segmentStarts), return; end
if dir > 0
    candidates = segmentStarts(segmentStarts > curFrame);
    if isempty(candidates), return; end
    target = candidates(1);
else
    candidates = segmentStarts(segmentStarts < curFrame);
    if isempty(candidates), return; end
    target = candidates(end);
end
seekToFrame(figV, target);
end

function buildSubsegmentStarts(figV)
% Like buildSegmentStarts but uses (label + confidence level) as the key.
% Fully vectorised — no per-frame function calls.
if ~isgraphics(figV, 'figure'), return; end
distData       = getappdata(figV, 'distData');
fallConfFrames = getappdata(figV, 'fallConfFrames');
holdConfFrames = getappdata(figV, 'holdConfFrames');
corrections    = getappdata(figV, 'corrections');
if isempty(distData)
    setappdata(figV, 'subsegmentStarts', 1);
    return;
end
nF = length(distData);
FALL_THR = 7.5;  HOLD_THR = 5.0;

% ── Auto-label vector (0=Transition, 1=Fall, 2=Hold) ─────────────────────
autoVec = zeros(nF, 1, 'int8');
if ~isempty(fallConfFrames) && length(fallConfFrames) == nF
    autoVec(fallConfFrames(:) > 0) = 1;
else
    autoVec(distData(:) > FALL_THR) = 1;
end
if ~isempty(holdConfFrames) && length(holdConfFrames) == nF
    autoVec(holdConfFrames(:) > 0 & autoVec == 0) = 2;
else
    autoVec(distData(:) < HOLD_THR & autoVec == 0) = 2;
end

% ── Confidence level vector ───────────────────────────────────────────────
confVec = zeros(nF, 1, 'int8');
if ~isempty(fallConfFrames) && length(fallConfFrames) == nF
    confVec = max(confVec, int8(fallConfFrames(:)));
end
if ~isempty(holdConfFrames) && length(holdConfFrames) == nF
    confVec = max(confVec, int8(holdConfFrames(:)));
end

% Key = autoVec * 10 + confVec (unique integer per subsegment type).
% Correction ranges get a unique negative value per correction index.
keyVec = int32(autoVec) * 10 + int32(confVec);
for k = 1:length(corrections)
    sf = max(1, corrections(k).start_frame);
    ef = min(nF, corrections(k).end_frame);
    keyVec(sf:ef) = int32(-k);   % each correction gets its own unique key
end

% Subsegment starts: frame 1 plus every frame where the key changes
changed = keyVec(1:end-1) ~= keyVec(2:end);
ps = [1, find(changed)' + 1];

% Merge any forced splits (from Divide subseg button)
subsegSplits = getappdata(figV, 'subsegSplits');
if ~isempty(subsegSplits)
    valid = subsegSplits(subsegSplits >= 2 & subsegSplits <= nF);
    ps = unique([ps, valid]);
end

setappdata(figV, 'subsegmentStarts', ps);
end

function stepSubsegment(figV, dir)
% Jump forward (dir=+1) or backward (dir=-1) by subsegMultiplier subsegments.
if ~isgraphics(figV, 'figure'), return; end
curFrame          = getappdata(figV, 'curFrame');
subsegmentStarts  = getappdata(figV, 'subsegmentStarts');
if isempty(subsegmentStarts), return; end
mult = getappdata(figV, 'subsegMultiplier');
if isempty(mult), mult = 1; end
if dir > 0
    candidates = subsegmentStarts(subsegmentStarts > curFrame);
    if isempty(candidates), return; end
    target = candidates(min(mult, end));
else
    candidates = subsegmentStarts(subsegmentStarts < curFrame);
    if isempty(candidates), return; end
    target = candidates(max(1, end - mult + 1));
end
seekToFrame(figV, target);
end

function setSubsegMultiplier(figV, mult)
% Set the subsegment step multiplier and update toggle button states.
if ~isgraphics(figV, 'figure'), return; end
setappdata(figV, 'subsegMultiplier', mult);
tags = {'btnSubsegMx1','btnSubsegMx2','btnSubsegMx4','btnSubsegMx10'};
vals = [1, 2, 4, 10];
for k = 1:numel(tags)
    h = findobj(figV, 'Tag', tags{k});
    if ~isempty(h)
        isActive = (vals(k) == mult);
        if isActive
            set(h, 'Value', 1, 'FontWeight', 'bold');
        else
            set(h, 'Value', 0, 'FontWeight', 'normal');
        end
    end
end
end

function divideSubsegment(figV)
% Split the current subsegment into two at the current frame.
% The current frame becomes the start of the second half.
if ~isgraphics(figV, 'figure'), return; end
curFrame     = getappdata(figV, 'curFrame');
subsegSplits = getappdata(figV, 'subsegSplits');
nFrames      = getappdata(figV, 'nFrames');

% Frame 1 is always a subseg start — no split needed there.
if curFrame < 2 || curFrame > nFrames
    return;
end

% Skip if already a subsegment boundary.
subsegmentStarts = getappdata(figV, 'subsegmentStarts');
if ~isempty(subsegmentStarts) && any(subsegmentStarts == curFrame)
    hSt = findobj(figV, 'Tag', 'txtCorrStatus');
    if ~isempty(hSt)
        set(hSt, 'String', sprintf('Frame %d is already a subseg boundary', curFrame));
    end
    return;
end

subsegSplits = unique([subsegSplits, curFrame]);
setappdata(figV, 'subsegSplits', subsegSplits);
buildSubsegmentStarts(figV);

hSt = findobj(figV, 'Tag', 'txtCorrStatus');
if ~isempty(hSt)
    set(hSt, 'String', sprintf('Subseg split at frame %d (%d forced splits total)', ...
        curFrame, length(subsegSplits)));
end
end

function [segStart, segEnd] = findSubsegmentBounds( ...
        distData, fallConfFrames, holdConfFrames, corrections, fi, forcedSplits)
% Find bounds of the contiguous subsegment (same label + same confidence tier)
% around frame fi.  forcedSplits (optional) is a sorted list of frame indices
% that act as hard boundaries (from the Divide subseg button).
if nargin < 6, forcedSplits = []; end
nF      = length(distData);
thisKey = getFrameSubKey(distData, fallConfFrames, holdConfFrames, corrections, fi);
segStart = fi;
while segStart > 1
    if ~isempty(forcedSplits) && any(forcedSplits == segStart), break; end
    k = getFrameSubKey(distData, fallConfFrames, holdConfFrames, corrections, segStart-1);
    if ~strcmp(k, thisKey), break; end
    segStart = segStart - 1;
end
segEnd = fi;
while segEnd < nF
    if ~isempty(forcedSplits) && any(forcedSplits == segEnd+1), break; end
    k = getFrameSubKey(distData, fallConfFrames, holdConfFrames, corrections, segEnd+1);
    if ~strcmp(k, thisKey), break; end
    segEnd = segEnd + 1;
end
end

function key = getFrameSubKey(distData, fallConfFrames, holdConfFrames, corrections, fi)
% Return the subsegment key for frame fi: correction label, or "AutoLabel_conf".
for k = 1:length(corrections)
    if fi >= corrections(k).start_frame && fi <= corrections(k).end_frame
        key = corrections(k).label; return;
    end
end
autoLbl = getFrameAutoLabel(distData, fallConfFrames, holdConfFrames, fi);
conf = 0;
if ~isempty(fallConfFrames) && fi <= length(fallConfFrames)
    conf = fallConfFrames(fi);
end
if conf == 0 && ~isempty(holdConfFrames) && fi <= length(holdConfFrames)
    conf = holdConfFrames(fi);
end
key = sprintf('%s_%d', autoLbl, conf);
end

function [FT, RHT, CC, CH] = computeCorrectedMetrics(s, corrections)
% Recompute FT/RHT/CC/CH from a loaded FallCount struct + corrections array.
% Falls back to raw s.List values if distance data is absent.
FT  = s.List(1);
RHT = s.List(2);
CC  = s.List(3);
CH  = sum(strcmpi({corrections.label}, 'Case Holding'));
if isempty(corrections) || ~isfield(s, 'distance_mm_filtered'), return; end

FALL_THR = 7.5;  HOLD_THR = 5.0;
fps      = 60.0;   % camera is always 60 Hz
distData = double(s.distance_mm_filtered(:));
nF       = length(distData);
totalMin = nF / fps / 60;
if totalMin <= 0, return; end

% Per-frame masks for which frames count as fall / hold after corrections.
% Base is always the distance threshold (same as s.List(1) = FallTime_10min),
% so corrected values stay on the same scale as the uncorrected baseline.
corrNonFall   = false(nF, 1);
corrForceFall = false(nF, 1);
corrNonHold   = false(nF, 1);
for k = 1:length(corrections)
    sf  = max(1, corrections(k).start_frame);
    ef  = min(nF, corrections(k).end_frame);
    lbl = corrections(k).label;
    if strcmpi(lbl, 'fall')
        corrForceFall(sf:ef) = true;   % force these frames to count as fall
    else
        corrNonFall(sf:ef) = true;     % override away from fall
    end
    if ~any(strcmpi(lbl, {'regular hold','hold'}))
        corrNonHold(sf:ef) = true;
    end
end

fallMask = ((distData > FALL_THR) | corrForceFall) & ~corrNonFall;
holdMask = (distData < HOLD_THR) & ~corrNonHold;

FT  = sum(fallMask) / fps / 60 / totalMin * 10;
RHT = sum(holdMask) / fps / 60 / totalMin * 10;

effDist = distData;
effDist(corrNonFall)   = 0;
effDist(corrForceFall) = FALL_THR + 1;   % force-fall segments above threshold for CC
CC = sum(effDist(1:end-1) <= FALL_THR & effDist(2:end) > FALL_THR) / totalMin * 10;
end

function findCorrectionRules(figV)
% Aggregate corrections across all sessions of the same animal,
% extract per-segment features, and suggest threshold rules.
if ~isgraphics(figV, 'figure'), return; end
matFile    = getappdata(figV, 'matFile');
if isempty(matFile)
    msgbox('No FallCount.mat loaded — cannot analyse corrections.','Find Rules'); return
end

% First save current session's corrections
saveCorrectionFile(figV);

% Collect correction files from the same animal folder
movDir = fileparts(matFile);
corrFiles = dir(fullfile(movDir, '*_corrections.mat'));
if isempty(corrFiles)
    msgbox('No corrections saved yet in this folder.','Find Rules'); return
end

% Accumulate feature rows
featMat = [];   % Nx5: [dist_mean, distZ_mean, angle_mean, duration_s, dist_max]
labelList = {};
for ff = 1:length(corrFiles)
    cp = fullfile(corrFiles(ff).folder, corrFiles(ff).name);
    try
        Sc = load(cp, 'corrections');
        if ~isfield(Sc,'corrections') || isempty(Sc.corrections), continue; end
        for kc = 1:length(Sc.corrections)
            f = Sc.corrections(kc).features;
            row = [f.dist_mean, f.distZ_mean, f.angle_mean, f.duration_s, f.dist_max];
            featMat(end+1,:) = row; %#ok<AGROW>
            labelList{end+1} = Sc.corrections(kc).label; %#ok<AGROW>
        end
    catch, end
end

if isempty(featMat)
    msgbox('Corrections exist but have no feature data yet.','Find Rules'); return
end

featNames = {'dist\_mean (mm)','distZ\_mean (mm)','angle\_mean (°)','duration (s)','dist\_max (mm)'};
pyNames   = {'dist_mean','distZ_mean','angle_mean','duration_s','dist_max'};
uniqueLabels = unique(labelList);
nClass = length(uniqueLabels);

% ── Statistics per class ──────────────────────────────────────────────────
lines = {'=== Correction Statistics ===', ''};
for ci = 1:nClass
    mask = strcmp(labelList, uniqueLabels{ci});
    lines{end+1} = sprintf('Class: %s  (N=%d)', uniqueLabels{ci}, sum(mask));
    for fi = 1:size(featMat,2)
        v = featMat(mask, fi);
        v = v(isfinite(v));
        if isempty(v), continue; end
        lines{end+1} = sprintf('  %-20s  mean=%.2f  sd=%.2f  [%.2f, %.2f]', ...
            strrep(featNames{fi},'\_','_'), mean(v), std(v), min(v), max(v));
    end
    lines{end+1} = '';
end

% ── Best separating threshold for each pair ───────────────────────────────
if nClass >= 2
    lines{end+1} = '=== Suggested Rules ===';
    lines{end+1} = '';
    for ci = 1:nClass
        for cj = ci+1:nClass
            m1 = strcmp(labelList, uniqueLabels{ci});
            m2 = strcmp(labelList, uniqueLabels{cj});
            n1 = sum(m1);  n2 = sum(m2);
            if n1 < 2 || n2 < 2, continue; end
            bestAcc = 0; bestFi = 1; bestThr = 0; bestDir = '>';
            for fi = 1:size(featMat,2)
                v1 = featMat(m1, fi);  v1 = v1(isfinite(v1));
                v2 = featMat(m2, fi);  v2 = v2(isfinite(v2));
                if isempty(v1)||isempty(v2), continue; end
                allV = sort([v1; v2]);
                for ti = 1:length(allV)-1
                    thr = (allV(ti)+allV(ti+1))/2;
                    acc1 = (sum(v1 < thr) + sum(v2 >= thr)) / (n1+n2);
                    acc2 = (sum(v1 >= thr) + sum(v2 < thr)) / (n1+n2);
                    if max(acc1,acc2) > bestAcc
                        bestAcc = max(acc1,acc2);
                        bestFi  = fi;
                        bestThr = thr;
                        bestDir = '< ';
                        if acc2 > acc1, bestDir = '>='; end
                    end
                end
            end
            lines{end+1} = sprintf('%s  vs  %s:', uniqueLabels{ci}, uniqueLabels{cj});
            lines{end+1} = sprintf('  Best: %s %s %.3g  (accuracy=%.0f%%)', ...
                strrep(pyNames{bestFi},'_','\_'), bestDir, bestThr, bestAcc*100);
            % Suggest GenerateFallCount.py constant update
            if strcmp(pyNames{bestFi},'distZ_mean')
                lines{end+1} = sprintf('  → Consider Z_SHELL_THR = %.2f', bestThr);
            elseif strcmp(pyNames{bestFi},'angle_mean')
                lines{end+1} = sprintf('  → Consider ANGLE_FALL_THR = %.1f', bestThr);
            elseif strcmp(pyNames{bestFi},'duration_s')
                lines{end+1} = sprintf('  → Consider MIN_FALL_DUR_S = %.2f', bestThr);
            end
            lines{end+1} = '';
        end
    end
end

% ── Show results in a scrollable figure ───────────────────────────────────
figR = figure('Name','Correction Rules','Position',[200 100 620 500], ...
    'MenuBar','none','ToolBar','none','NumberTitle','off');
uicontrol(figR, 'Style','listbox', 'String', lines, ...
    'Units','normalized','Position',[0.02 0.02 0.96 0.96], ...
    'FontSize',9,'FontName','Courier New', ...
    'HorizontalAlignment','left','Max',2);
end

function d = parseDateFromFilename(fname)
% Extract session date from a movie filename (Nakashima or Iwai format).
% Returns NaT on failure.
d = NaT;
try
    s = strtrim(fname);
    % Strip DLC suffix so we only parse the leading date token
    idx = strfind(s, 'DLC_');
    if ~isempty(idx), s = s(1:idx(1)-1); end
    s = strtrim(s);
    p1 = strsplit(s, '-');
    if length(p1{1}) == 4
        % Nakashima: YYYY-M-D-...
        yr = str2double(p1{1});
        mo = str2double(p1{2});
        dy = str2double(p1{3});
    else
        % Iwai: YY-MM-DD HH-MM-SS... (leading space in some filenames)
        datePart = strtrim(extractBefore(s, ' '));
        p2 = strsplit(datePart, '-');
        yr = str2double(p2{1}) + 2000;
        mo = str2double(p2{2});
        dy = str2double(p2{3});
    end
    if any(isnan([yr, mo, dy])) || yr < 2020 || yr > 2100, return; end
    d = datetime(yr, mo, dy);
catch
end
end

function stepPopAnimal(figPop, delta)
% Advance (+1) or retreat (-1) the selected animal and refresh the highlight.
allOrder = getappdata(figPop, 'popAllOrder');
if isempty(allOrder), return; end
curIdx = getappdata(figPop, 'popAnimalIdx');
if isempty(curIdx), curIdx = 1; end
curIdx = mod(curIdx - 1 + delta, numel(allOrder)) + 1;
setappdata(figPop, 'popAnimalIdx', curIdx);
highlightAnimalInPop(figPop);
end

function highlightAnimalInPop(figPop)
% Overlay the selected animal's traces in bold on the three individual subplots.
BehData  = getappdata(figPop, 'popBehData');
StdPOD   = getappdata(figPop, 'popStdPOD');
infMask  = getappdata(figPop, 'popInfMask');
allOrder = getappdata(figPop, 'popAllOrder');
curIdx   = getappdata(figPop, 'popAnimalIdx');
if isempty(curIdx) || isempty(allOrder) || isempty(BehData), return; end

bdi = allOrder(curIdx);
bd  = BehData(bdi);
ovlMask = getappdata(figPop, 'popOvlMask');
cH  = [0.85 0.15 0.15];              % red    = infarction / region
grpStr = 'Inf';
if ~infMask(bdi)
    cH = [0.2 0.2 0.2];  grpStr = 'Sham';    % dark = sham
end
if ~isempty(ovlMask) && numel(ovlMask) >= bdi && ovlMask(bdi)
    cH = [0.00 0.35 0.85];  grpStr = 'Surround';   % blue = surround overlay
end

axTags = {'axIndFT',         'axIndFC',            'axIndRH'};
fields = {'FallTime_10min',  'CrossCount_10min',   'RegHoldTime_10min'};
for k = 1:3
    ax = findobj(figPop, 'Tag', axTags{k});
    if isempty(ax), continue; end
    delete(findobj(ax, 'Tag', 'popHighlight'));
    if isfield(bd, fields{k})
        ydata = bd.(fields{k});
        vm = ~isnan(ydata);
        if any(vm)
            plot(ax, StdPOD(vm), ydata(vm), '-o', ...
                'Color', cH, 'LineWidth', 2, 'MarkerSize', 5, ...
                'Tag', 'popHighlight');
        end
    end
end

% Severity panel: recompute z(FallTime)+z(FallCount) for this animal using
% the pooled mean/std stashed at draw time (same standardization as the
% panel data), so the highlighted trace lines up with the population.
axSV = findobj(figPop, 'Tag', 'axIndSV');
zp   = getappdata(figPop, 'popZParams');
if ~isempty(axSV) && numel(zp) == 4 ...
        && isfield(bd, 'FallTime_10min') && isfield(bd, 'CrossCount_10min')
    delete(findobj(axSV, 'Tag', 'popHighlight'));
    sv = zStd(bd.FallTime_10min, zp(1), zp(2)) + zStd(bd.CrossCount_10min, zp(3), zp(4));
    vm = ~isnan(sv);
    if any(vm)
        plot(axSV, StdPOD(vm), sv(vm), '-o', ...
            'Color', cH, 'LineWidth', 2, 'MarkerSize', 5, 'Tag', 'popHighlight');
    end
end

% Update ID label next to Next button
hTxt = findobj(figPop, 'Tag', 'txtPopID');
if ~isempty(hTxt)
    set(hTxt, 'String', sprintf('%s  (%s)', bd.ID, grpStr));
end

% Sync the source "Lesion Centroids" figure when this population figure was
% spawned by its "Select region" toggle (srcFigCent set on figPop): recolor
% the current animal's lesion contour green there. Guarded so ordinary
% population figures (no srcFigCent) are unaffected.
figCentSrc = getappdata(figPop, 'srcFigCent');
if ~isempty(figCentSrc) && isgraphics(figCentSrc, 'figure')
    setappdata(figCentSrc, 'centHighlightID', bd.ID);
    redrawCentroidScatter(figCentSrc);
end
end

function rgb = ccfAreaColor(acr)
% Allen CCF color (0–1 RGB) for a region acronym, read from
% structure_tree_safe_2017.csv's color_hex_triplet — the same LUT that
% colors the top-view lesion map (Area_mapRGB). Built once and cached.
% Layer suffixes share the parent color in Allen, so an exact-acronym miss
% falls back to the layer-stripped form, then to neutral gray.
persistent MAP
if isempty(MAP)
    MAP = containers.Map('KeyType', 'char', 'ValueType', 'any');
    baseDir = fileparts(mfilename('fullpath'));
    stFn = fullfile(baseDir, 'AllenCCF', 'structure_tree_safe_2017.csv');
    % loadStructureTree ships in the bundled AP_histology repo; add it if needed
    if isempty(which('loadStructureTree'))
        stDir = fullfile(baseDir, 'AP_histology-master', 'allenCCF_repo_functions');
        if isfolder(stDir), addpath(stDir); end
    end
    if exist(stFn, 'file') && ~isempty(which('loadStructureTree'))
        try
            st = loadStructureTree(stFn);
            for r = 1:numel(st.acronym)
                hx = st.color_hex_triplet{r};
                if ischar(hx) && numel(hx) == 6
                    MAP(st.acronym{r}) = ...
                        [hex2dec(hx(1:2)), hex2dec(hx(3:4)), hex2dec(hx(5:6))] / 255;
                end
            end
        catch ME
            fprintf('ccfAreaColor: could not load structure tree: %s\n', ME.message);
        end
    end
end
rgb = [0.65 0.65 0.65];   % fallback gray
if isKey(MAP, acr)
    rgb = MAP(acr);
elseif isKey(MAP, stripLayerSuffix(acr))
    rgb = MAP(stripLayerSuffix(acr));
end
end

function b = stripLayerSuffix(s)
% Return the base acronym by removing trailing layer-number suffix.
% 'MOp5'→'MOp', 'SSp-bfd1'→'SSp-bfd', 'MOp'→'MOp'
idx = find(isstrprop(s, 'digit'), 1);
if isempty(idx) || idx == 1
    b = s;
else
    b = s(1:idx-1);
end
end

function variants = animalIDVariants(id)
% Return candidate folder names for an animal ID, handling zero-padding differences.
% e.g. 'NO4'  → {'NO4',  'NO04'}
%      'NO04' → {'NO04', 'NO4'}
%      'IO22' → {'IO22'} (already 2-digit, no unpadded form differs)
variants = {id};
tok = regexp(id, '^([A-Za-z]+)(\d+)$', 'tokens', 'once');
if isempty(tok), return; end
prefix = tok{1};
numStr = tok{2};
num    = str2double(numStr);
% zero-padded form (at least 2 digits)
padded   = sprintf('%s%02d', prefix, num);
% unpadded form (no leading zeros)
unpadded = sprintf('%s%d',   prefix, num);
% add the one that differs from the original
if ~strcmp(padded, id),   variants{end+1} = padded;   end
if ~strcmp(unpadded, id), variants{end+1} = unpadded; end
end

function ccfFiles = findCCFFiles(ccfRoot, id)
% Search for LesionMapAllenCCF.mat under ccfRoot/*/id/CCF/,
% trying zero-padded and unpadded variants of id (e.g. 'IO2' <-> 'IO02').
ccfFiles = [];
for v = animalIDVariants(id)
    ccfFiles = dir(fullfile(ccfRoot, '*', v{1}, 'CCF', 'LesionMapAllenCCF.mat'));
    if ~isempty(ccfFiles), return; end
end
end

function lvmData = loadLVMForSession(matFile, animalID)
% Find and load the .lvm file matching the session date and animal ID.
% Filename format: 'YYMMDD {AnimalID}*.lvm'  (same for Iwai and Nakashima).
% Returns struct: tSec, leverR, rewardTimes, pullTimes  (empty if not found).
lvmData = struct('tSec',[],'leverR',[],'rewardTimes',[],'pullTimes',[],'triggerTimes',[]);

BehRoot      = fullfile(getDataServerRoot(), 'Behavior');
% Search all known researcher subfolders — no hardcoded ID-prefix mapping needed
researcherDirs = {'Iwai', 'Nakashima', 'Watanabe'};

% Find the animal's subfolder (try all researchers, all ID variants)
subDir = '';
for ri = 1:length(researcherDirs)
    subFolderRoot = fullfile(BehRoot, researcherDirs{ri});
    for v = animalIDVariants(animalID)
        candidate = fullfile(subFolderRoot, v{1});
        if isfolder(candidate)
            subDir = candidate;
            break;
        end
    end
    if ~isempty(subDir), break; end
end
if isempty(subDir)
    fprintf('loadLVM: no subfolder found for %s under %s\n', animalID, BehRoot);
    return;
end
fprintf('loadLVM: found subfolder %s\n', subDir);

% Parse session date AND time from the _FallCount.mat basename
[~, matBase] = fileparts(matFile);
sessionDate  = parseDateFromFilename(matBase);
fprintf('loadLVM: matBase=%s  sessionDate=%s\n', matBase, char(sessionDate));
if isnat(sessionDate), return; end

% Extract HH-MM-SS time token from Iwai-format basename: 'YY-MM-DD HH-MM-SS...'
sessionTimeStr = '';   % digits only, e.g. '132915' from '13-29-15'
tok = regexp(matBase, '\d{2}-\d{2}-\d{2}\s+(\d{2})-(\d{2})-(\d{2})', 'tokens', 'once');
if ~isempty(tok)
    sessionTimeStr = [tok{1} tok{2} tok{3}];   % 'HHMMSS'
end

% Build YYMMDD prefix and try multiple filename conventions:
%   Iwai:      'Iwai{YYMMDD}*.lvm'
%   Nakashima: '{YYMMDD}*.lvm'
%   Watanabe:  'Watanabe{YYMMDD}*.lvm'  or  '{YYMMDD}*.lvm'
dateStr   = sprintf('%02d%02d%02d', mod(year(sessionDate), 100), month(sessionDate), day(sessionDate));
prefixes  = {'Iwai', 'Watanabe', ''};   % '' = bare YYMMDD (Nakashima / others)
lvmCands  = [];
for pi = 1:length(prefixes)
    pattern  = fullfile(subDir, [prefixes{pi} dateStr '*.lvm']);
    lvmCands = dir(pattern);
    if ~isempty(lvmCands)
        fprintf('loadLVM: matched pattern %s (%d file(s))\n', pattern, length(lvmCands));
        break;
    end
end
if isempty(lvmCands)
    fprintf('loadLVM: no .lvm found in %s for date %s\n', subDir, dateStr);
    return;
end

% When multiple LVM files exist for the same day, prefer the one whose name
% contains the session time (HHMMSS or HHMM), then fall back to the largest file.
if numel(lvmCands) > 1 && ~isempty(sessionTimeStr)
    chosen = 0;
    % Try HHMMSS match, then HHMM prefix match
    for tryLen = [6 4]
        tStr = sessionTimeStr(1:tryLen);
        for ci = 1:numel(lvmCands)
            if contains(lvmCands(ci).name, tStr)
                chosen = ci;
                fprintf('loadLVM: multiple LVM files — matched time %s → %s\n', tStr, lvmCands(ci).name);
                break;
            end
        end
        if chosen > 0, break; end
    end
    if chosen == 0
        % Fall back: pick the largest file
        [~, chosen] = max([lvmCands.bytes]);
        fprintf('loadLVM: multiple LVM files, no time match — using largest: %s\n', lvmCands(chosen).name);
    end
    lvmCands = lvmCands(chosen);
end
lvmFile = fullfile(lvmCands(1).folder, lvmCands(1).name);
fprintf('loadLVM: loading %s\n', lvmFile);

% Load the LVM file
try
    data = lvm_import(lvmFile, 0);
    if ~isfield(data, 'Segment1') || ~isfield(data.Segment1, 'data')
        return;
    end
    Dat = data.Segment1.data;
    if isempty(Dat) || size(Dat,2) < 8, return; end

    AddDat = 0;
    if size(Dat,2) == 15, AddDat = 3; end

    nSamples  = size(Dat, 1);
    tSec      = (0:nSamples-1)' / 1000;
    leverR    = Dat(:, 1);

    % Reward: falling edge of column 4
    rewardTimes = [];
    if size(Dat,2) >= 4
        [~, rewLoc] = findpeaks(-diff(Dat(:,4)), 'MinPeakHeight', 0.8);
        if ~isempty(rewLoc)
            rewardTimes = tSec(rewLoc + 1);
        end
    end

    % Pull onset: rising edge of column 8+AddDat
    pullTimes = [];
    colIdx    = 8 + AddDat;
    if size(Dat,2) >= colIdx
        colOT = min(max(Dat(:, colIdx), 0), 5);
        [~, pullLoc] = findpeaks(diff(colOT), 'MinPeakHeight', 0.8);
        if ~isempty(pullLoc)
            pullTimes = tSec(pullLoc + 1);
        end
    end

    % Camera triggers: rising edge of column 6
    triggerTimes = [];
    if size(Dat,2) >= 6
        colTrig = min(max(Dat(:,6), 0), 5);
        [~, trigLoc] = findpeaks(diff(colTrig), 'MinPeakHeight', 0.8);
        if ~isempty(trigLoc)
            triggerTimes = tSec(trigLoc + 1);
        end
    end
    fprintf('loadLVM: %d triggers, %d rewards, %d pulls\n', ...
        length(triggerTimes), length(rewardTimes), length(pullTimes));

    lvmData.tSec         = tSec;
    lvmData.leverR       = leverR;
    lvmData.rewardTimes  = rewardTimes;
    lvmData.pullTimes    = pullTimes;
    lvmData.triggerTimes = triggerTimes;
catch ME
    fprintf('loadLVMForSession: error loading %s: %s\n', lvmFile, ME.message);
end
end

function cats = loadSharedCustomCats()
% Load custom categories from both redundant copies and return the merged union.
% Using two copies means either can serve as backup if the other is corrupted/empty.
copies = sharedCatFiles();
cats = {};
for i = 1:numel(copies)
    f = copies{i};
    if exist(f, 'file')
        try
            S = load(f, 'customCategories');
            if isfield(S, 'customCategories') && iscell(S.customCategories)
                for k = 1:numel(S.customCategories)
                    entry = S.customCategories{k};
                    if ~ismember(entry, cats)
                        cats{end+1} = entry; %#ok<AGROW>
                    end
                end
            end
        catch ME
            fprintf('loadSharedCustomCats: error reading %s: %s\n', f, ME.message);
        end
    end
end
end

function saveSharedCustomCats(cats)
% Write custom categories to both redundant copies.
% Safety: refuse to overwrite non-empty files with an empty list.
if isempty(cats)
    existing = loadSharedCustomCats();
    if ~isempty(existing)
        fprintf('saveSharedCustomCats: refusing to overwrite %d existing categories with empty list.\n', length(existing));
        return;
    end
end
copies = sharedCatFiles();
customCategories = cats(:)';   %#ok<NASGU>
for i = 1:numel(copies)
    try
        save(copies{i}, 'customCategories');
    catch ME
        fprintf('saveSharedCustomCats: failed to save to %s: %s\n', copies{i}, ME.message);
    end
end
end

function files = sharedCatFiles()
% Canonical locations for the custom-category list (two redundant copies).
root = getDataServerRoot();
files = { fullfile(root, 'Movie\Iwai\FallCount_customCategories.mat'), ...
          fullfile(root, 'Movie\Nakashima\FallCount_customCategories.mat') };
end

function root = getDataServerRoot()
% Return the UNC root of the shared data server (e.g. \\IP\DataTransferForAllUsers_1day).
% Strategy:
%   1. Use cached value (persistent) if the folder is still reachable.
%   2. Try the IP/hostname saved from last successful connection (per-machine pref).
%   3. Try P.DataServerAddr from local_paths.m (see local_paths.example.m).
%   4. If none work, show an input dialog so the user can enter the new address.
%      The working address is then saved to prefs for next time.
persistent cachedRoot
shareName = 'DataTransferForAllUsers_1day';
% Return cache if still alive
if ~isempty(cachedRoot) && isfolder(cachedRoot)
    root = cachedRoot;
    return;
end
% Build candidate list: saved pref first, then known fallback
P = local_paths();
savedAddr = getpref('LeverPullTask', 'DataServerAddr', P.DataServerAddr);
candidates = {savedAddr};
if ~isempty(P.DataServerAddr) && ~strcmp(savedAddr, P.DataServerAddr)
    candidates{end+1} = P.DataServerAddr;
end
candidates = candidates(~cellfun(@isempty, candidates));
root = '';
for i = 1:numel(candidates)
    candidate = ['\\' candidates{i} '\' shareName];
    if isfolder(candidate)
        root = candidate;
        cachedRoot = root;
        setpref('LeverPullTask', 'DataServerAddr', candidates{i});
        return;
    end
end
% None of the known addresses worked — ask the user once
answer = inputdlg( ...
    {sprintf('Data server not reachable (tried: %s).\nEnter server IP or hostname:', ...
        strjoin(candidates, ', '))}, ...
    'Data Server Address', 1, {savedAddr});
if ~isempty(answer) && ~isempty(strtrim(answer{1}))
    newAddr = strtrim(answer{1});
    candidate = ['\\' newAddr '\' shareName];
    if isfolder(candidate)
        root = candidate;
        cachedRoot = root;
        setpref('LeverPullTask', 'DataServerAddr', newAddr);
    else
        warning('LeverPullTask:serverNotFound', ...
            'Cannot reach \\%s\\%s — network paths will not work.', newAddr, shareName);
    end
end
end


function pyExe = getDeepLabCutPython()
% Locate the DEEPLABCUT conda env python.exe used to run GenerateFallCount.py.
% The path was previously hardcoded to a single user's conda env, which
% only exists on one machine (on other machines the env may live under
% anaconda3 rather than .conda). Strategy mirrors getDataServerRoot:
%   1. Cached value (persistent) if still valid.
%   2. Per-machine saved pref.
%   3. Known conda roots under the current user profile (and ProgramData).
%   4. One-time file picker; the chosen path is saved to prefs for next time.
persistent cachedPy
if ~isempty(cachedPy) && isfile(cachedPy)
    pyExe = cachedPy;
    return;
end
home = getenv('USERPROFILE');
candidates = {};
saved = getpref('LeverPullTask', 'DeepLabCutPython', '');
if ~isempty(saved), candidates{end+1} = saved; end
condaRoots = { fullfile(home,'.conda'), fullfile(home,'anaconda3'), ...
    fullfile(home,'Anaconda3'), fullfile(home,'miniconda3'), ...
    fullfile(home,'miniforge3'), 'C:\ProgramData\anaconda3', ...
    'C:\ProgramData\miniconda3' };
for r = 1:numel(condaRoots)
    candidates{end+1} = fullfile(condaRoots{r}, 'envs', 'DEEPLABCUT', 'python.exe'); %#ok<AGROW>
end
pyExe = '';
for i = 1:numel(candidates)
    if ~isempty(candidates{i}) && isfile(candidates{i})
        pyExe = candidates{i};
        cachedPy = pyExe;
        setpref('LeverPullTask', 'DeepLabCutPython', pyExe);
        return;
    end
end
% None of the known locations worked — ask the user to point at it once.
[fn, fp] = uigetfile({'python.exe', 'python.exe'; '*.exe', 'Executable (*.exe)'}, ...
    'Locate the DEEPLABCUT conda env python.exe');
if isequal(fn, 0)
    pyExe = '';   % caller reports and skips this animal
    return;
end
pyExe = fullfile(fp, fn);
cachedPy = pyExe;
setpref('LeverPullTask', 'DeepLabCutPython', pyExe);
end

