# Terminal media retains byte identity on recovery

PR [#47317](https://github.com/jeong-sik/masc/pull/47317) compares terminal
media through the history codec's decoded byte identity. It still materializes
and validates restored media, keeps text/MIME/order/tool data/provenance exact,
and returns the untouched persisted provider response.

Actual workflow **Test** [41316474760](https://github.com/jeong-sik/masc/actions/runs/41316474760), checkout
`c9776cc2968353a1f66af2c127cf6b28f64ba49a`, ref `fix/terminal-media-identity-20261101`, explicit
`minimal=true`, targets Pipeline and execution journal, existing 600-second
targeted-suite guard: **SUCCESS, 146 PASS / 0 FAIL** (Pipeline 125, journal 21).
Three registered media cases cover equivalent valid encodings, exact-content
refusals, and malformed/unavailable bytes. Their internal assertions are not
counted as additional executed cases. Other cases remain scoped controls.
There is no same-fixture media before/after execution or addition to the
historical 143/0 result.

The full four-file delta was independently source-reviewed. The rebased
reference `28e080c3cbeeeba4c95d75394c1e2418d8df67c3` has the same full delta canonical and all
19 named inputs, complete Core tree and config tree as the executed source.
Root lib/test trees changed through the lower batch-owner repair and are
excluded. Subsequent evidence-only commits preserve those named inputs and
Core/config trees; they are not executions at a later documentation head.

The source preserves the authored three-file integration from external merge
`2cbd919e52988c0c842672e6d71450246b368429`. Its main parent and full merge object are
retained under the local archive ref recorded in campaign artifacts. Resume
implementation/interface blobs match that merge; the test file also retains
the Pricing delta already present in this stack. Exact added/removed lines
verify that preservation. The whole 21-branch atomic publication restored the
lower Core PR's original scope while preserving this media repair in its own
linear layer. `scope-restoration.json` records both original parents' context
and the captured authored source blobs; it does not approve the broad main merge.

Raw logs remain in ignored campaign artifacts. `candidate.txt` is an ANSI/BOM
normalized, line-selected derivative preserving every case, checkout, target
and summary. Raw and retained byte digests are separate. `cases.tsv` uses
source/group/index/fixture-SHA identities; only the three media names are
expanded from source, and other displays may be ellipsized. The compact UTF-8
JSON key vector plus one LF hashes to `03f3d690c042823b9d4f5bb23e965811518ebd2841a55ef6fbe8a36dcf7bb36a`. Metadata paths were made
repository-relative in the retained derivative; original digests are unchanged.

This is a mock-backed public Pipeline/journal execution with synthetic recovery
windows, not OS restart, installed runtime, real provider/account, full regression
or whole-stack integration. No local build/typecheck ran. Internal source/evidence
review is separate from trusted non-author GitHub approval and merge. #27890's
original hard cut remains open; no issue is closed.
