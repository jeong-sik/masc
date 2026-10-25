# Required typed Librarian origin — #46007 / #25851

Main `114b5783b92f8695ae49ac1d0ecb82ad307ebaa7` fails the shared MASC
library build at keeper_librarian_input_capture.ml's reference to the removed
Agent_core Extra_system_context_provenance module. Existing draft #46007
replaced that reference with a local metadata classifier. Review5644581166
questioned retaining that compatibility behavior under the constitution's
legacy_residue rule. It was COMMENT, not formal approval or executed evidence.

This correction stays in the same PR and removes the obsolete inference path.
Current producers already carry closed typed origin. Both message and complete
input decoding require it and reject absence, duplicate, unknown or null values.
Conflicting historical metadata never changes an explicitly supplied origin.

The durable capture's separate manual Superseded_version checkpoint decoder was
also removed. Retained canonical bytes must pass the existing exact checkpoint
decoder; hash/session/turn/messages checks cannot independently admit an old
version. Canonical-byte/reference equality, persisted-field comparison, richer
ToolResult JSON, ordered metadata, source projection and receipt/frontier guards
remain. Checkpoint/official/mixed current inputs retain one exact serialization.

Origin-free formatting, source-format detection and optional origin-free Range
and atom-digest APIs are deleted with all consumers. Atom digests always use
current Checkpoint.message_to_json, including typed origin. This intentionally
refuses incompatible captures and performs no migration or runtime state edit.

Baseline request [40225027356](https://github.com/jeong-sik/masc/actions/runs/40225027356)
targets exact `f178033d1877e37de8345a86dcc1e51534fc2c50` with only input capture
and durable capture suites. Its result is unverified. The fixture-only candidate
replaces old success fixtures with current typed-origin roundtrip, strict
malformed-origin refusal, superseded canonical version refusal despite current
origins and recomputed hash, plus source/input origin tampering rejection.
The baseline includes the earlier draft compiler patch; it is not main execution.

Changed OCaml sources/interfaces parse and whitespace passes. Two independent
working-source reviews found no P0–P2; they do not prove compilation/execution or
formal GitHub approval. No local Dune/typecheck or live runtime mutation ran.

Focused verification traces input codec → retained checkpoint/official/mixed
sources → strict durable restoration, Range.select/cut_lines → origin-bearing
atom digests → boundary/source validation. Corrected checks select input capture,
durable capture, Librarian range and runtime model-input tail-window suites.
Their actual results must be read separately from source assessment.

This fixes one obsolete origin classifier and shared-library compile reference;
it is not completion of all fifteen #25851 members, current operating memory
quality (#25052), full regression, installed runtime, deployment or integration.
