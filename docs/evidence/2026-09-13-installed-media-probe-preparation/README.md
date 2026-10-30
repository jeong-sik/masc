# Installed original-media probe preparation

`scripts/verify-installed-media-inspection.py` is ready for execution after the
new CLI is installed. It requires explicit installed prefix, full source commit,
workspace, Keeper names, three original file paths, portable soffice and a fresh
output directory:

```sh
python3 scripts/verify-installed-media-inspection.py \
  --prefix INSTALLED_PREFIX --source-commit FULL_COMMIT --base WORKSPACE \
  --keeper exhibit-editor --keeper exhibit-designer \
  --pptx ORIGINAL.pptx --mp4 ORIGINAL.mp4 --pdf ORIGINAL.pdf \
  --soffice PORTABLE_SOFFICE --output FRESH_OUTPUT
```

The probe checks the installed binary, companions, Dashboard and runtime manifest
files, then checks the executed binary's embedded commit. It reads each selected
original independently and invokes the real CLI; it accepts no producer JSON as
inspection evidence. Raw command output, decoded PNG bytes and their hashes,
native MP4 probe/decode outputs, typed outcomes and an overall receipt are saved.
Source and installed-release identities are checked again before success.

The shared `capture-collaboration-state.py` records before/after state. Canonical
`tasks/backlog.json`, Goals, runtime and selected Keeper TOMLs are mandatory, and
all captured configuration TOMLs must remain identical. Broader playground
changes are recorded separately; the probe does not attribute concurrent runtime
activity to the CLI. It performs no Task/Goal transition, model verdict, server
replacement or dependency installation.

The initial six synthetic receipt-validator tests passed, but independent review found three false-success cases: PNG without IDAT, partial decode flags, and raw audio reclassified as unknown. These were corrected; nine tests and independent reruns now reject all three. PNG checks require Pillow and perform verify plus full pixel loading, while video checks compare the entire argv contract and raw stream kinds. They exercise missing typed fields,
incorrect source identity, incomplete PNGs, missing video stream maps, failed
native results, absent scope information and duplicate JSON fields. The release
checker also verified 5,431 manifest files of the existing aad94 installation
without invoking media inspection. These checks do not establish native CLI or
installed media acceptance. The actual new `inspect-file` command has not run.

The root also checked the currently installed4324764 release: 5,431 companion/asset/runtime files matched its manifest. This remains a read-only release identity check, not execution of the new CLI. The capture helper was tested against missing canonical backlog, symlinked parents/state roots, ordinary changes and JSONL prefix retention. Its corrected real preflight captured352 files including the five required paths; a subsequent observation found all352 unchanged. This was not a restart or an atomic whole-workspace snapshot.
