# Zen download result delivery — 2026-09-08

A Keeper on source `c067555236735ea9baf55c990c134257a5e0197d` used real Zen through
geckodriver against an owned loopback fixture. The request asked for two different
binary downloads with the same suggested filename and one Unicode file in an iframe.

[Actual call metadata](before.json) records 15 calls, 10 successes and 5 failures.
Zen downloaded Binary A: 40,960 bytes, SHA-256
`90b3b375e4565eb5cf64f68b23809e221918ee6a0b78fac98debf002ffaf2c4d`, matching
fixture bytes. BrowserRead downloads then failed at provider projection with
`tool output artifact storage failed`. The remaining requested downloads, file
reader and model image analysis were not completed. The [viewport](before.png)
is an independent operator capture, not proof the Keeper captured or analyzed it.
Operation Succeeded is not completion of the requested workflow.

The file publisher returns a normalized durable blob reference. Tool_bridge requires
a durable result manifest before projecting such data. The Keeper BrowserRead
producer omitted that step; Execute and composition producers already perform it.
The fix persists the manifest at the BrowserRead producer boundary using the exact
workspace base path. Failed browser reads and ordinary non-artifact results retain
their existing disposition. Manifest persistence errors remain explicit.

The added regression passes a real published binary through the Keeper producer,
provider projection, durable manifest and referenced-byte fetch. It would fail at
provider projection before this change. Local builds were not run. Fresh live
verification of the changed binary must be recorded separately from this failing run.


## Fresh execution after producer fix

Source `6219ea13c477518d95ba35c4d320aa86d850b5c3`, executable SHA-256
`5a4e2595f90c0563e0854e17b52e29452f76dfc286061c63d8e5333b9257b18c`,
ran a new Keeper against the same owned loopback fixture. Default init seeded the
[four Skill files](automatic-skill-seed.json), with no operator Skill copying.
The request did not name a Skill. The trace records `keeper_skill` main and
advanced reference reads.

[The fresh trace receipt](after.json) contains 45 completed calls: 41 successes and
4 failures. The Keeper recovered from one missing observed tab ID and three
selector failures. This is a completed requested workflow with retries, not a
failure-free interaction run.

| Download | Actual filename | Bytes | Keeper reader pages |
| --- | --- | ---: | ---: |
| Binary A | `same.bin` | 40,960 | 6 |
| Binary B | `same(1).bin` | 41,216 | 5 |
| Iframe Unicode text | `unicode.txt` | 51 | 1 |

Each artifact's tool-returned pages were decoded according to their declared
UTF-8/base64 encoding, checked for contiguous offsets through EOF, concatenated,
and compared byte-for-byte with both the fixture and Zen's saved file. All three
SHA-256 digests match. A and B have distinct download IDs; the iframe download
has its own context. The Unicode payload retains its final LF. This download
check does not resolve the separate earlier model Write omission of an LF.

The Keeper captured [this viewport](after.png) and successfully passed its exact
artifact hash to `keeper_analyze_image`; a subsequent independent screenshot has
the same hash. The model read the visible title, two links and cropped iframe
text. Text below the visible iframe viewport is not claimed as image evidence.
The Keeper then closed its automation BrowserSession.

The run also exposed a remaining defect: all three result manifests contain
invalid UTF-8 from binary blob previews. Their paged bytes and hashes are exact,
but they are not valid UTF-8 JSON. Replacement decoding was used only to inspect
metadata for this receipt; it was never used for exact-byte verification. The
producer fix resolves missing artifact delivery, not this encoding defect.
The separate preview repair is tracked in [PR #34271](https://github.com/jeong-sik/masc/pull/34271);
this run predates that repair.

This is real headless Zen automation, not proof that an ordinary user Zen profile
has the native messaging extension connected. Cancellation, pending downloads,
and disconnected download recovery were not exercised here.

## Installer execution

[Installer receipt](installer.json) records the actual installer and immutable
`fe31fbcbd6ece858b957143bad64977c4678d9f7` main binary through a checksum-verified
local release mirror. Fresh install and existing-config upgrade install all four
built-in browser Skill files. Upgrade preserves runtime bytes and deliberate
prompt omission. Reinstall preserves an edited Skill and deleted reference.
[Direct init checks](builtin-init.json) additionally verify `init --force` does
not overwrite an existing Skill package.

The mirror uses fixture companion executables and fixture dashboard assets.
These checks do not prove public release publication or actual TUI execution.

The [owned fixture](fixture.py) is reproducible with
`python3 fixture.py --out /tmp/zen-download-fixture`; its `fixture.json` records
the OS-allocated loopback URL and expected digests. Stop that foreground process
after use. It serves synthetic payloads only.


## Shutdown and cleanup

BrowserSession close succeeded, but the original Keeper shutdown blocked while
waiting for Librarian lane exit. [Official recovery](recovery-public.json) used
an operator metadata update to supersede that blocked operation, preserving
runtime, sandbox, instructions and the two completed turns. One new official
shutdown reached `finalized` with stopped join evidence and no cleanup error.
The exact owned VM inventory was available and empty. This was not an automatic
first-attempt Keeper shutdown success.

[Process cleanup](process-cleanup.json) then verified and stopped only the owned
scratch MASC server, driver and fixture. Production MASC and user browser
processes were untouched; downloaded fixture bytes remain available for audit.
