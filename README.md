# lesion-symptom-map-leverpull

Analysis code for *Functional vulnerability of the M1/S1 transitional zone in post-stroke motor deficits in mice* (Osaki, Nakashima, Iwai, Masamizu; in preparation).

The pipeline quantifies right-forelimb behavior in a lever-pull task after photothrombotic infarction of mouse sensorimotor cortex, registers every lesion to the Allen Mouse Brain Common Coordinate Framework (CCFv3), and maps behavioral impairment pixel by pixel on the dorsal cortical surface.

## Pipeline

| Step | Script | Input | Output |
| --- | --- | --- | --- |
| 1. Behavior: per-session forelimb metrics | `GenerateFallCount.py` | DeepLabCut `.h5` tracking of frontal + ventral (mirror) views | `<session>_FallCount.mat` (FallTime, RegularHoldTime, CrossCount per 10 min) |
| 2. Histology: lesion registration to CCFv3 | `AP_histology-master/` (`AP_histology.m` GUI, `ap_histology.annotate_lesion`) | DAPI coronal sections (`slice_1.png`, ...) | `<animal>/CCF/LesionMapAllenCCF.mat` |
| 3. Lesion volume per region and per-animal summary | `OutputSummary_MOp_volume_Lever.m`, `Output_histology_selectedAnimal.m` | outputs of 1 and 2 | `InfarctionShamIDdata.mat`, figures |
| 4. Group comparison, time courses, pixel-wise lesion–symptom map with cluster-level permutation statistics | `LeverPullTask_InfVsSham.m` (reads the animal table via `Read_NOIO_summary.m`) | outputs of 1–3 | manuscript figures |

Dorsal-view region masks used for the pixel-wise map are in `AllenCCF/` (`MOp_topview_mask.mat`, `Region_topview_masks.mat`); `AP_histology-master/AllenMapTopView.m` regenerates them from the atlas.

## Requirements

* MATLAB R2023b with Statistics and Machine Learning Toolbox and Image Processing Toolbox.
* Python 3.9 with `numpy`, `scipy`, `pyyaml`, `h5py`, `matplotlib` (for `GenerateFallCount.py`). Tracking itself is done beforehand with [DeepLabCut](https://github.com/DeepLabCut/DeepLabCut).
* [npy-matlab](https://github.com/kwikteam/npy-matlab) on the MATLAB path (`readNPY`).
* Allen CCF atlas files (not included, about 9 GB): download `template_volume_10um.npy`, `annotation_volume_10um_by_index.npy` and `structure_tree_safe_2017.csv` from <https://osf.io/fv7ed/> and place them in `AllenCCF/`.

## Setup

1. Clone this repository and add it to the MATLAB path by running `startupHistology.m`.
2. Copy `local_paths.example.m` to `local_paths.m` and fill in the data locations for your machine. `local_paths.m` is ignored by git.
3. For `GenerateFallCount.py`, set the environment variable `DLC_CONFIG_PATH` to the DeepLabCut project `config.yaml`, then run:

```
python GenerateFallCount.py <animal_folder>
```

## Data

Processed data needed to reproduce the figures (per-session `*_FallCount.mat`, per-animal `LesionMapAllenCCF.mat`, `InfarctionShamIDdata.mat`, the animal summary spreadsheet) and representative raw examples will be deposited on Zenodo on publication. Full raw videos and section images are available from the corresponding author on reasonable request.

## Third-party code

* `AP_histology-master/` is a modified copy of [AP_histology](https://github.com/petersaj/AP_histology) by Andrew Peters (GPL-3.0). Modifications: lesion annotation (`+ap_histology/annotate_lesion.m`), slice flipping, dorsal-view atlas maps (`AllenMapTopView.m`, `AP_histology2ccf.m`).
* `neuropixels_trajectory_explorer-main/` is a copy of [neuropixels_trajectory_explorer](https://github.com/petersaj/neuropixels_trajectory_explorer) by Andrew Peters (GPL-3.0), used for CCF coordinate handling.
* `AP_histology-master/allenCCF_repo_functions/` contains helpers from [cortex-lab/allenCCF](https://github.com/cortex-lab/allenCCF) and `natsort` by Stephen Cobeldick.
* The Allen CCFv3 atlas is (c) Allen Institute for Brain Science; see the [Allen Institute terms of use](https://alleninstitute.org/terms-of-use/).

## License

GPL-3.0. See `LICENSE`. Because the repository contains modified GPL-3.0 code, derivative works must also be distributed under GPL-3.0.
