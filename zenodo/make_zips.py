#!/usr/bin/env python3
"""Package the two Zenodo records as zip files (stored, no recompression).
record1: one zip per animal + _shared.zip; README.md, manifest.csv, SHA256SUMS.txt kept as loose files.
record2: one zip per top-level folder (videos, dlc_tracking, dlc_model, behavior); README.md loose."""
import os, zipfile, hashlib, shutil, time
H = os.path.expanduser("~/ZenodoUpload")
R1 = os.path.join(H, "lesion-symptom-map-leverpull-data")
R2 = os.path.join(H, "lesion-symptom-map-leverpull-example-NO57")
U1 = os.path.join(H, "upload", "record1_processed_data")
U2 = os.path.join(H, "upload", "record2_example_NO57")
t0 = time.time()
def log(m): print(f"[{time.time()-t0:6.0f}s] {m}", flush=True)
def zipdir(src_dir, dst_zip, arc_root):
    if os.path.exists(dst_zip):
        return
    tmp = dst_zip + ".part"
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_STORED, allowZip64=True) as z:
        for root, _, files in os.walk(src_dir):
            for f in sorted(files):
                p = os.path.join(root, f)
                z.write(p, os.path.join(arc_root, os.path.relpath(p, src_dir)))
    os.replace(tmp, dst_zip)
    log(f"{os.path.basename(dst_zip)}  {os.path.getsize(dst_zip)/1e9:.2f} GB")
def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for c in iter(lambda: f.read(8 << 20), b""): h.update(c)
    return h.hexdigest()
def sums(d):
    with open(os.path.join(d, "SHA256SUMS_zips.txt"), "w") as f:
        for n in sorted(os.listdir(d)):
            if n.endswith(".zip"): f.write(f"{sha(os.path.join(d,n))}  {n}\n")

os.makedirs(U1, exist_ok=True); os.makedirs(U2, exist_ok=True)
# record 1
for a in sorted(os.listdir(os.path.join(R1, "data"))):
    zipdir(os.path.join(R1, "data", a), os.path.join(U1, f"{a}.zip"), a)
for n in ("README.md", "manifest.csv", "SHA256SUMS.txt"):
    shutil.copy2(os.path.join(R1, n), os.path.join(U1, n))
sums(U1)
# record 2
for d in ("videos", "dlc_tracking", "dlc_model", "behavior"):
    zipdir(os.path.join(R2, d), os.path.join(U2, f"NO57_{d}.zip"), d)
shutil.copy2(os.path.join(R2, "README.md"), os.path.join(U2, "README.md"))
sums(U2)
log("ZIPS DONE")
