# X5H NPU: the host-side inputs and the board-side checks

What lives here is the part of NPU work that can live in a public repository:
the scripts that turn public model weights into compiler inputs, and the checks
that grade what the board does with the result. The procedure, the reasoning and
the recovery paths are in [../npu-bringup.md](../npu-bringup.md); read that
first if you are about to touch the board.

**Read the status section of that document before quoting any of this as
working.** As of 2026-08-21 the NPU does execute — the shipped ResNet18 sample
runs on it — but model load faults the kernel for larger models, and every
measurement so far was taken without the bootloader the vendor documents for
this package. So this directory is complete as tooling and incomplete as
results.

## What is not here, and why

The compiler wrapper, the licence, the SDK paths and every vendor address stay
outside this repository, exactly as in
[../cr52-slot-update.md](../cr52-slot-update.md). That is not tidiness: the SDK
is NDA-bound material. The scripts here take file paths as arguments and read
vendor values from the SDK at the time you run them, so nothing needs to be
copied in to make them work.

Concretely, the NNAC compile step itself — `renesas_ep_gen_artifacts.py` from
the runtime release, plus a local wrapper for the model that needs post-legalize
surgery — is invoked from the working area, not from here.

## Host: from public weights to compiler inputs

| Step | Script | Marker |
| --- | --- | --- |
| Fetch the pinned VisionPilot models | `vp-models/export-models.sh [dest] [src]` | `VP_MODELS_OK` |
| Pin the symbolic batch dimension | `vp-models/fix-static-shapes.py <src> <dst>` | `STATIC_SHAPES_OK` |
| Build calibration data and replay feeds | `vp-models/calib-dump.py --model … --clip …` | `CALIB_DUMP_OK` |

Order matters for the middle one: the models ship with a symbolic batch
dimension on inputs *and* outputs, and the compiler frontend fails late, inside
legalization, if it is left symbolic. Pinning the inputs alone is not enough.

`calib-dump.py` mirrors the pinned VisionPilot C++ preprocessing rather than a
reasonable-looking reconstruction of it, because the three models are **not**
preprocessed the same way — one gets a perspective-warped image with ImageNet
normalization, the other two share a top-cropped resize with no normalization
beyond `/255`. Feeding either model the other's tensors sets every quantization
range wrong at once. Two of the model headers also document preprocessing the
code does not perform; the code is what runs. The constants and their source
lines are in the script's docstring.

It writes two trees from one pass: a calibration tree in the layout
`--calibration-path` expects (one directory per input, file names sorting into
frame order, equal counts per input — the generator indexes inputs by position),
and an ordered replay tree for the consistency check.

## Board: grading what actually happened

| Step | Script | Marker |
| --- | --- | --- |
| Prove the whole chain to the device node | `../scripts/npu-probe.sh [artifacts] [image]` | `NPU_PROBE_PASS` / `NPU_PROBE_FAIL reason=…` |
| Compare NPU against CPU over replay feeds | `vp-models/consistency-check.py` | `CONSISTENCY_PASS` / `_FAIL` / `_CALIBRATED` |

Run the probe first, and grade by its marker rather than by an exit status or by
reading output. Three reasons, all measured rather than assumed:

- The vendor's evaluation script catches every exception, prints
  `Error occurred: …` and returns normally, so `$?` is 0 on a board with no NPU
  at all.
- A completed run is not an offloaded run: the provider list ends in
  `CPUExecutionProvider`, so a board without a working NPU produces correct
  results and a plausible latency.
- A run can print correct numbers on a kernel that has **already** oopsed. The
  probe refuses to measure on a damaged kernel and checks again afterwards;
  nothing else in this directory does.

`consistency-check.py` freezes an envelope rather than demanding equality — the
NPU path is quantized, so it cannot match the CPU exactly, and the useful
question is whether the difference has moved. Calibrate once per model
(`--calibrate`), commit the resulting `tolerance.json`, then run without the
flag to assert. Calibration merges into the existing file, so calibrating the
second model does not evict the first.

`tolerance.json` is **not** committed yet, and cannot be until model load stops
faulting the kernel: freezing an envelope from a run that never happened would
be worse than having no envelope.

## Mounting artifacts, which is the trap that looks like a driver bug

The backend opens the artifact path recorded in the manifest. The shipped
samples record a path *relative* to the artifacts directory's parent and
starting with that directory's own name, so the mount must preserve the
directory name — mount it as `/work/artifacts` and the backend looks for
`/work/<name>` and misses. Locally compiled artifacts instead record the
*absolute* path of the machine that compiled them, which the backend opens
verbatim, so there the mount point has to be that path. `npu-probe.sh` reads the
manifest and picks the right form; do the same by hand.
