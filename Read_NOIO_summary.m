
P = local_paths();          % machine-specific data locations (see local_paths.example.m)
xlsxFile = P.NOIOSummary;   % NOIO_summary_YYYYMMDD.xlsx (animal ID / lesion location / lesion size)

% Read all cells as raw (row 1: session groups, row 2: headers, rows 3+: data)
raw = readcell(xlsxFile, 'Sheet', 'Sheet1');

% Column layout (1-indexed):
%  1: ID
%  2: Lesion location
%  3: Lesion size (mm3)  -- mostly numeric, some text e.g. '0.41+0.51'
%  4: Notes
%  5- 9: day1-day5 (pre-surgery sessions)
% 10: Surgery date
% 11-20: POD3, POD7, POD10, POD14, POD17, POD21, POD24, POD28, POD31, POD35
% 21: End date

sessionLabels = {'day1','day2','day3','day4','day5','Surgery', ...
    'POD3','POD7','POD10','POD14','POD17','POD21','POD24','POD28','POD31','POD35','End'};

% Data starts at row 3 (rows 1-2 are headers)
nRows = size(raw, 1);
NOIOData = struct();
idx = 0;

for r = 3:nRows
    id = raw{r, 1};
    % Skip rows with no animal ID
    if isempty(id) || (isnumeric(id) && (isnan(id) || id == 0))
        continue
    end
    if ismissing(id)
        continue
    end
    idx = idx + 1;
    NOIOData(idx).ID = id;

    % Lesion location (col 2)
    % Sham animals have no lesion: cell may contain 'sham', numeric 0, or be empty
    loc = raw{r, 2};
    if (ischar(loc) || isstring(loc)) && ~isempty(loc)
        NOIOData(idx).LesionLocation = char(loc);
    elseif (isnumeric(loc) && ~isnan(loc) && loc == 0) || ismissing(loc) || isempty(loc)
        NOIOData(idx).LesionLocation = 'sham';
    else
        NOIOData(idx).LesionLocation = '';
    end

    % Lesion size in mm3 (col 3) -- numeric or text (e.g. '0.41+0.51')
    sz = raw{r, 3};
    if isnumeric(sz) && ~isnan(sz)
        NOIOData(idx).LesionSize_mm3 = sz;
        NOIOData(idx).LesionSize_str = num2str(sz);
    elseif ischar(sz) || isstring(sz)
        NOIOData(idx).LesionSize_mm3 = NaN;
        NOIOData(idx).LesionSize_str = sz;
    else
        NOIOData(idx).LesionSize_mm3 = NaN;
        NOIOData(idx).LesionSize_str = '';
    end

    % Notes (col 4)
    notes = raw{r, 4};
    if ischar(notes) || isstring(notes)
        NOIOData(idx).Notes = notes;
    elseif isnumeric(notes) && notes == 0
        NOIOData(idx).Notes = '';
    else
        NOIOData(idx).Notes = '';
    end

    % Session dates (cols 5-21 = 17 entries)
    % Invalid/empty cells (Excel serial 0 = datetime <=1900-01-01, or text) -> NaT
    sessionDates = NaT(1, 17);
    for j = 1:17
        d = raw{r, 4 + j};
        if isdatetime(d) && d > datetime(1900, 1, 2)
            sessionDates(j) = d;
        end
    end
    NOIOData(idx).SessionDates  = sessionDates;
    NOIOData(idx).SessionLabels = sessionLabels;
end

fprintf('Loaded %d animals.\n', idx);
disp({NOIOData.ID}');
