# Candidate code generation

The macOS ARM artifact `10911402956` from existing build run `36257316359`
contains probe `0782db656ccf5c9da1ee743ea21ef932567c978a`. Its ZIP size/digest,
source manifest and all three binary hashes were verified. `artifact.json`,
`manifest.json` and `verification.json` retain that identity; the artifact is
explicitly `release_validated: false`.

`otool -tvV` over this TUI binary finds **zero direct branches to generic
`Stdlib.min` / `Stdlib.max`** in the selected message-layout and scroll symbol
bodies. The baseline has 93 such sites, recorded in
`../baseline-bound-call-sites.json`. The candidate's selected assembly and
empty call-site list are retained here, together with decoded SHA-256 hashes.

`examples.txt` shows complete `scalar_cell_width` and `max_scroll` symbol
bodies from both binaries. Their former generic bound calls are replaced by
integer compare/branch instructions. `comparison.json` verifies the source
scope: only the two intended product files differ between these probes, and
both match the PR source exactly.

To reproduce the extraction after verifying an artifact's provenance:

```sh
python3 extract-assembly.py ARTIFACT_DIRECTORY NEW_OUTPUT_DIRECTORY --source FULL_SOURCE_SHA
```

The script verifies the TUI binary against its manifest before disassembling,
selects the same whole symbol bodies for either binary, and emits compressed
assembly, branch sites and an extraction receipt. The candidate extraction
was reproduced with this script and matches the independently collected
selected bytes exactly.

This proves a change in these generated paths. It does not count runtime
invocations, prove that all generic comparisons disappeared from linked code,
measure allocation or establish an input-latency improvement. The probe base
is older than the PR's main base. The separately dispatched
[PTY comparison 36259405687](https://github.com/jeong-sik/masc/actions/runs/36259405687)
uses the same pinned observer and three alternating pairs; no result is claimed
here. These artifacts came from a Release dispatch made before the updated
constitution directed future manual binary probes to `linux-x64-probe.yml`.
