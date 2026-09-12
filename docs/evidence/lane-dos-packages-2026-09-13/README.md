# Recorded DOS package host probes

This bundle exports original bytes from two isolated local executions. It does
not rerun MASC, DOS or a Keeper, and does not qualify a current deployment. The
[package guide](../../../addons/dos-world/README.md#qualification-scope) describes
what these combinations established and their limits.

| Input | Exact source / CI |
| --- | --- |
| Native host and Dashboard | `4218e1c05e2029e7b63d8847aa857a18dd6db084`; [native](https://github.com/jeong-sik/masc/actions/runs/34699821571), [Dashboard](https://github.com/jeong-sik/masc/actions/runs/34699823363) |
| DOS package | `e0d4e0c35ae9b550d53a952c3340709f2deac4c6`; [actual DOS CI](https://github.com/jeong-sik/masc/actions/runs/34699775204) |
| Statistics package | `a534bd96e36106df1a2bfc6a8a352ff342b27e98`; [image CI](https://github.com/jeong-sik/masc/actions/runs/34697003041) |

[original-evidence.tar.gz](original-evidence.tar.gz) contains 209 unchanged files:
57 API response bodies with their original receipt metadata, 13 browser response
bodies and browser execution summaries, the host's Lane records and 21 retained
blobs, guest state/PNG files, container/process identities, and recorded cleanup.
The host probe includes its explicitly controlled companion source. Both DOS
machines actually ran the homebrew guest. Authentication files and credentials,
executables, image archives, Dashboard asset bodies, and unselected screenshots
are excluded. No replacement responses or simulated guest captures were generated
for this export.

[manifest.json](manifest.json) maps every exported path to its original relative
path, byte length and SHA-256. Original absolute paths inside responses are kept
as provenance; they are not paths the verifier opens. For a referenced
`lane-evidence:<sha>`, read `<probe>/.masc/lane-addons/evidence/<sha>.json` inside
the archive. The `.json` suffix belongs to the host store; some of those blobs
contain PNG or eight-byte guest data. The one external controlled-screen URI is
mapped to its exported fixture in the manifest. These paths are recorded evidence,
not product configuration defaults.

## Inspect the recorded claims

| Claim | Original records inside archive |
| --- | --- |
| Real guest 0→1 and same bytes after detach | Both probes' `evidence/{before,after,after-detach}.STATE.BIN` and `.png`; original host blobs carry the same digests. |
| Dashboard explicitly requests one increment and sees confirmation | Each probe's `evidence/browser/result.json` lists the original `response-*.json` hashes, request ID, actual executor, and receipt states. |
| Companion progresses while DOS workflow runs | `dos-host/evidence/0016.raw`, `0018.raw`, `0020.raw` show the same companion's sequences 2, 3, 4; `0026.raw` leaves it attached after DOS detach. |
| Statistics remains gauge 1 | `dos-statistics/evidence/0004.raw`, `0007.raw`, `0009.raw`, `0011.raw`; last two reuse producer sequence 3 with distinct consumer observations. |
| Missing producer is not a zero count | `dos-statistics/evidence/0015.raw` retains the same statistics worker with no count row and unavailable input. |
| History remains after detach | `dos-host/evidence/0029.raw` and `dos-statistics/evidence/0018.raw` are post-detach Slice responses; referenced output/source blobs are included. |
| Normal owned cleanup | Each probe's `summary.json`, `server.log`, final API snapshot, and `all-attempts-cleanup.json` preserve the recorded process/container cleanup results. These are historical receipts, not a fresh Docker query. |

The recorded Dashboard views are [DOS action](dos-action.png),
[DOS timeline](dos-timeline.png), [current statistics](statistics-current.png), and
[missing input](statistics-missing.png). Their original file hashes are in the
manifest.

## Offline verification

With Python 3 and Pillow available, run from this directory:

```sh
python3 verify.py
python3 negative_controls.py
```

[verify.py](verify.py) reads the archive without extracting paths or accessing the
network. It checks the manifest, all response and blob hashes, action/request/
executor linkage, raw guest layout, and all pixels of six 320×200 VGA captures.
Each capture export is joined to its measured API row, original retained
observation, and content-addressed guest/PNG blobs; the post-detach Slice must
retain the same measured row. Statistics checks compare the exact producer,
installation, run, consumer, and upstream DOS row across all four stages,
including distinct consumer observations of the same producer cursor.
Cleanup requires an explicit zero exit for the owned server, normal absence
for every final instance, and matching entries in the all-attempts absence
ledger. The original `dos-host/evidence/0026.raw` must show the same companion
still attached while that DOS owner is detached. It
recomputes facts from bytes rather than accepting only the producer's success
label. [verification.json](verification.json) is the recorded output of that
check. It is an export integrity and recorded-outcome check, not evidence of a
new live run, model reasoning, performance acceptance or broad DOS compatibility.

[negative_controls.py](negative_controls.py) first verifies the untouched
archive, then changes copies of selected records in memory to exercise these
cross-record checks independently of manifest hash failures. All 22 controls
must be rejected, including disconnected capture blobs, missing cleanup fields
or entries, changed producer/run/installation/consumer identities, incorrect
upstream rows, and a detached or replaced companion.
[audit-negative-controls.json](audit-negative-controls.json) records the results.
These deliberately corrupted test inputs are not new runtime observations and
are never written into the original archive or manifest.
