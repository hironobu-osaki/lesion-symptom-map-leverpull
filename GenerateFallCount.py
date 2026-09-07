"""
GenerateFallCount.py
Usage: python GenerateFallCount.py <animal_folder>

For each *.mp4 session file in <animal_folder> that has a DLC .h5 output but
no corresponding *_FallCount.mat, compute FallTime/RegularHoldTime/CrossCount
and save *_FallCount.mat.

Extracted from LeverPullTask_IO_NO.ipynb (Cell 10).
"""

import sys
import os
import glob
import numpy as np
import scipy.io
import yaml
import h5py
from scipy.signal import butter, filtfilt
import matplotlib
matplotlib.use('Agg')   # no display
import matplotlib.pyplot as plt

# ── Configuration ──────────────────────────────────────────────────────────────
# Path to the DeepLabCut project config.yaml. Set the environment variable
# DLC_CONFIG_PATH (or edit the default below) for your machine.
CONFIG_PATH  = os.environ.get('DLC_CONFIG_PATH', '')
USED_MODEL   = 'DLC_resnet50_LeverPullTaskNov14shuffle1_251211'
FS           = 60.0   # camera frame rate (Hz)
FALL_THR     = 7.5    # mm — forelimb "fall" threshold
HOLD_THR     = 5.0    # mm — regular hold threshold
LP_CUTOFF    = 0.1    # Hz — distance signal low-pass cutoff
LP_CUTOFF_Z  = 7.0    # Hz — Z-distance low-pass cutoff
NO_PULL_THR  = 1.0    # mm — lever-pull noise exclusion margin
MIN_FALL_DUR_S    = 0.3   # s  — minimum event duration to count as a fall
ZDOT_ONSET_FRAMES = 5     # frames to average for Z-velocity at event onset
EYE_Y_THRESH      = 100   # px — raw Y below this is in the eye region (top of frame)
SPREAD_THRESH     = 150   # px — inter-part spread triggers outlier detection (after A)
LEVER_DIST_THRESH = 250   # px — centroid too far from stable lever → mark all bad (C)
# ── Physiological distance bounds (mm) ─────────────────────────────────────
MAX_XY_DIST_MM      = 10.0  # mm — forelimb cannot be > 10 mm from lever in XY
                              #      (hindlimb misdetection in bottom view produces >> 10 mm)
MAX_FI_PA_SPREAD_MM = 5.0   # mm — finger–paw separation cannot exceed ~5 mm
                              #      (hindlimb detected instead of forelimb spreads them apart)
# ── Fall confidence thresholds ──────────────────────────────────────────────
Z_SHELL_THR    = -2.0   # mm — distZ < this = paw dropped (true fall indicator)
                         #      distZ ≥ this when dist > FALL_THR → shell/body holding
ANGLE_FALL_THR = 160.0  # deg — finger-paw-wrist angle > this = fingers straight (fall)
ANGLE_HOLD_THR = 130.0  # deg — angle < this = fingers bent (gripping = hold)


# ── Helper functions (from notebook) ───────────────────────────────────────────

def find_session_mp4s(directory):
    """Return raw session mp4 files, excluding labeled/trimmed/output variants."""
    all_mp4  = set(glob.glob(os.path.join(directory, '*-*-*-*-*.mp4')))
    labeled  = set(glob.glob(os.path.join(directory, '*-*-*-*-*_labeled.mp4')))
    output   = set(glob.glob(os.path.join(directory, '*-*-*-*-*_output_video.mp4')))
    trimmed  = set(glob.glob(os.path.join(directory, '*-*-*-*-*_Trimmed.mp4')))
    return sorted(all_mp4 - labeled - output - trimmed)


def load_bodyparts(config_path):
    """Read body-part list from DLC config.yaml."""
    with open(config_path, 'r') as f:
        cfg = yaml.safe_load(f)
    base_bp = cfg['bodyparts']
    # DLC flattens to [BP, BP_Y, BP_Likelihood, ...]
    bodyparts = []
    for bp in base_bp:
        bodyparts += [bp, bp + '_Y', bp + '_Likelihood']
    return base_bp, bodyparts


def extract_pose(positions, hdf_name, bodyparts):
    idx = bodyparts.index(hdf_name)
    F   = np.arange(len(positions))
    return positions[F, idx], positions[F, idx+1], F, positions[F, idx+2]


def find_h5_for_session(folder, movie_name):
    """Find the DLC h5 file for a session, preferring the highest model iteration."""
    preferred = os.path.join(folder, movie_name + USED_MODEL + '.h5')
    if os.path.exists(preferred):
        return preferred
    # Fall back to any DLC h5 that matches the session (not labeled/meta)
    candidates = glob.glob(os.path.join(folder, movie_name + 'DLC_*.h5'))
    candidates = [c for c in candidates if not c.endswith('_meta.pickle')]
    if not candidates:
        raise FileNotFoundError(f'No DLC .h5 found for {movie_name} in {folder}')
    # Pick highest model iteration number
    def _iter(p):
        import re
        m = re.search(r'shuffle\d+_(\d+)\.h5$', p)
        return int(m.group(1)) if m else 0
    return max(candidates, key=_iter)


def extract_position_allframe(video_path, hdf_name, bodyparts):
    folder, fname = os.path.split(video_path)
    movie_name    = fname[:-4]
    h5_path       = find_h5_for_session(folder, movie_name)
    with h5py.File(h5_path, 'r') as f:
        positions = f['/df_with_missing/table']['values_block_0'][:]
    X, Y, F, L = extract_pose(positions, hdf_name, bodyparts)
    return F, X, Y, L


def calc_mean_xy(filtered_X, filtered_Y, idx_list):
    def _mean_1d(arr):
        out = np.zeros(len(arr))
        for i, row in enumerate(arr):
            sel = row[idx_list].astype(float)
            sel[sel == 0] = np.nan
            v = np.nanmean(sel)
            out[i] = v if not np.isnan(v) else (out[i-1] if i > 0 else 0.0)
        return out
    return _mean_1d(filtered_X), _mean_1d(filtered_Y)


def shortest_distance(A, B, C):
    A, B, C = np.array(A), np.array(B), np.array(C)
    AB = B - A
    cross = np.cross(AB, C - A)
    return np.linalg.norm(cross) / np.linalg.norm(AB)


def lowpass_filter(data, cutoff, fs, order=5):
    nyq = 0.5 * fs
    b, a = butter(order, cutoff / nyq, btype='low')
    return filtfilt(b, a, data)


def interpolate_nan(data):
    nans = np.isnan(data)
    if nans.any():
        valid = ~nans
        if not valid.any():
            return data   # all NaN — nothing to interpolate
        x = lambda z: z.nonzero()[0]
        data[nans] = np.interp(x(nans), x(valid), data[valid])
    return data


def _lever_calib_mean(Xall, Yall, Lall, bp, calib_frame):
    """Mean (x, y) position of body part bp for calibration.

    Uses only raw frames >= calib_frame where likelihood >= 0.8 so that
    carry-forward contamination from a cropped / repositioned mirror does
    not corrupt the session-wide scalar used in XYscale.
    Falls back to all valid frames if none qualify from calib_frame.
    """
    Xsub = Xall[calib_frame:, bp]
    Ysub = Yall[calib_frame:, bp]
    det  = Lall[calib_frame:, bp] >= 0.8
    if det.any():
        return float(np.mean(Xsub[det])), float(np.mean(Ysub[det]))
    # Fallback: any frame in the full session with valid likelihood
    det_all = Lall[:, bp] >= 0.8
    if det_all.any():
        return float(np.mean(Xall[det_all, bp])), float(np.mean(Yall[det_all, bp]))
    return 0.0, 0.0


# ── Event-level analysis helpers ────────────────────────────────────────────────

def find_threshold_events(signal, threshold):
    """Return list of dicts {start, end, duration_frames, duration_s} for each
    contiguous segment where signal > threshold."""
    events, in_ev, start = [], False, 0
    for i, v in enumerate(signal):
        if v > threshold and not in_ev:
            in_ev, start = True, i
        elif v <= threshold and in_ev:
            in_ev = False
            events.append(dict(start=start, end=i - 1))
    if in_ev:
        events.append(dict(start=start, end=len(signal) - 1))
    for ev in events:
        ev['duration_frames'] = ev['end'] - ev['start'] + 1
        ev['duration_s']      = ev['duration_frames'] / FS
    return events


def extract_event_features(events, dist_filt, distZ_filt, distXY):
    """Compute a 7-element feature vector for each event.
    Features: duration_s, max_dist, z_at_peak, xy_at_peak,
              z_xy_ratio, zdot_onset, mean_z"""
    feats = []
    for ev in events:
        s, e = ev['start'], ev['end']
        seg_d  = dist_filt[s:e + 1]
        seg_z  = distZ_filt[s:e + 1]
        seg_xy = distXY[s:e + 1]

        # Z velocity at onset: mean frame-to-frame difference over first N frames
        n_onset  = min(ZDOT_ONSET_FRAMES + 1, e - s + 2)
        z_onset  = distZ_filt[s: s + n_onset]
        zdot     = float(np.mean(np.diff(z_onset))) if len(z_onset) > 1 else 0.0

        pk = int(np.argmax(seg_d))
        feats.append({
            'duration_s':  ev['duration_s'],
            'max_dist':    float(np.max(seg_d)),
            'z_at_peak':   float(seg_z[pk]),
            'xy_at_peak':  float(seg_xy[pk]),
            'z_xy_ratio':  float(seg_z[pk] / (seg_xy[pk] + 1e-6)),
            'zdot_onset':  zdot,
            'mean_z':      float(np.mean(seg_z)),
        })
    return feats


def classify_duration_zdv(feats):
    """Label each event as fall (1) or release (0).
    Fall = duration >= MIN_FALL_DUR_S  AND  Z-velocity at onset <= 0.
    (zdot_onset > 0 means forelimb moving upward = volitional release.)"""
    return np.array(
        [1 if f['duration_s'] >= MIN_FALL_DUR_S and f['zdot_onset'] <= 0 else 0
         for f in feats], dtype=np.int32)


def classify_pca_gmm(feats):
    """PCA (2-D) followed by GMM (2 components) on per-event features.
    Returns (labels, pca_coords [n×2], explained_variance_ratio [2])."""
    try:
        from sklearn.preprocessing import StandardScaler
        from sklearn.decomposition import PCA
        from sklearn.mixture import GaussianMixture
    except ImportError:
        print('    WARNING: scikit-learn not available — skipping PCA/GMM.')
        n = len(feats)
        return np.zeros(n, dtype=np.int32), np.zeros((n, 2)), np.zeros(2)

    n = len(feats)
    if n < 2:
        return np.zeros(n, dtype=np.int32), np.zeros((n, 2)), np.zeros(2)

    keys = ['duration_s', 'max_dist', 'z_at_peak', 'xy_at_peak',
            'z_xy_ratio', 'zdot_onset', 'mean_z']
    X     = np.array([[f[k] for k in keys] for f in feats], dtype=float)
    X_sc  = StandardScaler().fit_transform(X)
    pca   = PCA(n_components=2)
    X_pc  = pca.fit_transform(X_sc)

    gmm    = GaussianMixture(n_components=2, random_state=42, n_init=10)
    labels = gmm.fit_predict(X_pc).astype(np.int32)

    # Orient: label 1 = cluster with longer mean duration (= fall)
    dur = np.array([f['duration_s'] for f in feats])
    mean_dur = [np.mean(dur[labels == k]) if np.any(labels == k) else 0.0
                for k in (0, 1)]
    if mean_dur[0] > mean_dur[1]:
        labels = (1 - labels).astype(np.int32)

    return labels, X_pc, pca.explained_variance_ratio_


# ── Eye artifact filter ────────────────────────────────────────────────────────

def filter_eye_artifacts(Xall, Yall, filtered_X, filtered_Y, fi_r, pa_r, wr_r, lr_wt):
    """Remove eye-region artifact frames from filtered forelimb positions.

    Three-stage filter applied per frame:
      A: raw Y < EYE_Y_THRESH  →  mark part as bad
      B: spread among remaining valid parts > SPREAD_THRESH
         →  mark the outlier (furthest from centroid) as bad
      C: centroid of valid parts > LEVER_DIST_THRESH from stable lever
         →  mark all forelimb parts as bad for that frame

    Zeroes filtered_X/Y in-place for bad frames/parts.
    """
    bp_idx = np.array([fi_r, pa_r] if wr_r is None else [fi_r, pa_r, wr_r])
    n_frames = Xall.shape[0]

    # Stable lever reference: median of non-zero likelihood-filtered lever tip
    lx = filtered_X[:, lr_wt]
    ly = filtered_Y[:, lr_wt]
    valid_lev = (lx != 0) | (ly != 0)
    if np.any(valid_lev):
        slx, sly = np.median(lx[valid_lev]), np.median(ly[valid_lev])
    else:
        slx, sly = np.nan, np.nan

    Yraw = Yall[:, bp_idx]               # (n_frames, n_bp) raw Y
    FX   = filtered_X[:, bp_idx].copy()  # likelihood-filtered X (copy for staging)
    FY   = filtered_Y[:, bp_idx].copy()

    bad = np.zeros((n_frames, len(bp_idx)), dtype=bool)

    # --- A: raw Y in eye region (Y > 0 guards against undetected/zero rows) ---
    bad |= (Yraw < EYE_Y_THRESH) & (Yraw > 0)

    # Clean copy for stages B/C (mask A-bad positions)
    FX_a = np.where(bad, 0.0, FX)
    FY_a = np.where(bad, 0.0, FY)

    # --- B: inter-part spread among parts surviving A ---
    valid_B = ~bad & ((FX_a != 0) | (FY_a != 0))
    n_valid_B = valid_B.sum(axis=1)
    has_spread = n_valid_B >= 2

    if np.any(has_spread):
        FX_B = np.where(valid_B, FX_a, np.nan)
        FY_B = np.where(valid_B, FY_a, np.nan)
        spread = np.maximum(
            np.nanmax(FX_B, axis=1) - np.nanmin(FX_B, axis=1),
            np.nanmax(FY_B, axis=1) - np.nanmin(FY_B, axis=1))
        high_spread = has_spread & (spread > SPREAD_THRESH)

        for f in np.where(high_spread)[0]:
            v = np.where(valid_B[f])[0]
            if len(v) < 2:
                continue
            xs, ys = FX_a[f, v], FY_a[f, v]
            dists = np.sqrt((xs - xs.mean())**2 + (ys - ys.mean())**2)
            bad[f, v[np.argmax(dists)]] = True

    # --- C: centroid of surviving parts vs stable lever ---
    if not np.isnan(slx):
        valid_C = ~bad & ((FX != 0) | (FY != 0))
        FX_C = np.where(valid_C, FX, np.nan)
        FY_C = np.where(valid_C, FY, np.nan)
        has_valid = valid_C.any(axis=1)
        cx = np.where(has_valid, np.nanmean(FX_C, axis=1), np.nan)
        cy = np.where(has_valid, np.nanmean(FY_C, axis=1), np.nan)
        far = has_valid & (np.sqrt((cx - slx)**2 + (cy - sly)**2) > LEVER_DIST_THRESH)
        bad[far, :] = True

    # Apply: zero out bad entries
    for i, bp in enumerate(bp_idx):
        mask = bad[:, i]
        filtered_X[mask, bp] = 0.0
        filtered_Y[mask, bp] = 0.0

    n_bad = int(np.any(bad, axis=1).sum())
    if n_bad > 0:
        print(f'    Eye filter: {n_bad} frames corrected ({100 * n_bad / n_frames:.1f}%)')
    return filtered_X, filtered_Y


# ── Fall confidence helpers ────────────────────────────────────────────────────

def compute_fp_angle(filtered_X, filtered_Y, fi_r, pa_r, wr_r):
    """Per-frame angle (degrees) at Paw_R vertex: FingerTip_R – Paw_R – Wrist_R.
    ~180° = fingers straight (falling posture).
    <130° = fingers bent (gripping lever).
    Returns NaN where any of the three parts has zero (invalid) position.
    """
    n = filtered_X.shape[0]
    if wr_r is None:
        return np.full(n, np.nan)
    fi_x = filtered_X[:, fi_r];  fi_y = filtered_Y[:, fi_r]
    pa_x = filtered_X[:, pa_r];  pa_y = filtered_Y[:, pa_r]
    wr_x = filtered_X[:, wr_r];  wr_y = filtered_Y[:, wr_r]
    valid = (fi_x > 0) & (pa_x > 0) & (wr_x > 0)
    BA_x = fi_x - pa_x;  BA_y = fi_y - pa_y
    BC_x = wr_x - pa_x;  BC_y = wr_y - pa_y
    dot  = BA_x * BC_x + BA_y * BC_y
    norm = np.sqrt(BA_x**2 + BA_y**2) * np.sqrt(BC_x**2 + BC_y**2)
    angle = np.full(n, np.nan)
    v = valid & (norm > 1.0)
    angle[v] = np.degrees(np.arccos(np.clip(dot[v] / norm[v], -1.0, 1.0)))
    return angle


def compute_event_fall_confidence(events, distZ_filt, angle_frames):
    """Fall confidence 1–4 for each event above FALL_THR.

    Base = 1 (threshold crossed at all).
    +1  distZ < Z_SHELL_THR  →  paw actually dropped (not shell/body holding)
    +1  mean angle > ANGLE_FALL_THR  →  fingers straight (fall posture)
    +1  duration ≥ MIN_FALL_DUR_S  →  sustained event

    Score 4 = all three positive = strong fall.
    Score 1 = none satisfied = likely artifact / shell-holding.
    """
    confs = np.ones(len(events), dtype=np.int32)
    for i, ev in enumerate(events):
        s, e = ev['start'], ev['end']
        if np.mean(distZ_filt[s:e + 1]) < Z_SHELL_THR:
            confs[i] += 1
        ang = angle_frames[s:e + 1]
        ang_valid = ang[~np.isnan(ang)]
        if len(ang_valid) > 0 and np.mean(ang_valid) > ANGLE_FALL_THR:
            confs[i] += 1
        if ev['duration_s'] >= MIN_FALL_DUR_S:
            confs[i] += 1
    return confs


def compute_frame_confidence(dist_mm_filt, distZ_filt, angle_frames,
                              events, event_fall_conf):
    """Per-frame confidence arrays.

    fall_conf[f] : 0 = not in fall zone; 1–4 = fall with confidence level
    hold_conf[f] : 0 = not in hold zone; 1–3 = regular hold with confidence level
        1 = dist < HOLD_THR only
        2 = + fingers bent (angle < ANGLE_HOLD_THR)
        3 = + Z not dropped (distZ > Z_SHELL_THR, i.e. paw near lever height)
    """
    n = len(dist_mm_filt)
    fall_conf = np.zeros(n, dtype=np.int32)
    hold_conf = np.zeros(n, dtype=np.int32)

    # Fall: propagate event-level confidence to every frame in that event
    for ev, c in zip(events, event_fall_conf):
        fall_conf[ev['start']:ev['end'] + 1] = c

    # Hold: base = dist < HOLD_THR
    hold_mask = dist_mm_filt < HOLD_THR
    hold_conf[hold_mask] = 1
    # +1 if fingers bent
    ang_ok = hold_mask & ~np.isnan(angle_frames)
    hold_conf[ang_ok & (angle_frames < ANGLE_HOLD_THR)] += 1
    # +1 if paw has not dropped far below lever
    hold_conf[hold_mask & (distZ_filt > Z_SHELL_THR)] += 1

    return fall_conf, hold_conf


# ── Main processing ─────────────────────────────────────────────────────────────

def process_session(video_path, base_bp, bodyparts, force=False, calib_frame=0,
                    xy_scale_override=None):
    """Compute metrics for one session and save *_FallCount.mat.

    calib_frame : int, 0-based frame index.  Left-lever calibration means
        (used for XYscale) are computed from this frame onwards.  Set this to
        the first frame where the mirror position is correct when the mirror
        was adjusted mid-session (e.g., --calib-frame 1349 on the CLI, which
        maps to 0-based index 1348).
    xy_scale_override : float or None.  If given, bypass auto-calibration and
        use this value directly as XYscale (px/mm).  Useful when the left lever
        is undetectable even after mirror correction.
    """
    folder    = os.path.dirname(video_path)
    base_name = os.path.basename(video_path)
    mat_path  = os.path.join(folder, base_name[:-4] + '_FallCount.mat')

    if os.path.exists(mat_path) and not force:
        print(f'  Skip (exists): {base_name}')
        return

    print(f'  Processing: {base_name}')

    # ── Extract all body-part positions ──────────────────────────────────────
    n_bp = len(base_bp)
    try:
        F, X, Y, L = extract_position_allframe(video_path, base_bp[0], bodyparts)
    except Exception as e:
        print(f'    ERROR loading h5: {e}')
        return

    n_frames = len(F)
    Xall = np.zeros((n_frames, n_bp))
    Yall = np.zeros((n_frames, n_bp))
    Lall = np.zeros((n_frames, n_bp))

    for k, bp in enumerate(base_bp):
        try:
            _, Xk, Yk, Lk = extract_position_allframe(video_path, bp, bodyparts)
        except Exception as e:
            print(f'    WARNING: cannot load {bp}: {e}')
            continue
        if len(Xk) != n_frames:
            continue
        Xall[:, k] = Xk
        Yall[:, k] = Yk
        Lall[:, k] = Lk

    # Filter by likelihood ≥ 0.8
    valid = Lall >= 0.8
    filtered_X = np.where(valid, Xall, 0.0)
    filtered_Y = np.where(valid, Yall, 0.0)

    # ── Body-part indices ─────────────────────────────────────────────────────
    try:
        fi_r   = base_bp.index('FingerTip_R')
        pa_r   = base_bp.index('Paw_R')
        fi_r_mr= base_bp.index('FingerTip_R_MR')
        pa_r_mr= base_bp.index('Paw_R_MR')
        lr_wr  = base_bp.index('Lever_R_whiteroot')
        lr_wt  = base_bp.index('Lever_R_whitetip')
        lr_wr_mr=base_bp.index('Lever_R_whiteroot_MR')
        lr_wt_mr=base_bp.index('Lever_R_whitetip_MR')
        ll_wr_mr=base_bp.index('Lever_L_whiteroot_MR')
        ll_wt_mr=base_bp.index('Lever_L_whitetip_MR')
        lp     = base_bp.index('LickPort')
        lp_mr  = base_bp.index('LickPort_MR')
    except ValueError as e:
        print(f'    ERROR: missing body part {e}')
        return

    try:
        wr_r = base_bp.index('Wrist_R')
    except ValueError:
        wr_r = None

    # ── Eye artifact filter (A: Y-threshold, B: spread, C: lever distance) ──
    filtered_X, filtered_Y = filter_eye_artifacts(
        Xall, Yall, filtered_X, filtered_Y, fi_r, pa_r, wr_r, lr_wt)

    # ── Finger-Paw-Wrist angle (pixel space, front view) ─────────────────────
    angle_frames = compute_fp_angle(filtered_X, filtered_Y, fi_r, pa_r, wr_r)

    MFR_X,  MFR_Y  = calc_mean_xy(filtered_X, filtered_Y, [fi_r,   pa_r])
    MFR_MRX,MFR_MRY= calc_mean_xy(filtered_X, filtered_Y, [fi_r_mr,pa_r_mr])
    LRwr_MRX,LRwr_MRY = calc_mean_xy(filtered_X, filtered_Y, [lr_wr_mr])
    LRwt_MRX,LRwt_MRY = calc_mean_xy(filtered_X, filtered_Y, [lr_wt_mr])
    LLwr_MRX,LLwr_MRY = calc_mean_xy(filtered_X, filtered_Y, [ll_wr_mr])
    LLwt_MRX,LLwt_MRY = calc_mean_xy(filtered_X, filtered_Y, [ll_wt_mr])
    LRwr_X,  LRwr_Y  = calc_mean_xy(filtered_X, filtered_Y, [lr_wr])
    LP_X,    LP_Y    = calc_mean_xy(filtered_X, filtered_Y, [lp])
    LP_MRX,  LP_MRY  = calc_mean_xy(filtered_X, filtered_Y, [lp_mr])

    # ── Rotation to align lever axis ──────────────────────────────────────────
    p5_x  = np.percentile(LRwr_MRX[~np.isnan(LRwr_MRX)], 5)
    p5_xt = np.percentile(LRwt_MRX[~np.isnan(LRwt_MRX)], 5)
    p95_y = np.percentile(LRwr_MRY[~np.isnan(LRwr_MRY)], 95)
    p95_yt= np.percentile(LRwt_MRY[~np.isnan(LRwt_MRY)], 95)

    theta = np.arctan2(p95_yt - p95_y, p5_xt - p5_x)
    theta = np.pi / 2 - theta
    R = np.array([[np.cos(theta), -np.sin(theta)],
                  [np.sin(theta),  np.cos(theta)]])

    LRwr_MRX_r, LRwr_MRY_r = np.dot(R, [LRwr_MRX, LRwr_MRY])
    LRwt_MRX_r, LRwt_MRY_r = np.dot(R, [LRwt_MRX, LRwt_MRY])
    MFR_MRX_r,  MFR_MRY_r  = np.dot(R, [MFR_MRX,  MFR_MRY])
    # Use raw detections from calib_frame onwards so that frames with a
    # cropped / repositioned mirror do not contaminate the scale calibration.
    llwr_x, llwr_y = _lever_calib_mean(Xall, Yall, Lall, ll_wr_mr, calib_frame)
    llwt_x, llwt_y = _lever_calib_mean(Xall, Yall, Lall, ll_wt_mr, calib_frame)
    LLwr_MRX_r, LLwr_MRY_r = np.dot(R, [llwr_x, llwr_y])
    LLwt_MRX_r, LLwt_MRY_r = np.dot(R, [llwt_x, llwt_y])
    LP_MRX_r,   LP_MRY_r   = np.dot(R, [np.nanmean(LP_MRX),   np.nanmean(LP_MRY)])

    # ── Origin at LickPort ────────────────────────────────────────────────────
    MLP_X, MLP_Y = np.nanmean(LP_X), np.nanmean(LP_Y)

    LRwr_MRX_lp = LRwr_MRX_r - LP_MRX_r
    LRwr_MRY_lp = LRwr_MRY_r - LP_MRY_r
    LRwt_MRX_lp = LRwt_MRX_r - LP_MRX_r
    LRwt_MRY_lp = LRwt_MRY_r - LP_MRY_r
    LLwr_MRX_lp = LLwr_MRX_r - LP_MRX_r
    LLwt_MRX_lp = LLwt_MRX_r - LP_MRX_r
    LLwr_MRY_lp = LLwr_MRY_r - LP_MRY_r
    LLwt_MRY_lp = LLwt_MRY_r - LP_MRY_r
    MFR_MRX_lp  = MFR_MRX_r  - LP_MRX_r
    MFR_MRY_lp  = MFR_MRY_r  - LP_MRY_r
    LRwr_X_lp   = LRwr_X     - MLP_X
    LRwr_Y_lp   = LRwr_Y     - MLP_Y
    MFR_Y_lp    = MFR_Y      - MLP_Y
    MFR_X_lp    = MFR_X      - MLP_X

    # ── Scale to mm ───────────────────────────────────────────────────────────
    # Use 5th-percentile instead of nanmin so that a single outlier frame
    # (near-zero inter-lever separation) cannot blow up XYscale.
    _XY_SCALE_MIN, _XY_SCALE_MAX = 0.04, 0.25   # plausible range (px/mm) for this rig
    inter_lever_gap = np.nanpercentile(LLwt_MRY_lp - LRwt_MRY_lp, 5)
    XYscale_auto    = 6.0 / inter_lever_gap      # Lever_tip to Lever_tip = 6 mm
    Zscale  = 12.5 / np.abs(np.nanmean(LRwr_Y) - MLP_Y)   # LickPort to Lever = 12.5 mm

    if xy_scale_override is not None:
        XYscale = float(xy_scale_override)
        print(f'    XYscale overridden: {XYscale:.4f} px/mm  '
              f'(auto would have been {XYscale_auto:.4f}, gap={inter_lever_gap:.1f} px)')
    elif not (_XY_SCALE_MIN < XYscale_auto < _XY_SCALE_MAX):
        print(f'    WARNING: auto XYscale={XYscale_auto:.4f} outside plausible range '
              f'[{_XY_SCALE_MIN}, {_XY_SCALE_MAX}] (inter-lever gap={inter_lever_gap:.1f} px). '
              f'Left lever may be undetected.  Use --xy-scale to override.')
        XYscale = XYscale_auto   # keep going — results will be wrong but saves the file
    else:
        XYscale = XYscale_auto
        if calib_frame > 0:
            print(f'    calib_frame={calib_frame}: XYscale={XYscale:.4f} px/mm  '
                  f'(inter-lever gap={inter_lever_gap:.1f} px)')

    LRwr_MRX_mm = LRwr_MRX_lp * XYscale
    LRwr_MRY_mm = LRwr_MRY_lp * XYscale
    LRwt_MRX_mm = LRwt_MRX_lp * XYscale
    LRwt_MRY_mm = LRwt_MRY_lp * XYscale
    MFR_MRX_mm  = MFR_MRX_lp  * XYscale
    MFR_MRY_mm  = MFR_MRY_lp  * XYscale
    LRwr_Y_mm   = LRwr_Y_lp   * Zscale
    MFR_Y_mm    = MFR_Y_lp    * Zscale
    MFR_X_mm    = MFR_X_lp    * Zscale

    # Individual finger / paw mm coords (mirror view, rotated) for spread recovery
    FI_MRX_raw, FI_MRY_raw = calc_mean_xy(filtered_X, filtered_Y, [fi_r_mr])
    PA_MRX_raw, PA_MRY_raw = calc_mean_xy(filtered_X, filtered_Y, [pa_r_mr])
    FI_MRX_r, FI_MRY_r = np.dot(R, [FI_MRX_raw, FI_MRY_raw])
    PA_MRX_r, PA_MRY_r = np.dot(R, [PA_MRX_raw, PA_MRY_raw])
    FI_MRX_mm = (FI_MRX_r - LP_MRX_r) * XYscale
    FI_MRY_mm = (FI_MRY_r - LP_MRY_r) * XYscale
    PA_MRX_mm = (PA_MRX_r - LP_MRX_r) * XYscale
    PA_MRY_mm = (PA_MRY_r - LP_MRY_r) * XYscale

    # ── Remove lever-detection outliers ───────────────────────────────────────
    # NaN-out frames where lever wrist is above p99 (misdetection) so that
    # shortest_distance() returns NaN for those frames and interpolate_nan()
    # fills them in rather than propagating a spike into dist_mm.
    p99_wr = np.percentile(LRwr_MRY_mm, 99)
    keep   = LRwr_MRY_mm < p99_wr
    LRwr_MRX_mm[~keep] = np.nan
    LRwr_MRY_mm[~keep] = np.nan
    LRwt_MRX_mm[~keep] = np.nan
    LRwt_MRY_mm[~keep] = np.nan
    # No-pull mask: lever barely moved
    no_pull_mask = LRwr_MRX_mm < (np.nanmin(LRwr_MRX_mm) + NO_PULL_THR)

    # ── 3D distance: XY (perpendicular to lever) + Z ─────────────────────────
    n = len(LRwr_MRX_mm)
    distXY = np.zeros(n)
    distZ  = np.zeros(n)
    for idx in range(n):
        A = [LRwr_MRX_mm[idx], LRwr_MRY_mm[idx]]
        B = [LRwt_MRX_mm[idx], LRwt_MRY_mm[idx]]
        C = [MFR_MRX_mm[idx],  MFR_MRY_mm[idx]]
        distXY[idx] = shortest_distance(A, B, C)
        lever_Z      = np.mean([LRwt_MRY_mm[idx], LRwr_MRY_mm[idx]])  # reuse Y_mm for Z plane
        # Z from separate side-view channel
        lever_Zval   = np.mean([LRwr_Y_mm[idx]])
        distZ[idx]   = lever_Zval - MFR_Y_mm[idx]

    # ── Physiological plausibility filters ───────────────────────────────────
    # 1. Forelimb > MAX_XY_DIST_MM from lever → hindlimb misdetection in bottom view
    distXY[distXY > MAX_XY_DIST_MM] = np.nan

    # 2. Finger–paw spread > MAX_FI_PA_SPREAD_MM → one part is hindlimb.
    #    Instead of discarding the frame, recompute distXY using only the part
    #    closer to the lever axis (the true forelimb contact point).
    fi_x_mm = filtered_X[:, fi_r] * XYscale
    pa_x_mm = filtered_X[:, pa_r] * XYscale
    fi_y_mm = filtered_Y[:, fi_r] * XYscale
    pa_y_mm = filtered_Y[:, pa_r] * XYscale
    fi_pa_spread = np.sqrt((fi_x_mm - pa_x_mm)**2 + (fi_y_mm - pa_y_mm)**2)
    spread_bad = fi_pa_spread > MAX_FI_PA_SPREAD_MM
    n_spread = int(np.sum(spread_bad))
    if n_spread > 0:
        print(f'    Spread filter: {n_spread} frames recomputed ({100*n_spread/n:.1f}%)')
        for ii in np.where(spread_bad)[0]:
            A = [LRwr_MRX_mm[ii], LRwr_MRY_mm[ii]]
            B = [LRwt_MRX_mm[ii], LRwt_MRY_mm[ii]]
            if np.isnan(A[0]) or np.isnan(B[0]):
                continue  # lever also NaN — leave distXY as-is
            d_fi = shortest_distance(A, B, [FI_MRX_mm[ii], FI_MRY_mm[ii]])
            d_pa = shortest_distance(A, B, [PA_MRX_mm[ii], PA_MRY_mm[ii]])
            distXY[ii] = min(d_fi, d_pa)

    distXY = interpolate_nan(distXY)   # fill NaN from lever-outlier and spread frames
    dist_mm = np.sqrt(distXY**2 + distZ**2)
    dist_mm = interpolate_nan(dist_mm)
    dist_mm_filt = lowpass_filter(dist_mm, LP_CUTOFF, FS)

    distZ = interpolate_nan(distZ)
    distZ_filt = lowpass_filter(distZ, LP_CUTOFF_Z, FS)

    # ── Metrics ───────────────────────────────────────────────────────────────
    t_axis = np.arange(n) / FS / 60.0   # minutes
    total_min = t_axis[-1]

    fall_time_min  = np.sum(dist_mm_filt > FALL_THR)  / FS / 60.0
    hold_time_min  = np.sum(dist_mm_filt < HOLD_THR)  / FS / 60.0

    cross_count = 0
    for idx in range(n - 1):
        if dist_mm_filt[idx] < FALL_THR and dist_mm_filt[idx+1] > FALL_THR:
            cross_count += 1

    FallTime_10min        = fall_time_min  / total_min * 10.0
    RegularHoldTime_10min = hold_time_min  / total_min * 10.0
    CrossCount_10min      = cross_count    / total_min * 10.0

    # ── Event-level analysis ──────────────────────────────────────────────────
    events   = find_threshold_events(dist_mm_filt, FALL_THR)
    n_events = len(events)

    if n_events > 0:
        feats      = extract_event_features(events, dist_mm_filt, distZ_filt, distXY)
        labels_dv  = classify_duration_zdv(feats)
        labels_gmm, pca_coords, pca_var = classify_pca_gmm(feats)
    else:
        feats      = []
        labels_dv  = np.zeros(0, dtype=np.int32)
        labels_gmm = np.zeros(0, dtype=np.int32)
        pca_coords = np.zeros((0, 2))
        pca_var    = np.zeros(2)

    # Duration + Z-velocity metrics
    fall_mask_dv = np.zeros(n, dtype=bool)
    for ev, lbl in zip(events, labels_dv):
        if lbl == 1:
            fall_mask_dv[ev['start']:ev['end'] + 1] = True
    FallTime_10min_dv   = np.sum(fall_mask_dv) / FS / 60.0 / total_min * 10.0
    CrossCount_10min_dv = float(np.sum(labels_dv)) / total_min * 10.0

    # GMM metrics
    fall_mask_gmm = np.zeros(n, dtype=bool)
    for ev, lbl in zip(events, labels_gmm):
        if lbl == 1:
            fall_mask_gmm[ev['start']:ev['end'] + 1] = True
    FallTime_10min_gmm   = np.sum(fall_mask_gmm) / FS / 60.0 / total_min * 10.0
    CrossCount_10min_gmm = float(np.sum(labels_gmm)) / total_min * 10.0

    # ── Confidence-based metrics ──────────────────────────────────────────────
    event_fall_conf = compute_event_fall_confidence(events, distZ_filt, angle_frames)
    fall_conf_frames, hold_conf_frames = compute_frame_confidence(
        dist_mm_filt, distZ_filt, angle_frames, events, event_fall_conf)

    # FallTime and CrossCount at each minimum confidence level (1–4)
    ft_conf  = np.zeros(4);  cc_conf  = np.zeros(4)
    for min_c in range(1, 5):
        ft_conf[min_c-1]  = np.sum(fall_conf_frames >= min_c) / FS / 60.0 / total_min * 10.0
        cc_conf[min_c-1]  = float(np.sum(event_fall_conf >= min_c))        / total_min * 10.0

    # RegularHoldTime at each minimum confidence level (1–3)
    rht_conf = np.zeros(3)
    for min_c in range(1, 4):
        rht_conf[min_c-1] = np.sum(hold_conf_frames >= min_c) / FS / 60.0 / total_min * 10.0

    # ── Left Forelimb Analysis ────────────────────────────────────────────────
    left_metrics_dict = {}
    try:
        fi_l    = base_bp.index('FingerTip_L')
        pa_l    = base_bp.index('Paw_L')
        fi_l_mr = base_bp.index('FingerTip_L_MR')
        pa_l_mr = base_bp.index('Paw_L_MR')
        has_left = True
    except ValueError:
        has_left = False

    if has_left:
        try:
            try:
                wr_l = base_bp.index('Wrist_L')
            except ValueError:
                wr_l = None

            try:
                ll_wr_fr = base_bp.index('Lever_L_whiteroot')
            except ValueError:
                ll_wr_fr = None

            # Eye artifact filter on a copy (left body parts, front-view lever as reference).
            # Must use a front-view lever reference so that stage C (lever-distance check)
            # compares front-view forelimb positions to a front-view lever position.
            # ll_wt_mr (mirror-view) would always be > LEVER_DIST_THRESH pixels away from
            # front-view body parts, zeroing every frame incorrectly.
            lev_ref_L = ll_wr_fr if ll_wr_fr is not None else lr_wt  # both front-view
            filtered_X_L = filtered_X.copy()
            filtered_Y_L = filtered_Y.copy()
            filtered_X_L, filtered_Y_L = filter_eye_artifacts(
                Xall, Yall, filtered_X_L, filtered_Y_L, fi_l, pa_l, wr_l, lev_ref_L)

            # Finger-Paw-Wrist angle (left)
            angle_frames_L = compute_fp_angle(filtered_X_L, filtered_Y_L, fi_l, pa_l, wr_l)

            # Mean positions — mirror view (for XY distance)
            MFL_MRX, MFL_MRY       = calc_mean_xy(filtered_X_L, filtered_Y_L, [fi_l_mr, pa_l_mr])
            # Mean positions — front view (for Z distance)
            MFL_X, MFL_Y           = calc_mean_xy(filtered_X_L, filtered_Y_L, [fi_l, pa_l])
            if ll_wr_fr is not None:
                LLwr_Y_fr, _       = calc_mean_xy(filtered_X_L, filtered_Y_L, [ll_wr_fr])
            else:
                LLwr_Y_fr          = None

            # Left lever time series in mirror view (reuse already-extracted arrays)
            # LLwr_MRX, LLwr_MRY and LLwt_MRX, LLwt_MRY are time series from lines above

            # Rotate (same R derived from right lever — both sides share coordinate system)
            MFL_MRX_r, MFL_MRY_r         = np.dot(R, [MFL_MRX, MFL_MRY])
            LLwr_MRX_r_ts, LLwr_MRY_r_ts = np.dot(R, [LLwr_MRX, LLwr_MRY])
            LLwt_MRX_r_ts, LLwt_MRY_r_ts = np.dot(R, [LLwt_MRX, LLwt_MRY])

            # Origin at LickPort
            MFL_MRX_lp     = MFL_MRX_r     - LP_MRX_r
            MFL_MRY_lp     = MFL_MRY_r     - LP_MRY_r
            LLwr_MRX_lp_ts = LLwr_MRX_r_ts - LP_MRX_r
            LLwr_MRY_lp_ts = LLwr_MRY_r_ts - LP_MRY_r
            LLwt_MRX_lp_ts = LLwt_MRX_r_ts - LP_MRX_r
            LLwt_MRY_lp_ts = LLwt_MRY_r_ts - LP_MRY_r

            # Scale to mm (same XYscale and Zscale as right side)
            MFL_MRX_mm     = MFL_MRX_lp     * XYscale
            MFL_MRY_mm     = MFL_MRY_lp     * XYscale
            LLwr_MRX_mm_ts = LLwr_MRX_lp_ts * XYscale
            LLwr_MRY_mm_ts = LLwr_MRY_lp_ts * XYscale
            LLwt_MRX_mm_ts = LLwt_MRX_lp_ts * XYscale
            LLwt_MRY_mm_ts = LLwt_MRY_lp_ts * XYscale

            # NaN-out left-lever time series before calib_frame: carry-forward
            # values from the cropped-mirror period are invalid.  interpolate_nan
            # (called later) will backfill from the first valid frame onwards.
            if calib_frame > 0:
                LLwr_MRX_mm_ts[:calib_frame] = np.nan
                LLwr_MRY_mm_ts[:calib_frame] = np.nan
                LLwt_MRX_mm_ts[:calib_frame] = np.nan
                LLwt_MRY_mm_ts[:calib_frame] = np.nan

            # NaN-mask undetected front-view left forelimb frames (filtered pos = 0 → top of frame)
            MFL_Y_z  = MFL_Y.copy().astype(float)
            fl_det   = (filtered_Y_L[:, fi_l] != 0) | (filtered_Y_L[:, pa_l] != 0)
            if fl_det.any():
                MFL_Y_z[~fl_det] = np.nan
                MFL_Y_z = interpolate_nan(MFL_Y_z)
            else:
                MFL_Y_z[:] = MLP_Y  # fully undetected: set to lickport height → distZ_L ≈ 0
            MFL_Y_mm = (MFL_Y_z - MLP_Y) * Zscale

            if LLwr_Y_fr is not None:
                LLwr_Y_fr_z  = LLwr_Y_fr.copy().astype(float)
                ll_det        = (filtered_Y_L[:, ll_wr_fr] != 0)
                if ll_det.any():
                    LLwr_Y_fr_z[~ll_det] = np.nan
                    LLwr_Y_fr_z = interpolate_nan(LLwr_Y_fr_z)
                else:
                    LLwr_Y_fr_z[:] = MLP_Y  # fully undetected: distZ_L ≈ 0
                LLwr_Y_mm_fr = (LLwr_Y_fr_z - MLP_Y) * Zscale
            else:
                LLwr_Y_mm_fr = LRwr_Y_mm.copy()  # fallback: assume same lever height

            # Remove left-lever outlier frames
            p99_ll = np.percentile(LLwr_MRY_mm_ts[~np.isnan(LLwr_MRY_mm_ts)], 99) if np.any(~np.isnan(LLwr_MRY_mm_ts)) else np.inf
            keep_L = LLwr_MRY_mm_ts < p99_ll
            LLwr_MRX_mm_ts[~keep_L] = np.nan
            LLwr_MRY_mm_ts[~keep_L] = np.nan
            LLwt_MRX_mm_ts[~keep_L] = np.nan
            LLwt_MRY_mm_ts[~keep_L] = np.nan

            # Individual finger/paw for spread recovery
            FI_L_MRX_raw, FI_L_MRY_raw = calc_mean_xy(filtered_X_L, filtered_Y_L, [fi_l_mr])
            PA_L_MRX_raw, PA_L_MRY_raw = calc_mean_xy(filtered_X_L, filtered_Y_L, [pa_l_mr])
            FI_L_MRX_r, FI_L_MRY_r     = np.dot(R, [FI_L_MRX_raw, FI_L_MRY_raw])
            PA_L_MRX_r, PA_L_MRY_r     = np.dot(R, [PA_L_MRX_raw, PA_L_MRY_raw])
            FI_L_MRX_mm = (FI_L_MRX_r - LP_MRX_r) * XYscale
            FI_L_MRY_mm = (FI_L_MRY_r - LP_MRY_r) * XYscale
            PA_L_MRX_mm = (PA_L_MRX_r - LP_MRX_r) * XYscale
            PA_L_MRY_mm = (PA_L_MRY_r - LP_MRY_r) * XYscale

            # XY distance to left lever axis
            distXY_L = np.zeros(n)
            distZ_L  = np.zeros(n)
            for ii in range(n):
                A = [LLwr_MRX_mm_ts[ii], LLwr_MRY_mm_ts[ii]]
                B = [LLwt_MRX_mm_ts[ii], LLwt_MRY_mm_ts[ii]]
                C = [MFL_MRX_mm[ii],     MFL_MRY_mm[ii]]
                distXY_L[ii] = shortest_distance(A, B, C)
                distZ_L[ii]  = LLwr_Y_mm_fr[ii] - MFL_Y_mm[ii]

            # Physiological plausibility
            distXY_L[distXY_L > MAX_XY_DIST_MM] = np.nan

            # Finger-paw spread filter
            fi_x_mm_L    = filtered_X_L[:, fi_l] * XYscale
            pa_x_mm_L    = filtered_X_L[:, pa_l] * XYscale
            fi_y_mm_L    = filtered_Y_L[:, fi_l] * XYscale
            pa_y_mm_L    = filtered_Y_L[:, pa_l] * XYscale
            fi_pa_spr_L  = np.sqrt((fi_x_mm_L - pa_x_mm_L)**2 + (fi_y_mm_L - pa_y_mm_L)**2)
            spread_bad_L = fi_pa_spr_L > MAX_FI_PA_SPREAD_MM
            n_spread_L   = int(np.sum(spread_bad_L))
            if n_spread_L > 0:
                print(f'    Spread filter (L): {n_spread_L} frames recomputed ({100*n_spread_L/n:.1f}%)')
                for ii in np.where(spread_bad_L)[0]:
                    A = [LLwr_MRX_mm_ts[ii], LLwr_MRY_mm_ts[ii]]
                    B = [LLwt_MRX_mm_ts[ii], LLwt_MRY_mm_ts[ii]]
                    if np.isnan(A[0]) or np.isnan(B[0]):
                        continue
                    d_fi = shortest_distance(A, B, [FI_L_MRX_mm[ii], FI_L_MRY_mm[ii]])
                    d_pa = shortest_distance(A, B, [PA_L_MRX_mm[ii], PA_L_MRY_mm[ii]])
                    distXY_L[ii] = min(d_fi, d_pa)

            distXY_L      = interpolate_nan(distXY_L)
            dist_mm_L     = np.sqrt(distXY_L**2 + distZ_L**2)
            dist_mm_L     = interpolate_nan(dist_mm_L)
            dist_mm_filt_L = lowpass_filter(dist_mm_L, LP_CUTOFF, FS)
            distZ_L       = interpolate_nan(distZ_L)
            distZ_filt_L  = lowpass_filter(distZ_L, LP_CUTOFF_Z, FS)

            # Scalar metrics
            fall_time_min_L  = np.sum(dist_mm_filt_L > FALL_THR) / FS / 60.0
            hold_time_min_L  = np.sum(dist_mm_filt_L < HOLD_THR) / FS / 60.0
            cross_count_L    = int(np.sum((dist_mm_filt_L[:-1] < FALL_THR) & (dist_mm_filt_L[1:] > FALL_THR)))
            FallTime_10min_L        = fall_time_min_L  / total_min * 10.0
            RegularHoldTime_10min_L = hold_time_min_L  / total_min * 10.0
            CrossCount_10min_L      = cross_count_L    / total_min * 10.0

            # Event analysis
            events_L   = find_threshold_events(dist_mm_filt_L, FALL_THR)
            n_events_L = len(events_L)
            if n_events_L > 0:
                feats_L      = extract_event_features(events_L, dist_mm_filt_L, distZ_filt_L, distXY_L)
                labels_dv_L  = classify_duration_zdv(feats_L)
                labels_gmm_L, pca_coords_L, _ = classify_pca_gmm(feats_L)
            else:
                feats_L      = []
                labels_dv_L  = np.zeros(0, dtype=np.int32)
                labels_gmm_L = np.zeros(0, dtype=np.int32)
                pca_coords_L = np.zeros((0, 2))

            fall_mask_dv_L  = np.zeros(n, dtype=bool)
            fall_mask_gmm_L = np.zeros(n, dtype=bool)
            for ev, ld, lg in zip(events_L, labels_dv_L, labels_gmm_L):
                if ld == 1: fall_mask_dv_L[ev['start']:ev['end'] + 1]  = True
                if lg == 1: fall_mask_gmm_L[ev['start']:ev['end'] + 1] = True
            FallTime_10min_dv_L   = np.sum(fall_mask_dv_L)  / FS / 60.0 / total_min * 10.0
            CrossCount_10min_dv_L = float(np.sum(labels_dv_L))  / total_min * 10.0
            FallTime_10min_gmm_L  = np.sum(fall_mask_gmm_L) / FS / 60.0 / total_min * 10.0
            CrossCount_10min_gmm_L = float(np.sum(labels_gmm_L)) / total_min * 10.0

            # Confidence
            ev_conf_L = compute_event_fall_confidence(events_L, distZ_filt_L, angle_frames_L)
            fall_conf_L, hold_conf_L = compute_frame_confidence(
                dist_mm_filt_L, distZ_filt_L, angle_frames_L, events_L, ev_conf_L)

            ft_conf_L  = np.zeros(4); cc_conf_L  = np.zeros(4)
            for min_c in range(1, 5):
                ft_conf_L[min_c-1]  = np.sum(fall_conf_L >= min_c) / FS / 60.0 / total_min * 10.0
                cc_conf_L[min_c-1]  = float(np.sum(ev_conf_L >= min_c)) / total_min * 10.0
            rht_conf_L = np.zeros(3)
            for min_c in range(1, 4):
                rht_conf_L[min_c-1] = np.sum(hold_conf_L >= min_c) / FS / 60.0 / total_min * 10.0

            ev_feat_arr_L = (np.array([[f['duration_s'], f['max_dist'], f['z_at_peak'],
                                        f['xy_at_peak'], f['z_xy_ratio'], f['zdot_onset'],
                                        f['mean_z']] for f in feats_L])
                             if n_events_L > 0 else np.zeros((0, 7)))

            left_metrics_dict = {
                'distance_mm_filtered_L':    dist_mm_filt_L,
                'distance_mm_L':             dist_mm_L,
                'distanceZ_mm_L':            distZ_L,
                'distanceZ_mm_filtered_L':   distZ_filt_L,
                'distanceXY_mm_L':           distXY_L,
                'angle_frames_L':            angle_frames_L,
                'FallTime_10min_L':          FallTime_10min_L,
                'RegularHoldTime_10min_L':   RegularHoldTime_10min_L,
                'CrossCount_10min_L':        CrossCount_10min_L,
                'FallTime_10min_dv_L':       FallTime_10min_dv_L,
                'CrossCount_10min_dv_L':     CrossCount_10min_dv_L,
                'FallTime_10min_gmm_L':      FallTime_10min_gmm_L,
                'CrossCount_10min_gmm_L':    CrossCount_10min_gmm_L,
                'event_features_L':          ev_feat_arr_L,
                'event_labels_dv_L':         labels_dv_L,
                'event_labels_gmm_L':        labels_gmm_L,
                'event_start_frame_L':       np.array([ev['start'] for ev in events_L], dtype=np.int32),
                'event_duration_frames_L':   np.array([ev['duration_frames'] for ev in events_L], dtype=np.int32),
                'event_confidence_L':        ev_conf_L,
                'fall_confidence_frames_L':  fall_conf_L,
                'hold_confidence_frames_L':  hold_conf_L,
                'FallTime_10min_conf_L':     ft_conf_L,
                'CrossCount_10min_conf_L':   cc_conf_L,
                'RegHoldTime_10min_conf_L':  rht_conf_L,
            }
            print(f'    Left forelimb: FT={FallTime_10min_L:.2f}  FT_dv={FallTime_10min_dv_L:.2f}'
                  f'  FT_gmm={FallTime_10min_gmm_L:.2f}  Hold={RegularHoldTime_10min_L:.2f}'
                  f'  CC={CrossCount_10min_L:.2f}')
        except Exception as e_left:
            print(f'    WARNING: left forelimb analysis failed: {e_left}')

    # ── Save figures ──────────────────────────────────────────────────────────
    # Figure 1: distance trace (unchanged)
    fig, ax = plt.subplots()
    ax.plot(t_axis, dist_mm_filt)
    ax.axhline(FALL_THR, color='r', linestyle='--', label=f'{FALL_THR} mm (fall)')
    ax.axhline(HOLD_THR, color='y', linestyle='--', label=f'{HOLD_THR} mm (hold)')
    ax.set_xlabel('Time (min)'); ax.set_ylabel('Distance (mm)')
    ax.set_xlim(0, t_axis[-1]); ax.set_ylim(0, 30)
    ax.legend()
    plt.tight_layout()
    plt.savefig(os.path.join(folder, base_name[:-4] + '_distance.pdf'))
    plt.close(fig)

    # Figure 2: event classification (duration+Z-vel top, PCA/GMM bottom)
    fig2, (ax_tr, ax_pc) = plt.subplots(2, 1, figsize=(12, 7))

    ax_tr.plot(t_axis, dist_mm_filt, color='k', linewidth=0.5, alpha=0.6)
    for ev, lbl in zip(events, labels_dv):
        col = 'red' if lbl == 1 else 'limegreen'
        ax_tr.axvspan(t_axis[ev['start']], t_axis[ev['end']], alpha=0.35, color=col, linewidth=0)
    ax_tr.axhline(FALL_THR, color='r', linestyle='--', linewidth=1)
    ax_tr.axhline(HOLD_THR, color='goldenrod', linestyle='--', linewidth=1)
    ax_tr.set_xlim(0, t_axis[-1])
    ax_tr.set_ylabel('Distance (mm)')
    ax_tr.set_title(
        f'Duration+Z-vel  (red=fall, green=release)  '
        f'FallTime={FallTime_10min_dv:.2f}  Cross={CrossCount_10min_dv:.2f}  '
        f'[original: FT={FallTime_10min:.2f}  CC={CrossCount_10min:.2f}]',
        fontsize=8)

    if n_events >= 2:
        for lbl, col, name in [(0, 'limegreen', 'release'), (1, 'red', 'fall')]:
            mask = labels_gmm == lbl
            if np.any(mask):
                ax_pc.scatter(pca_coords[mask, 0], pca_coords[mask, 1],
                              c=col, label=f'GMM {name} (n={np.sum(mask)})',
                              alpha=0.75, s=40, edgecolors='k', linewidths=0.3)
        ax_pc.set_xlabel(f'PC1 ({pca_var[0]*100:.1f}% var)')
        ax_pc.set_ylabel(f'PC2 ({pca_var[1]*100:.1f}% var)')
        ax_pc.set_title(
            f'PCA/GMM  FallTime={FallTime_10min_gmm:.2f}  Cross={CrossCount_10min_gmm:.2f}',
            fontsize=8)
        ax_pc.legend(fontsize=8)
    else:
        ax_pc.text(0.5, 0.5, f'n_events={n_events} — too few for PCA/GMM',
                   ha='center', va='center', transform=ax_pc.transAxes, fontsize=10)

    plt.tight_layout()
    plt.savefig(os.path.join(folder, base_name[:-4] + '_events.pdf'))
    plt.close(fig2)

    # ── Save .mat ─────────────────────────────────────────────────────────────
    FDL = np.array([FallTime_10min, RegularHoldTime_10min, CrossCount_10min])
    release_flag = np.zeros(n)
    release_flag[distZ_filt > 2] = 2

    ev_feat_arr = (np.array([[f['duration_s'], f['max_dist'], f['z_at_peak'],
                               f['xy_at_peak'], f['z_xy_ratio'], f['zdot_onset'],
                               f['mean_z']] for f in feats])
                   if n_events > 0 else np.zeros((0, 7)))

    save_dict = {
        'List':                     FDL,
        'String':                   ['FallTime_10min', 'RegularHoldTime_10min', 'CrossCount_10min'],
        'distance_mm_filtered':     dist_mm_filt,
        'distance_mm':              dist_mm,
        'distanceZ_mm':             distZ,
        'distanceZ_mm_filtered':    distZ_filt,
        'distanceXY_mm':            distXY,
        'ReleaseFlag':              release_flag,
        # Duration + Z-velocity classification
        'FallTime_10min_dv':        FallTime_10min_dv,
        'CrossCount_10min_dv':      CrossCount_10min_dv,
        # PCA/GMM classification
        'FallTime_10min_gmm':       FallTime_10min_gmm,
        'CrossCount_10min_gmm':     CrossCount_10min_gmm,
        # Per-event data (rows = events)
        'event_features':           ev_feat_arr,   # n×7: [dur_s, max_d, z_pk, xy_pk, z_xy, zdot, mean_z]
        'event_labels_dv':          labels_dv,
        'event_labels_gmm':         labels_gmm,
        'event_pca':                pca_coords,
        'event_start_frame':        np.array([ev['start'] for ev in events], dtype=np.int32),
        'event_duration_frames':    np.array([ev['duration_frames'] for ev in events], dtype=np.int32),
        # Confidence-based classification
        # fall_confidence_frames: 0=not fall, 1(weak)–4(strong) per frame
        # hold_confidence_frames: 0=not hold, 1(weak)–3(strong) per frame
        # Confidence criteria:
        #   Fall +1: distZ < Z_SHELL_THR (paw dropped, not shell/body holding)
        #        +1: mean finger-paw-wrist angle > ANGLE_FALL_THR (fingers straight)
        #        +1: duration >= MIN_FALL_DUR_S (sustained)
        #   Hold +1: angle < ANGLE_HOLD_THR (fingers bent = gripping)
        #        +1: distZ > Z_SHELL_THR (paw near lever height)
        'angle_frames':             angle_frames,
        'event_confidence':         event_fall_conf,
        'fall_confidence_frames':   fall_conf_frames,
        'hold_confidence_frames':   hold_conf_frames,
        # FallTime/CrossCount/RegHoldTime at each minimum confidence level
        # index 0=c≥1, 1=c≥2, 2=c≥3, 3=c≥4
        'FallTime_10min_conf':      ft_conf,
        'CrossCount_10min_conf':    cc_conf,
        'RegHoldTime_10min_conf':   rht_conf,
    }
    save_dict.update(left_metrics_dict)
    scipy.io.savemat(mat_path, save_dict)
    np.save(mat_path[:-4] + '_dict', save_dict)
    np.save(mat_path[:-4], FDL)

    print(f'    Saved: {os.path.basename(mat_path)}  '
          f'FT={FallTime_10min:.2f}  FT_dv={FallTime_10min_dv:.2f}  FT_gmm={FallTime_10min_gmm:.2f}  '
          f'Hold={RegularHoldTime_10min:.2f}  '
          f'CC={CrossCount_10min:.2f}  CC_dv={CrossCount_10min_dv:.2f}  CC_gmm={CrossCount_10min_gmm:.2f}')


def main():
    import argparse
    parser = argparse.ArgumentParser(description='Generate *_FallCount.mat for lever-pull sessions.')
    parser.add_argument('animal_folders', nargs='+', help='Animal folder path(s) or glob patterns')
    parser.add_argument('--force', action='store_true', help='Overwrite existing *_FallCount.mat files')
    parser.add_argument('--calib-frame', type=int, default=1, metavar='N',
                        help='1-based frame number from which the left-lever mirror position is '
                             'correct.  Use when the mirror was repositioned mid-session so that '
                             'XYscale is calibrated from valid frames only (default: 1 = full '
                             'session).  Example: --calib-frame 1349')
    parser.add_argument('--xy-scale', type=float, default=None, metavar='S',
                        help='Override the auto-calibrated XYscale (px/mm).  Use when the left '
                             'lever is undetectable in the mirror view (e.g., still cropped after '
                             'mirror correction).  Typical value for this rig: ~0.091.  '
                             'Example: --xy-scale 0.091')
    args = parser.parse_args()

    # Expand glob patterns and fix UNC paths; collect folders and individual mp4s
    animal_folders = []
    direct_mp4s    = []
    for p in args.animal_folders:
        if p.startswith('\\') and not p.startswith('\\\\'):
            p = '\\' + p
        matched = glob.glob(p)
        if matched:
            for m in matched:
                if os.path.isdir(m):
                    animal_folders.append(m)
                elif m.lower().endswith('.mp4'):
                    direct_mp4s.append(m)
        elif os.path.isdir(p):
            animal_folders.append(p)
        elif os.path.isfile(p) and p.lower().endswith('.mp4'):
            direct_mp4s.append(p)
        else:
            print(f'WARNING: no folder or mp4 matched: {p}')

    if not animal_folders and not direct_mp4s:
        print('ERROR: no valid animal folders or mp4 files found.')
        sys.exit(1)

    # Load body parts from DLC config
    if not os.path.exists(CONFIG_PATH):
        print(f'ERROR: DLC config not found: {CONFIG_PATH}')
        sys.exit(1)
    base_bp, bodyparts = load_bodyparts(CONFIG_PATH)

    calib_frame = max(0, args.calib_frame - 1)   # convert 1-based CLI arg to 0-based index

    # Process individual mp4s specified directly
    for vid in sorted(direct_mp4s):
        print(f'\nDirect file: {vid}')
        try:
            process_session(vid, base_bp, bodyparts, force=args.force,
                            calib_frame=calib_frame,
                            xy_scale_override=args.xy_scale)
        except Exception as e:
            print(f'    ERROR (skipped): {os.path.basename(vid)}: {e}')

    # Process all sessions found in animal folders
    for animal_folder in sorted(animal_folders):
        print(f'\nAnimal folder: {animal_folder}')
        session_mp4s = find_session_mp4s(animal_folder)
        if not session_mp4s:
            print('  No session mp4 files found.')
            continue
        print(f'  Found {len(session_mp4s)} session(s).')
        for vid in session_mp4s:
            try:
                process_session(vid, base_bp, bodyparts, force=args.force,
                                calib_frame=calib_frame,
                                xy_scale_override=args.xy_scale)
            except Exception as e:
                print(f'    ERROR (skipped): {os.path.basename(vid)}: {e}')


if __name__ == '__main__':
    main()
