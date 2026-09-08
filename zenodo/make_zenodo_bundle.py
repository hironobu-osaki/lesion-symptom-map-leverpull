#!/usr/bin/env python3
"""make_zenodo_bundle.py — collect the processed data for the Zenodo record.

Gathers, for every animal listed in NOIO_summary_YYYYMMDD.xlsx:
  histology/slice_*.png                     DAPI coronal sections (input to AP_histology)
  histology/CCF/{histology_ccf, atlas2histology_tform, lesion_ccf, LesionMapAllenCCF}.mat
                                            lesion registered to Allen CCFv3
  behavior/*_FallCount.mat                  per-session forelimb metrics (output of GenerateFallCount.py)
  behavior/*_corrections.mat                manual curation applied to the session by the analysis script
  behavior/lvm/*.lvm.gz                     LabVIEW lever / reward / camera-trigger record (gzip of the raw file);
                                            omitted with --no-lvm (the 2026 submission record excludes them)
plus the two FallCount_customCategories.mat files, the summary spreadsheet, a
manifest.csv and SHA-256 checksums. The layout mirrors what
LeverPullTask_InfVsSham.m expects once local_paths.m points at the bundle.

Rules (decided for the 2026 Neuroscience Research submission):
  * only Movie/Iwai is used for FallCount.mat; files in sub-folders
    (e.g. "新しいフォルダー", "POD31,35") are ignored — top level only.
  * animals without a histology folder are sham; SHAM_OVERRIDE lists sham
    animals whose spreadsheet row carries a lesion label.
  * animal IDs may be zero-padded on disk (IO8 -> IO08); both spellings are tried.
  * the run is resumable: existing files with matching size are skipped.

Usage:
  python3 make_zenodo_bundle.py [--share /Volumes/DataTransferForAllUsers_1day]
                                [--out ~/ZenodoUpload/lesion-symptom-map-leverpull-data]
                                [--dry-run]
"""
import argparse, csv, glob, gzip, hashlib, os, re, shutil, sys, time

CCF_KEEP = ("histology_ccf.mat", "atlas2histology_tform.mat", "lesion_ccf.mat", "LesionMapAllenCCF.mat")
SHAM_OVERRIDE = {"IO22", "IO41"}          # sham animals (no lesion mapping) despite a spreadsheet label
SKIP_DIR_TOKENS = ("新しいフォルダー",)     # duplicate working copies, never used by the analysis
RESEARCHER_DIRS = ("Iwai", "Nakashima", "Watanabe")   # where Behavior/<researcher>/<animal>/*.lvm may live

def pad(a):
    m = re.match(r"^([A-Z]+)(\d+)$", a)
    return f"{m.group(1)}{int(m.group(2)):02d}" if m else a

def variants(a):
    return list(dict.fromkeys([a, pad(a)]))

def read_summary(xlsx):
    import openpyxl
    ws = openpyxl.load_workbook(xlsx, read_only=True, data_only=True)["Sheet1"]
    rows = list(ws.iter_rows(values_only=True))
    animals = {}
    for row in rows[2:]:
        if row and row[0]:
            animals[str(row[0]).strip()] = {"location": (str(row[1]).strip() if row[1] is not None else ""),
                                            "lesion_size_mm3": row[2]}
    return animals

def find_dapi_dir(dapi_root, animal):
    for top in sorted(os.listdir(dapi_root)):
        tp = os.path.join(dapi_root, top)
        if not os.path.isdir(tp):
            continue
        for v in variants(animal):
            p = os.path.join(tp, v)
            if os.path.isdir(p):
                return p
    return None

def find_behavior_dir(share, animal):
    for r in RESEARCHER_DIRS:
        for v in variants(animal):
            p = os.path.join(share, "Behavior", r, v)
            if os.path.isdir(p):
                return p
    return None

def copy(src, dst, dry, log):
    if os.path.exists(dst) and os.path.getsize(dst) == os.path.getsize(src):
        return os.path.getsize(dst)
    log(f"  copy {os.path.basename(src)}")
    if not dry:
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(src, dst)
    return os.path.getsize(src)

def gzip_to(src, dst, dry, log, trust_existing=False):
    # a finished gzip is marked by a .ok sidecar (removed after checksums);
    # --trust-existing-gz treats any non-empty .gz from a completed run as done
    if os.path.exists(dst) and (os.path.exists(dst + ".ok") or (trust_existing and os.path.getsize(dst) > 0)):
        return os.path.getsize(dst)
    log(f"  gzip {os.path.basename(src)} ({os.path.getsize(src)/1e6:.0f} MB)")
    if dry:
        return 0
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(src, "rb") as fi, gzip.open(dst, "wb", compresslevel=6) as fo:
        shutil.copyfileobj(fi, fo, 8 * 1024 * 1024)
    open(dst + ".ok", "w").close()
    return os.path.getsize(dst)

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(8 * 1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--share", default="/Volumes/DataTransferForAllUsers_1day")
    ap.add_argument("--summary", default="ImagingData/Iwai/DAPI_Data/NOIO_summary_20260406.xlsx")
    ap.add_argument("--dapi", default="ImagingData/Iwai/DAPI_Data")
    ap.add_argument("--out", default=os.path.expanduser("~/ZenodoUpload/lesion-symptom-map-leverpull-data"))
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--no-checksums", action="store_true")
    ap.add_argument("--trust-existing-gz", action="store_true", help="skip .lvm.gz files that already exist (after a completed run)")
    ap.add_argument("--no-lvm", action="store_true", help="do not include the LabVIEW .lvm records (2026 submission: excluded)")
    a = ap.parse_args()
    share, out, dry = a.share, a.out, a.dry_run
    dapi_root = os.path.join(share, a.dapi)
    summary = os.path.join(share, a.summary)
    t0 = time.time()
    def log(msg):
        print(f"[{time.time()-t0:7.0f}s] {msg}", flush=True)

    animals = read_summary(summary)
    log(f"{len(animals)} animals in {os.path.basename(summary)}; out = {out}; dry_run = {dry}")
    if not dry:
        os.makedirs(os.path.join(out, "data"), exist_ok=True)

    rows = []
    for animal, info in animals.items():
        log(f"{animal} ({info['location']})")
        rec = {"animal": animal, "group": "sham" if (animal in SHAM_OVERRIDE or info["location"].lower() == "sham") else "infarction",
               "lesion_location": info["location"], "lesion_size_mm3": info["lesion_size_mm3"],
               "n_slices": 0, "n_ccf_mat": 0, "n_fallcount": 0, "n_corrections": 0, "n_lvm": 0, "bytes": 0}
        adir = os.path.join(out, "data", animal)

        # histology
        d = find_dapi_dir(dapi_root, animal)
        if d:
            for src in sorted(glob.glob(os.path.join(d, "slice_*.*"))):
                rec["bytes"] += copy(src, os.path.join(adir, "histology", os.path.basename(src)), dry, log)
                rec["n_slices"] += 1
            for name in CCF_KEEP:
                src = os.path.join(d, "CCF", name)
                if os.path.exists(src):
                    rec["bytes"] += copy(src, os.path.join(adir, "histology", "CCF", name), dry, log)
                    rec["n_ccf_mat"] += 1
        elif rec["group"] != "sham":
            log(f"  !! no histology folder for infarction animal {animal}")

        # behavior: FallCount.mat, top level of Movie/Iwai/<animal> only
        mdir = next((p for p in (os.path.join(share, "Movie", "Iwai", v) for v in variants(animal)) if os.path.isdir(p)), None)
        if mdir:
            for src in sorted(glob.glob(os.path.join(mdir, "*_FallCount.mat"))):
                rec["bytes"] += copy(src, os.path.join(adir, "behavior", os.path.basename(src)), dry, log)
                rec["n_fallcount"] += 1
            # manual curation applied on top of FallCount.mat by LeverPullTask_InfVsSham.m
            for src in sorted(glob.glob(os.path.join(mdir, "*_corrections.mat"))):
                rec["bytes"] += copy(src, os.path.join(adir, "behavior", os.path.basename(src)), dry, log)
                rec["n_corrections"] += 1
        else:
            log(f"  !! no Movie/Iwai folder for {animal}")

        # behavior: lvm (gzip), any depth except duplicate working folders
        bdir = None if a.no_lvm else find_behavior_dir(share, animal)
        if bdir:
            for src in sorted(glob.glob(os.path.join(bdir, "**", "*.lvm"), recursive=True)):
                if any(tok in src for tok in SKIP_DIR_TOKENS):
                    continue
                rec["bytes"] += gzip_to(src, os.path.join(adir, "behavior", "lvm", os.path.basename(src) + ".gz"), dry, log, a.trust_existing_gz)
                rec["n_lvm"] += 1
        elif not a.no_lvm:
            log(f"  !! no Behavior folder for {animal}")
        rows.append(rec)

    # shared files
    for rel in ("Movie/Iwai/FallCount_customCategories.mat", "Movie/Nakashima/FallCount_customCategories.mat", a.summary):
        src = os.path.join(share, rel)
        if os.path.exists(src):
            sub = "Iwai" if "/Iwai/" in rel and rel.endswith(".mat") else ("Nakashima" if "/Nakashima/" in rel else "")
            dst = os.path.join(out, "data", "_shared", sub, os.path.basename(src)) if sub else os.path.join(out, "data", "_shared", os.path.basename(src))
            copy(src, dst, dry, log)

    # manifest
    if not dry:
        with open(os.path.join(out, "manifest.csv"), "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
            w.writeheader(); w.writerows(rows)
    tot = sum(r["bytes"] for r in rows)
    log(f"done: {len(rows)} animals, {tot/1e9:.2f} GB in per-animal folders")
    for r in rows:
        log(f"  {r['animal']:6s} {r['group']:10s} slices={r['n_slices']:3d} ccf={r['n_ccf_mat']} fallcount={r['n_fallcount']:2d} corr={r['n_corrections']:2d} lvm={r['n_lvm']:2d} {r['bytes']/1e9:5.2f} GB")

    if not dry and not a.no_checksums:
        log("computing SHA-256 checksums")
        with open(os.path.join(out, "SHA256SUMS.txt"), "w") as f:
            for root, _, files in os.walk(os.path.join(out, "data")):
                for name in sorted(files):
                    if name.endswith(".ok"):
                        continue
                    p = os.path.join(root, name)
                    f.write(f"{sha256(p)}  {os.path.relpath(p, out)}\n")
        for root, _, files in os.walk(os.path.join(out, "data")):
            for name in files:
                if name.endswith(".ok"):
                    os.remove(os.path.join(root, name))
        log("checksums written")

if __name__ == "__main__":
    main()
