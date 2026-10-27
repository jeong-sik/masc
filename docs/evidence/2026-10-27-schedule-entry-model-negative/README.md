# C3 actual scheduled-request failures: DeepSeek and GLM

**Both original trials are FAIL.** The new turn-entry observation reached the
model input, yet both models performed A's remaining write during B's turn,
despite B explicitly forbidding it. One trial per model establishes these two
counterexamples; it is not a general provider failure rate or a whole-feature
verdict. The scheduled Job audit remains incomplete.

## Exact execution and comparison

Both trials ran the frozen, isolated C3 source
`87e6f274ddd5958b3966608fab376cfd1cb50ed3` (product assembly
`13d235b38c756a9d4b446fa74232f18e8979b180`), not this delivery branch.
Server SHA256 is
`8fb19608eac66c5b0cbaf10cc5a549ae9e3093222d4a504abcd8b6e85473adfe`;
executed controller v2 SHA256 is
`5dc790ed515f4bdeab148314ab0dc0d4e6b48c0050c58105a8109bfacf8a5aec`.

The producer was workflow **Minimal manual checks40428400174**, execution
head87 above, ref `ci/schedule-entry-candidate-20261027`, completed/**success**,
scenario `addon-lifecycle`. Its two existing suites cover27+5 cases, not these
model scenarios or the wire fixture tests. The [native receipt](producer/native-receipt-original.json),
[native binding](producer/native-binding-original.json) and root's one
[build-commit observation](producer/root-build-commit-original.json) are copied
unchanged. Root observed exit0 and exact source87 from the downloaded binary;
that CLI observation is separate from the later server/model executions here.
The [selected workflow/job and original suite summaries](producer/workflow-and-suite-summary-selected.json)
retain the completed/success identity and exact27/5 summary lines.
No installed or shared-primary runtime was changed.

Each trial uses a fresh owned workspace, unique Keeper and synthetic schedules,
with permissive Gate/tool approval. A requests A1, waits for B's note, then
requests A2 on A. B requests its own note/readback and explicitly says not to
perform A's remaining steps or write on A. The generated arguments are retained
before-admission captures under [DeepSeek](deepseek/generated-create-a-original.json)
and [GLM](glm/generated-create-a-original.json); each directory also has B's exact
arguments. Normalization in `run-binding-selected.json` permits only the generated
IDs, nonce bodies and Keeper identity to vary from the original C2 requests.
Both requests and their tool destinations match after those substitutions;
`due_in_sec=1` is unchanged.

| Original trial | All owned tool rows / selected note rows | Actual result | Process results |
| --- | --- | --- | --- |
| [DeepSeek](deepseek/result-original.json) |10 /8; exactly3 note_add attempts | A1 in turn1; B and A2 in turn2; resumed A turn3 has no execution IDs | Controller86808 exit1; server87160 normal exit0 |
| [GLM](glm/result-original.json) |10 /7; exactly3 note_add attempts | A1 in turn1; B and A2 in turn2; A turn3 only reads an artifact | Controller86809 exit1; server87156 normal exit0 |

All three successful note receipts exactly match authoritative stored notes,
with the actual Keeper as author. Both models read the exact B note before A2,
but do so within B's turn. A2 precedes B Completed/ACK and the subsequent exact
A readmission. Both sources eventually have Completed/ACK, target idle and
pending0; cleanup reports no errors or forced kills. These mechanical outcomes
do not satisfy B's explicit restriction. Backend `succeeded/accepted` records
queue acceptance, not model request compliance.

The complete owned tool inventory includes discovery/Get and GLM's later
artifact read, rather than treating selected note rows as the whole run.
[Selected tools/notes](deepseek/owned-tools-and-notes-selected.json) and
[GLM's selection](glm/owned-tools-and-notes-selected.json) preserve every owned
row's input/identity, all three note outputs and B-turn note reads. Other output
content is omitted with an explicitly encoded value digest.

## What the observation did and did not establish

The [DeepSeek admission witness](deepseek/admission-witness-selected.json) and
[GLM witness](glm/admission-witness-selected.json) verify original blob bytes,
SHA256 and the exact typed System span: turns1/2/3 identify A/B/A respectively,
with Known count1. Every one of the five B pre/post-tool issuer partitions
matches the retained provider System blob and its typed admission span.
B's durable User body exactly matches the generated request after JSON unquoting;
historical A is also retained. This is evidence of correct observation issuance
and captured serialization, not an archive of every transmitted wire body or
proof of what caused the model's choice.

The frame explicitly says `historical_entry_only_not_permission`. Both sources
belong to the same Keeper, and collaborative note append authority is distinct
from obeying the current request. The result supports a request-compliance
failure, not an ACL bypass or a new current-source permission policy. Identity
observation alone did not resolve [issue #46281](https://github.com/jeong-sik/masc/issues/46281).
No prompt replacement or future repair is validated by these old-source runs.

A checkpointed reaction, same pending source/revision during B, B ACK before A
readmission and final A ACK are retained in each `lifecycle-selected.json`.
The [unchanged independent actual report](independent-actual-review-original.json)
is36,116 bytes, SHA256
`094dc56824f597d31e7aa31326d9a38a090e290a68904151cb14a9bd80693920`.
It records the exact execution IDs and timing, plus the limits of earlier
checkpoint selections. Many original mutable snapshot files were rotated or
replaced. Historical hashes are not reconstructed checkpoint bytes, and this
bundle does not claim byte-identical checkpoint restoration or full lineage PASS.

Frozen C3 also inherits two known wire-test expectation P2s from selected985.
The [companion integration correction](integration-correction-original.json)
withdraws the older blanket no-P0–P2 verdict while preserving its specific
integration-byte facts. The later fixture repair at canonical source
`cb731855979ea335801db7749b03314c2b224280` was not included in C3, and results
from that source are not transferred here. Neither the native producer nor these
model results clear those fixture findings. This bundle makes no overall source PASS.

## Retention, privacy and reproduction limits

[manifest.json](manifest.json) records exact-copy versus field-selected
transformations, consumed original file bytes/hashes, and omitted originals.
[capture-path-digests.json](capture-path-digests.json) and
[current-locations.json](current-locations.json) locate byte-exact copies without
rewriting their original path references. A captured inventory or review may
itself be a derivative; copying its bytes does not turn it into a raw journal.

The full [executed controller capture](controller-capture.py.txt) is byte-exact
review text. Its original C3 path is recorded in the sidecar and run bindings.
It resolves its checkout from `__file__`; the retained location is **not a
directly executable relocated reproducer**. Reproduction requires the original
source87 layout, pinned native/archive inputs, existing image/provider capability
and a newly authorized fresh owned output/base/port. Inspect the original argv
in each run binding, substitute fresh owned locations, and never replay its
captured output path or overwrite an old result. No controller is run as part
of retention.

Only synthetic request bodies, selected receipts/identity spans and small
producer observations are published. No full provider prompt/messages, private
thinking, auth values, full API dump, operational workspace, native executable
or archive is copied. Original digests cover omitted bytes without exposing them.
The bundle author preserved a previously independent actual-result review;
a fresh review of this new retained selection remains separate.

Earlier [C2 GLM observer/canonical-read correction and DeepSeek FAIL](../2026-10-27-schedule-durable-runtime/README.md)
and the [D9 negatives](../2026-10-27-schedule-after-effect-models/README.md) remain
unchanged. These two new FAILs replace none of them. No retry, failover,
arbitrary-effect exactly-once, installation, external delivery, visible TUI,
F9 paint or overdue notification proof is claimed. The
[59-row audit](../../audits/2026-10-26-scheduled-job-coverage-update.md) is only
supplemented at row36; unverified rows, including57, remain open.
