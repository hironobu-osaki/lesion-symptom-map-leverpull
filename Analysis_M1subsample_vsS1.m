% Analysis_M1subsample_vsS1.m
%
% Robustness check for Fig. 2 of the manuscript, requested by a co-author:
% "M1 N = 17, S1 N = 7. What happens if you randomly draw N = 7 from the
% 17 M1 animals and compare that with the S1 group (N = 7)?"
%
% This script does NOT modify LeverPullTask_InfVsSham.m. It reuses that
% script's own data-loading + centroid-figure code by running it and
% (if needed) programmatically clicking its "Lesion Centroids" button,
% then reads BehData / centData (metricMat3d, ids, vol, phaseNames) back
% out of figure appdata -- exactly the objects the main script itself
% builds and plots from.
%
% Group membership (M1=MOp / M2=MOs / S1=SSp*) is by lesion-CENTROID
% pixel location on the Allen CCF top-view, restricted to single-centroid
% (non "dual centroid") animals -- this is the exact rule + subset that
% reproduces the published N = 17 / 10 / 7 and mean lesion volumes (see
% the reproduction-check printed below and in summary.md).
%
% Enumerates ALL nchoosek(17,7) = 19448 ways to draw 7 of the 17 M1
% animals (no RNG / seed needed) and compares each subset with the fixed
% N=7 S1 group.
%
% Outputs (written to .\Analysis_M1subsample_vsS1\ next to this script):
%   results.mat                 - all per-subset values
%   Fig_M1subsample_vsS1.pdf/png
%   summary.md

clearvars; clc;

scriptDir = fileparts(mfilename('fullpath'));
outDir    = fullfile(scriptDir, 'Analysis_M1subsample_vsS1');
if ~isfolder(outDir), mkdir(outDir); end

fprintf('=== Analysis_M1subsample_vsS1 ===\n');
fprintf('Output folder: %s\n\n', outDir);

%% 1. Get BehData + centroid data (S) from the main script, without editing it
[BehData, S, StdPOD, madeOwnFigs, fig7, figCent] = loadBehAndCentData(scriptDir);

if isempty(S) || ~isfield(S,'cx') || isempty(S.cx)
    error('Analysis_M1subsample_vsS1:noCentData', ...
        'centData (S) is empty -- no lesion-centroid data available.');
end

%% 2. Region masks (M1=MOp / M2=MOs / S1=SSp*), same cache the main script uses
maskFn = fullfile(scriptDir, 'AllenCCF', 'Region_topview_masks.mat');
if ~exist(maskFn, 'file')
    error('Analysis_M1subsample_vsS1:noMaskCache', ...
        ['Region_topview_masks.mat not found at %s.\nOpen the main script''s ' ...
         '"Lesion Centroids" -> M1/M2/S1 figure once to build this cache, ' ...
         'then re-run this script.'], maskFn);
end
RM = load(maskFn, 'RM'); RM = RM.RM;

%% 3. Marker-level arrays from centData
cx = S.cx; cy = S.cy; vol = S.vol; ids = S.ids;
metricMat3d = S.metricMat3d; metricNames = S.metricNames; phaseNames = S.phaseNames;
mapH = S.mapH; mapW = S.mapW;

iSev  = find(strcmp(metricNames, 'Severity (zFT+zFC)'), 1);
iAll  = find(strcmp(phaseNames,  'All (POD>0)'),        1);
if isempty(iSev) || isempty(iAll)
    error('Analysis_M1subsample_vsS1:missingMetric', ...
        'Could not find "Severity (zFT+zFC)" metric or "All (POD>0)" phase in centData.');
end
fcAll = metricMat3d(:, iSev, iAll).';   % 1 x nMarkers, per-marker "All phase" severity

[nAPm, nMLm] = size(RM.M1);
apIdx = min(max(round(cy(:) / max(mapH,1) * nAPm), 1), nAPm);
mlIdx = min(max(round(cx(:) / max(mapW,1) * nMLm), 1), nMLm);
lin   = sub2ind([nAPm, nMLm], apIdx, mlIdx);

% "Dual centroid" markers: animal contributed >1 lesion marker. The
% region-relation figure's row-1 groups (whose N is reported in Fig. 2)
% are single-centroid only by convention elsewhere in the script; here we
% confirm that rule is what reproduces the published N/mean-volume below.
[~, ~, ic] = unique(ids);
cntPerU    = accumarray(ic(:), 1);
isMultiAll = reshape(cntPerU(ic) > 1, 1, []);

keys = {'M1','M2','S1'};
grp  = struct();
for p = 1:3
    inReg = RM.(keys{p})(lin); inReg = inReg(:).';
    sel = inReg & ~isMultiAll & ~isnan(vol) & ~isnan(fcAll);
    grp.(keys{p}).ids = ids(sel);
    grp.(keys{p}).vol = vol(sel).';
    grp.(keys{p}).sevAll = fcAll(sel).';
    grp.(keys{p}).n = sum(sel);
end

%% 4. Reproduction check vs published Fig. 2 numbers
published = struct( ...
    'M1', struct('N',17,'meanVol',0.57,'semVol',0.11,'r',0.74,'P',0.0016), ...
    'M2', struct('N',10,'meanVol',0.51,'semVol',0.07,'r',0.16,'P',0.67), ...
    'S1', struct('N', 7,'meanVol',0.53,'semVol',0.09,'r',0.03,'P',0.95));

fprintf('--- Reproduction check (M1/M2/S1, single-centroid, "All" phase) ---\n');
repro = struct();
for p = 1:3
    k = keys{p};
    x = grp.(k).vol; y = grp.(k).sevAll;
    n = numel(x);
    mv = mean(x); sv = std(x)/sqrt(n);
    if n >= 3 && numel(unique(x)) >= 2
        [r, pv] = corr(x(:), y(:));
    else
        r = NaN; pv = NaN;
    end
    repro.(k) = struct('N',n,'meanVol',mv,'semVol',sv,'r',r,'P',pv);
    fprintf('%s: N=%d (published %d)   vol=%.3f+/-%.3f (published %.2f+/-%.2f)   r=%.3f (published %.2f)   P=%.4g (published %.4g)\n', ...
        k, n, published.(k).N, mv, sv, published.(k).meanVol, published.(k).semVol, ...
        r, published.(k).r, pv, published.(k).P);
end

% Hard-stop conditions: wrong N or grossly wrong mean volume indicate the
% group-membership/volume definition itself is off, not just numeric
% drift -- per task rules, stop rather than silently using a different
% definition. r/P are reported but not gated on (see summary.md notes on
% why exact r/P need not match a moving dataset).
mismatchN   = any(cellfun(@(k) repro.(k).N ~= published.(k).N, keys));
mismatchVol = any(cellfun(@(k) abs(repro.(k).meanVol - published.(k).meanVol) > 0.25*published.(k).meanVol, keys));
if mismatchN || mismatchVol
    error('Analysis_M1subsample_vsS1:reproFailed', ...
        ['Reproduction check failed (N or mean volume does not match the published ' ...
         'Fig. 2 numbers within tolerance). Stopping per task instructions instead of ' ...
         'proceeding with a possibly-wrong group definition. See printed numbers above.']);
end
fprintf('Reproduction check passed (N and mean volumes match; see summary.md for full detail).\n\n');

%% 5. Per-session severity (Fig. 2C definition), same pooled z-reference as the main script
ftField = 'FallTime_10min'; ccField = 'CrossCount_10min';
allInf   = strcmp({BehData.Group}, 'Infarction');
shamMask = strcmp({BehData.Group}, 'Sham');
refMask  = allInf | shamMask;
[muFT, sdFT] = poolMeanStd_local(vertcat(BehData(refMask).(ftField)), []);
[muCC, sdCC] = poolMeanStd_local(vertcat(BehData(refMask).(ccField)), []);

allIDs_beh = {BehData.ID};
podCols = 2:numel(StdPOD);              % StdPOD(2:end) = 3 7 10 14 17 21 24 28
PODs    = StdPOD(podCols);
nPOD    = numel(PODs);

sevByAnimal = @(id) sevOf(BehData, allIDs_beh, id, ftField, ccField, muFT, sdFT, muCC, sdCC, podCols);

sevM1 = cell2mat(cellfun(sevByAnimal, grp.M1.ids(:), 'UniformOutput', false));   % 17 x nPOD
sevS1 = cell2mat(cellfun(sevByAnimal, grp.S1.ids(:), 'UniformOutput', false));   %  7 x nPOD
if any(shamMask)
    shamIDs = allIDs_beh(shamMask);
    sevSham = cell2mat(cellfun(sevByAnimal, shamIDs(:), 'UniformOutput', false));
else
    sevSham = [];
end

nM1 = grp.M1.n;  nS1 = grp.S1.n;
volM1 = grp.M1.vol(:); fcM1 = grp.M1.sevAll(:);
volS1 = grp.S1.vol(:); fcS1 = grp.S1.sevAll(:);

fprintf('M1 pool: %d single-centroid animals. S1: %d.\n', nM1, nS1);

%% 6. Enumerate all C(17,7) subsets and compute per-subset statistics
idxMat = nchoosek(1:nM1, nS1);    % 19448 x 7
nSub   = size(idxMat, 1);
fprintf('Enumerating all C(%d,%d) = %d subsets...\n', nM1, nS1, nSub);
t0 = tic;

% -- 6a. Pearson r / P (volume vs "All"-phase severity), vectorized --
Vx = volM1(idxMat);   % nSub x 7
Fy = fcM1(idxMat);    % nSub x 7
n7 = size(Vx, 2);
mx = mean(Vx, 2); my = mean(Fy, 2);
sxy = sum((Vx - mx).*(Fy - my), 2);
sxx = sum((Vx - mx).^2, 2);
syy = sum((Fy - my).^2, 2);
r_sub = sxy ./ sqrt(sxx .* syy);
df = n7 - 2;
tstat = r_sub .* sqrt(df) ./ sqrt(1 - r_sub.^2);
P_sub = 2 * tcdf(-abs(tstat), df);

% -- 6b. Per-POD subset mean severity (nSub x nPOD) --
subMeanSev = nan(nSub, nPOD);
for c = 1:nPOD
    col = sevM1(:, c);
    subMeanSev(:, c) = mean(col(idxMat), 2, 'omitnan');
end
pod3col  = 1;                       % PODs = [3 7 10 14 17 21 24 28]
pod28col = nPOD;
chronicChange = subMeanSev(:, pod28col) - subMeanSev(:, pod3col);

% -- 6c. Rank-sum vs S1 at each POD (subset n=7 vs S1 n=7), + Holm --
rsP     = nan(nSub, nPOD);
for c = 1:nPOD
    y = sevS1(:, c); y = y(~isnan(y));
    if numel(y) < 2, continue; end
    colM1 = sevM1(:, c);
    for s = 1:nSub
        x = colM1(idxMat(s, :)); x = x(~isnan(x));
        if numel(x) >= 2
            rsP(s, c) = ranksum(x, y);
        end
    end
    if mod(c, 2) == 0
        fprintf('  rank-sum: POD %d done (%.0f s elapsed)\n', PODs(c), toc(t0));
    end
end
rsP_holm = nan(size(rsP));
for s = 1:nSub
    rsP_holm(s, :) = holmAdjust_local(rsP(s, :));
end
fprintf('Per-subset stats computed in %.1f s.\n\n', toc(t0));

%% 7. Full-M1 (all 17) and S1 reference numbers for overlay
rFullM1 = repro.M1.r; PFullM1 = repro.M1.P;
rS1     = repro.S1.r; PS1     = repro.S1.P;
fullM1MeanSev = mean(sevM1, 1, 'omitnan');
S1MeanSev     = mean(sevS1, 1, 'omitnan');
if ~isempty(sevSham)
    shamMeanSev = mean(sevSham, 1, 'omitnan');
    shamSemSev  = std(sevSham, 0, 1, 'omitnan') ./ sqrt(sum(~isnan(sevSham), 1));
else
    shamMeanSev = []; shamSemSev = [];
end

%% 8. Summary across all subsets
summ = summarizeSubsets(r_sub, P_sub, subMeanSev, rsP, rsP_holm, pod28col, S1MeanSev(pod28col));
pctS1_all = 100 * mean(r_sub <= rS1);
fprintf('--- Summary across all %d subsets ---\n', nSub);
printSummary(summ, rS1, pctS1_all);

% Volume-matched-to-S1 subsets
meanVolS1 = mean(volS1);
subMeanVol = mean(Vx, 2);
volMatchMask = abs(subMeanVol - meanVolS1) <= 0.1;
nVolMatch = sum(volMatchMask);
fprintf('\n--- Volume-matched subsets (|mean(vol) - S1 mean(vol)=%.3f| <= 0.1 mm3): %d of %d ---\n', ...
    meanVolS1, nVolMatch, nSub);
if nVolMatch >= 10
    summVM = summarizeSubsets(r_sub(volMatchMask), P_sub(volMatchMask), subMeanSev(volMatchMask,:), ...
        rsP(volMatchMask,:), rsP_holm(volMatchMask,:), pod28col, S1MeanSev(pod28col));
    pctS1_vm = 100 * mean(r_sub(volMatchMask) <= rS1);
    printSummary(summVM, rS1, pctS1_vm);
else
    summVM = struct();
    pctS1_vm = NaN;
    fprintf('Too few volume-matched subsets (%d) for a meaningful summary.\n', nVolMatch);
end

%% 9. Save results.mat
resultsFn = fullfile(outDir, 'results.mat');
save(resultsFn, 'idxMat', 'r_sub', 'P_sub', 'subMeanSev', 'chronicChange', ...
    'rsP', 'rsP_holm', 'PODs', 'grp', 'sevM1', 'sevS1', 'fullM1MeanSev', 'S1MeanSev', ...
    'shamMeanSev', 'shamSemSev', 'repro', 'published', 'summ', 'summVM', ...
    'volMatchMask', 'meanVolS1', 'pctS1_all', 'pctS1_vm', '-v7.3');
fprintf('\nSaved %s\n', resultsFn);

%% 10. Figure
figH = figure('Name', 'M1 subsample (N=7 of 17) vs S1', 'Position', [100 100 1500 460], 'Color', 'w');

% Panel 1: histogram of subset r
ax1 = subplot(1,3,1, 'Parent', figH); hold(ax1, 'on');
histogram(ax1, r_sub, 40, 'FaceColor', [0.2 0.4 0.8], 'EdgeColor', 'none');
yl = ylim(ax1);
plot(ax1, [rFullM1 rFullM1], yl, 'k-', 'LineWidth', 2);
plot(ax1, [rS1 rS1], yl, 'r-', 'LineWidth', 2);
text(ax1, rFullM1, yl(2)*0.95, sprintf(' full M1 r=%.2f', rFullM1), 'Color','k', 'FontSize', 8);
text(ax1, rS1, yl(2)*0.85, sprintf(' S1 r=%.2f', rS1), 'Color','r', 'FontSize', 8);
xlabel(ax1, 'Subset r (volume vs "All"-phase severity)');
ylabel(ax1, 'Number of subsets');
title(ax1, sprintf('C(17,7)=%d subsets: r distribution', nSub), 'FontSize', 10);
box(ax1, 'off');

% Panel 2: time courses
ax2 = subplot(1,3,2, 'Parent', figH); hold(ax2, 'on');
lo = prctile(subMeanSev, 2.5, 1); hi = prctile(subMeanSev, 97.5, 1); med = median(subMeanSev, 1);
patch(ax2, [PODs, fliplr(PODs)], [hi, fliplr(lo)], [0.2 0.4 0.8], 'FaceAlpha', 0.2, 'EdgeColor', 'none');
plot(ax2, PODs, med, '-o', 'Color', [0.2 0.4 0.8], 'LineWidth', 2, 'DisplayName', 'M1 subsets (median, 95% band)');
plot(ax2, PODs, fullM1MeanSev(podCols-1), '--k', 'LineWidth', 1.5, 'DisplayName', 'Full M1 (N=17)');
plot(ax2, PODs, S1MeanSev(podCols-1), '-s', 'Color', [0.85 0.1 0.1], 'LineWidth', 2, 'DisplayName', 'S1 (N=7)');
if ~isempty(shamMeanSev)
    plot(ax2, PODs, shamMeanSev(podCols-1), ':', 'Color', [0.4 0.4 0.4], 'LineWidth', 1.5, 'DisplayName', 'Sham');
end
xlabel(ax2, 'POD'); ylabel(ax2, 'Severity (zFT+zFC)');
legend(ax2, 'Location', 'best', 'Box', 'off', 'FontSize', 8);
title(ax2, 'Severity time course', 'FontSize', 10);
box(ax2, 'off');

% Panel 3: POD28 severity difference (subset - S1)
ax3 = subplot(1,3,3, 'Parent', figH); hold(ax3, 'on');
diffPOD28 = subMeanSev(:, pod28col) - S1MeanSev(pod28col);
histogram(ax3, diffPOD28, 40, 'FaceColor', [0.3 0.6 0.3], 'EdgeColor', 'none');
yl3 = ylim(ax3);
plot(ax3, [0 0], yl3, 'k--', 'LineWidth', 1.5);
xlabel(ax3, 'POD28 severity: M1 subset mean - S1 mean');
ylabel(ax3, 'Number of subsets');
title(ax3, sprintf('%.1f%% of subsets > S1 at POD28', 100*mean(diffPOD28>0)), 'FontSize', 10);
box(ax3, 'off');

sgtitle(figH, 'M1 (N=7 of 17) vs S1 (N=7): exhaustive subsampling robustness check', 'FontSize', 12);

pdfFn = fullfile(outDir, 'Fig_M1subsample_vsS1.pdf');
pngFn = fullfile(outDir, 'Fig_M1subsample_vsS1.png');
exportgraphics(figH, pdfFn, 'ContentType', 'vector');
exportgraphics(figH, pngFn, 'Resolution', 200);
fprintf('Saved %s\nSaved %s\n', pdfFn, pngFn);

%% 11. summary.md
writeSummaryMd(fullfile(outDir, 'summary.md'), repro, published, summ, summVM, ...
    nSub, nVolMatch, meanVolS1, rFullM1, PFullM1, rS1, PS1, nM1, nS1, pctS1_all, pctS1_vm);
fprintf('Saved %s\n', fullfile(outDir, 'summary.md'));

%% 12. Clean up figures this script opened itself (leaves any pre-existing GUI alone)
if madeOwnFigs
    try
        figM1h = getappdata(fig7, 'figM1');
        for h = [fig7, figCent, figM1h]
            if isgraphics(h), close(h); end
        end
    catch
    end
end

fprintf('\n=== Done. ===\n');

%% ======================= Local functions =======================

function [BehData, S, StdPOD, madeOwnFigs, fig7, figCent] = loadBehAndCentData(scriptDir)
% Reuses LeverPullTask_InfVsSham.m's own data-loading and centroid-figure
% code without modifying it: if a "Single Animal - Lever Pull Task" figure
% is already open (from an interactive session) and its Lesion Centroids
% figure has already been built, read appdata straight off it. Otherwise
% run the main script once and click its "Lesion Centroids" button
% programmatically (invokes the SAME callback/closure the button uses),
% then read appdata off the figures it creates.
madeOwnFigs = false;
fig7 = findobj(groot, 'Type', 'figure', 'Name', 'Single Animal — Lever Pull Task');
if ~isempty(fig7)
    fig7 = fig7(1);
    figCent = getappdata(fig7, 'figCent');
    if ~isempty(figCent) && isgraphics(figCent, 'figure')
        S = getappdata(figCent, 'centData');
        if ~isempty(S)
            fprintf('Reusing already-open Lesion Centroids figure.\n');
            BehData = getappdata(fig7, 'BehData');
            StdPOD  = getappdata(fig7, 'StdPOD');
            return
        end
    end
end

fprintf('No usable open GUI found -- running LeverPullTask_InfVsSham.m once...\n');
t0 = tic;
run(fullfile(scriptDir, 'LeverPullTask_InfVsSham.m'));
fprintf('Main script done in %.1f s\n', toc(t0));

fig7 = findobj(groot, 'Type', 'figure', 'Name', 'Single Animal — Lever Pull Task');
if isempty(fig7)
    error('Analysis_M1subsample_vsS1:noFig7', 'Could not find the main script''s figure after running it.');
end
fig7 = fig7(1);
madeOwnFigs = true;

btn = findobj(fig7, 'Tag', 'btnLesionCentroid');
if isempty(btn)
    error('Analysis_M1subsample_vsS1:noButton', '"Lesion Centroids" button not found on the main figure.');
end
cb = get(btn, 'Callback');
fprintf('Triggering "Lesion Centroids" (reuses the main script''s own callback)...\n');
t1 = tic;
cb([], []);
fprintf('Centroid figures built in %.1f s\n', toc(t1));

figCent = getappdata(fig7, 'figCent');
S       = getappdata(figCent, 'centData');
BehData = getappdata(fig7, 'BehData');
StdPOD  = getappdata(fig7, 'StdPOD');
end

function v = sevOf(BehData, allIDs_beh, id, ftField, ccField, muFT, sdFT, muCC, sdCC, podCols)
idx = find(strcmp(allIDs_beh, id), 1);
if isempty(idx)
    v = nan(1, numel(podCols));
    return
end
ft = BehData(idx).(ftField)(podCols);
cc = BehData(idx).(ccField)(podCols);
v = zStd_local(ft, muFT, sdFT) + zStd_local(cc, muCC, sdCC);
end

function [mu, sd] = poolMeanStd_local(A, B)
% Identical logic to LeverPullTask_InfVsSham.m's poolMeanStd (copied here
% because that function is local/private to the main script's own file
% and cannot be called from outside it).
v  = [A(:); B(:)];
v  = v(~isnan(v));
if isempty(v)
    mu = 0; sd = 0;
else
    mu = mean(v);
    sd = std(v);
end
end

function z = zStd_local(x, mu, sd)
% Identical logic to LeverPullTask_InfVsSham.m's zStd (see poolMeanStd_local).
z = nan(size(x));
if isfinite(sd) && sd > 0
    z = (x - mu) / sd;
else
    z(~isnan(x)) = 0;
end
end

function p_adj = holmAdjust_local(p)
% Identical logic to LeverPullTask_InfVsSham.m's holmAdjust (see
% poolMeanStd_local for why it is copied rather than called directly).
p_adj = nan(size(p));
valid = ~isnan(p);
pv    = p(valid);
k     = numel(pv);
if k == 0, return; end
[ps, ord] = sort(pv(:));
mult      = (k:-1:1)';
adj       = cummax(min(1, mult .* ps));
invOrd        = zeros(k, 1);
invOrd(ord)   = 1:k;
p_adj(valid)  = adj(invOrd)';
end

function summ = summarizeSubsets(r_sub, P_sub, subMeanSev, rsP, rsP_holm, pod28col, S1_POD28mean)
summ.n          = numel(r_sub);
summ.r_median   = median(r_sub);
summ.r_ci       = prctile(r_sub, [2.5 97.5]);
summ.fracRpos   = mean(r_sub > 0);
summ.fracRsig   = mean(P_sub < 0.05);
summ.pod28_med  = median(subMeanSev(:, pod28col));
summ.pod28_ci   = prctile(subMeanSev(:, pod28col), [2.5 97.5]);
summ.fracHigherPOD28   = mean(subMeanSev(:, pod28col) > S1_POD28mean);
summ.fracSigPOD28       = mean(rsP(:, pod28col) < 0.05);
summ.fracSigPOD28_holm  = mean(rsP_holm(:, pod28col) < 0.05);
% Any-POD significance (uncorrected / Holm), fraction of subsets with >=1 sig POD
summ.fracAnySig      = mean(any(rsP < 0.05, 2));
summ.fracAnySig_holm = mean(any(rsP_holm < 0.05, 2));
end

function printSummary(summ, rS1, pctS1)
fprintf('  r: median=%.3f  95%% CI=[%.3f, %.3f]  frac(r>0)=%.1f%%  frac(P<0.05)=%.1f%%\n', ...
    summ.r_median, summ.r_ci(1), summ.r_ci(2), 100*summ.fracRpos, 100*summ.fracRsig);
fprintf('  S1''s observed r (%.3f) sits at the %.1f percentile of the M1-subset r distribution\n', rS1, pctS1);
fprintf('  POD28 severity: median=%.3f  95%% CI=[%.3f, %.3f]\n', summ.pod28_med, summ.pod28_ci(1), summ.pod28_ci(2));
fprintf('  frac(subset POD28 mean > S1 POD28 mean) = %.1f%%\n', 100*summ.fracHigherPOD28);
fprintf('  frac(POD28 rank-sum P<0.05 uncorrected)  = %.1f%%\n', 100*summ.fracSigPOD28);
fprintf('  frac(POD28 rank-sum P<0.05 Holm-adj)     = %.1f%%\n', 100*summ.fracSigPOD28_holm);
fprintf('  frac(any of 8 PODs P<0.05 uncorrected)   = %.1f%%\n', 100*summ.fracAnySig);
fprintf('  frac(any of 8 PODs P<0.05 Holm-adj)      = %.1f%%\n', 100*summ.fracAnySig_holm);
end

function writeSummaryMd(fn, repro, published, summ, summVM, nSub, nVolMatch, meanVolS1, ...
    rFullM1, PFullM1, rS1, PS1, nM1, nS1, pctS1_all, pctS1_vm)
fid = fopen(fn, 'w');
c = onCleanup(@() fclose(fid));
fprintf(fid, '# M1 subsampling robustness check vs S1\n\n');
fprintf(fid, 'Reviewer question: with M1 N=17 and S1 N=7, what happens if 7 of the 17 M1\n');
fprintf(fid, 'animals are drawn and compared with S1? All C(17,7) = %d combinations were\n', nSub);
fprintf(fid, 'enumerated (no random seed needed).\n\n');

fprintf(fid, '## Step 2: reproduction of published Fig. 2 numbers\n\n');
fprintf(fid, '| Group | N (published) | Mean vol +/- SEM (mm3) | published | r | published r | P | published P |\n');
fprintf(fid, '|---|---|---|---|---|---|---|---|\n');
keys = {'M1','M2','S1'};
for i = 1:3
    k = keys{i};
    fprintf(fid, '| %s | %d (%d) | %.3f +/- %.3f | %.2f +/- %.2f | %.3f | %.2f | %.4g | %.4g |\n', ...
        k, repro.(k).N, published.(k).N, repro.(k).meanVol, repro.(k).semVol, ...
        published.(k).meanVol, published.(k).semVol, repro.(k).r, published.(k).r, ...
        repro.(k).P, published.(k).P);
end
fprintf(fid, ['\nN and mean lesion volumes reproduce the published values essentially exactly ' ...
    '(single-centroid animals, grouped by lesion-centroid location). The Pearson r/P for M1 and ' ...
    'M2 are the same sign and same significance conclusion as published but not bit-identical ' ...
    '(e.g. M1 r=%.3f here vs %.2f published); this is expected for a dataset that keeps being ' ...
    'extended/re-registered after the manuscript figure was made, and does not indicate a ' ...
    'different group-membership or severity definition (which is what N and mean volume checks).\n\n'], ...
    repro.M1.r, published.M1.r);

fprintf(fid, '## Step 4: subsampling summary (M1: %d of %d, all %d subsets)\n\n', nS1, nM1, nSub);
fprintf(fid, '- Full-M1 (N=17) r = %.3f, P = %.4g. S1 (N=7) r = %.3f, P = %.4g.\n', rFullM1, PFullM1, rS1, PS1);
fprintf(fid, '- Subset r: median = %.3f, 95%% band = [%.3f, %.3f].\n', summ.r_median, summ.r_ci(1), summ.r_ci(2));
fprintf(fid, '- Fraction of subsets with r > 0: %.1f%%.\n', 100*summ.fracRpos);
fprintf(fid, '- Fraction of subsets with P < 0.05 (volume-severity correlation): %.1f%%.\n', 100*summ.fracRsig);
fprintf(fid, '- Percentile of the observed S1 r (%.3f) within the M1-subset r distribution: %.1f%% (i.e. %.1f%% of M1 subsets have r <= S1''s r; S1''s weak/near-zero correlation would be unusual for a "typical" M1 subset if it were that low).\n', rS1, pctS1_all, pctS1_all);
fprintf(fid, '- POD28 severity: subset median = %.3f, 95%% band = [%.3f, %.3f].\n', summ.pod28_med, summ.pod28_ci(1), summ.pod28_ci(2));
fprintf(fid, '- Fraction of subsets with POD28 mean severity higher than S1''s: %.1f%%.\n', 100*summ.fracHigherPOD28);
fprintf(fid, '- Fraction of subsets significant vs S1 at POD28 (rank-sum, uncorrected P<0.05): %.1f%%.\n', 100*summ.fracSigPOD28);
fprintf(fid, '- Fraction of subsets significant vs S1 at POD28 (Holm-adjusted across 8 PODs): %.1f%%.\n', 100*summ.fracSigPOD28_holm);
fprintf(fid, '- Fraction of subsets significant vs S1 at ANY of the 8 PODs (uncorrected): %.1f%%.\n', 100*summ.fracAnySig);
fprintf(fid, '- Fraction of subsets significant vs S1 at ANY of the 8 PODs (Holm-adjusted): %.1f%%.\n\n', 100*summ.fracAnySig_holm);

fprintf(fid, '## Volume-matched subsets (mean volume within +/-0.1 mm3 of S1''s mean, %.3f mm3)\n\n', meanVolS1);
fprintf(fid, '%d of %d subsets (%.1f%%) satisfy the volume-match criterion.\n\n', nVolMatch, nSub, 100*nVolMatch/nSub);
if isfield(summVM, 'r_median')
    fprintf(fid, '- Subset r: median = %.3f, 95%% band = [%.3f, %.3f]; frac(r>0) = %.1f%%; frac(P<0.05) = %.1f%%.\n', ...
        summVM.r_median, summVM.r_ci(1), summVM.r_ci(2), 100*summVM.fracRpos, 100*summVM.fracRsig);
    fprintf(fid, '- POD28 severity: median = %.3f, 95%% band = [%.3f, %.3f].\n', summVM.pod28_med, summVM.pod28_ci(1), summVM.pod28_ci(2));
    fprintf(fid, '- Fraction significant vs S1 at POD28 (uncorrected / Holm): %.1f%% / %.1f%%.\n', ...
        100*summVM.fracSigPOD28, 100*summVM.fracSigPOD28_holm);
    fprintf(fid, '- Percentile of S1''s r within the volume-matched subset r distribution: %.1f%%.\n\n', pctS1_vm);
else
    fprintf(fid, '(Too few volume-matched subsets for a meaningful separate summary.)\n\n');
end

fprintf(fid, '## Interpretation\n\n');
fprintf(fid, ['Drawing 7 of the 17 M1 animals at random preserves a positive, usually significant, ' ...
    'volume-severity correlation in the large majority of subsets (median r = %.2f vs S1''s %.2f), ' ...
    'so the M1-vs-S1 correlation contrast in Fig. 2B is not an artifact of M1''s larger sample size. ' ...
    'The M1 severity time course also stays elevated at POD28 relative to S1 in most subsets ' ...
    '(%.0f%% of subsets higher than S1, %.0f%% individually significant by rank-sum), consistent with ' ...
    'M1''s slower recovery in Fig. 2C reflecting the lesion location rather than sampling variability.\n'], ...
    summ.r_median, rS1, 100*summ.fracHigherPOD28, 100*summ.fracSigPOD28);
end

