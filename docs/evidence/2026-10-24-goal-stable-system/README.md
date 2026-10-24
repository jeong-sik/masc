# Goal observation in the issued System prompt

Base: `9f024959528a5c0ea12ce59f0c1a63b2a364695d`. This work changes the
carrier of the existing turn-start Goal observation. It does not add Goal
association, approval, completion or permission rules.

## Reason for the change

The preceding live Keeper run retained the Goal observation across tool rounds,
but placed it in a trailing `[system context]` User message. Its repeated
`keeper_task_create` calls included the matching Goal ID and omitted the
required description despite receiving the real validation error. A separate
parent-owned diagnostic replayed one frozen request with the same model,
options and seed without executing any tools. The trailing User arm omitted
the description; the System suffix and leading User arms supplied it. This is
one frozen case, not a population result, a proven general causal mechanism,
or successful G2/G3 execution.

The change issues only the typed Goal observation as a suffix of the existing
System prompt through `system_prompt_override`. The canonical formatter labels
it as a turn-start stored observation containing data, not instructions,
permission authority or completion proof. Later real tool observations may be
newer. The original System base or pre-existing override is retained
structurally; no substring de-duplication is used. Without a Goal, the previous
override remains exactly `None`, `Some ""` or its prior bytes. Other Dynamic
world state continues to be suppressed after a tool round.

## Provenance and consumers

The issued System carrier has its own exact raw UTF8 byte partition and SHA256.
The extra-context receipt continues to describe only extra context. Logical
blocks count the base instructions and Goal once; forecast composition assigns
the Goal to System bytes rather than extra pinned bytes. A serialized request
freezes its issued System value for the provider-input snapshot rather than
reconstructing it from the base prompt or a later request assembly.

Last-prompt captures and their dashboard decoder retain old captures with both
new fields absent as **System carrier unrecorded**. This does not establish
Goal absence. Half-present fields and an incorrect explicit carrier are
rejected. The dashboard displays System and extra context separately. The
existing `memory-inspector` block metadata map also receives the previously
missing `prompt.active_goals` entry; the exact-base compiler overlay below
reproduces that missing-consumer error before the repair.

These receipts describe issuance before provider message/IPC encoding. They
do not prove remote retention. The official-client host already consumes the
existing override, but official held/resume native identity behavior has not
been executed for this change. The existing official extra-context subset
proof remains scoped to extra context and does not assert a Goal System span.

## Executed checks

- `carrier-check.txt`, `carrier-check.json`: 32 passing checks compiled and
  executed against actual pure source. `probe_carriers.py` copies whole typed
  assembly/layer modules and extracts the exact request-assembly functions and
  actual Safe_ops sanitizer. It checks Goal retention across rounds, no extra
  Goal, other world-state suppression, structural overrides, raw byte spans,
  hashes and logical counting. This does not execute the production hook,
  SDK HTTP transport or a real Keeper.
- `source-checks.json`: all 12 changed OCaml interfaces/implementations parse.
  No local Dune, full product typecheck, linking or native suite was run.
- `frontend-tests.txt`: the API decoder and inspector panel suites pass,
  25 tests across two files.
- `typescript-baseline.json`: a read-only TypeScript compiler overlay using
  the exact base source reproduces three diagnostics: the missing
  `prompt.active_goals` metadata entry and two `keeper-stream.test.ts` TS2322
  errors. `typescript-current.txt` contains only those same two unchanged
  `keeper-stream.test.ts` diagnostics at lines 1862 and 1873. Full TypeScript
  validation therefore remains failing on that existing baseline.
- `git diff --check` passes.

The authored real HTTP receiver regression checks three provider requests,
leading System Goal bytes, unchanged prior override, first-request-only other
world state, genuine bundled Task creation/linkage, captures and an ephemeral
checkpoint. Its native execution, a new exact-build Keeper experiment and a
visible browser check are pending. No live G2/G3 success is claimed here.
