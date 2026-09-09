# Standalone verifier Skills

Task and Goal verifiers now receive the existing `keeper_skill` tool when the
workspace has published readable instruction Skills. The tool advertises the
workspace's instruction catalog so each verifier can choose a relevant procedure
and load its body or bundled reference on demand. There is no role-name heuristic,
new preset, new environment variable, or duplicate Skill parser. The bundled
`skills/evidence-review/SKILL.md` provides a concrete verification procedure; the
existing embedded-skill seeder installs it as a missing package while preserving
operator edits.

The new connection is:

1. The shared Task/Goal reviewer hook reads the published workspace snapshot.
2. `Standalone_skill_tools` projects instruction entries using the same helper as
   Keeper's executable and advertised tool surfaces.
3. `run_named_with_masc_tools` preserves these native Agent-Core tools alongside
   the existing lookup and report tools. Invocation identity is not fabricated.
4. The original Skill reader serves the exact body or resource and sends every
   result to the existing verification observation callback.
5. The model uses its actual lookup tools and reports its verdict. The first
   real-model measurement is recorded in [20260909](20260909/README.md): all
   expected verdicts were correct, while strict tool-completion order passed 2/3.

A Skill supplies a procedure, not evidence, permission or new tools. Composition
execution is excluded. Task Read/Grep/Web and Goal Read/Web capabilities retain
their existing scope. No snapshot or no readable instruction entries means no
Skill tool is advertised. Workspace-resolution failures are logged; missing
optional Skills do not suppress verification.

The catalog and SKILL.md bodies freeze at the start of the run. Resource files
are read live through the existing owned-file reader; they are not part of the
SKILL.md content revision. The catalog includes all workspace instruction Skills,
not a role-filtered or per-Keeper selection. New observations retain the exact
reference and returned metadata through the existing tool-result path.

## Verification

`test_standalone_skill_tools` uses the real published snapshot, native tool
handler, filesystem reference reader and observation callback. It exercises body
and reference reads, frozen bodies across refresh, stale-reference rejection,
path traversal refusal, unpublished catalog behavior, workspace isolation and
composition exclusion. The merged PR CI ran these cases in a nonblocking step and four failed because
the fixture directory did not match its declared Skill name. The follow-up
corrects the fixture and exposes catalog rejection diagnostics. Execution of
the corrected suite still needs CI evidence. It does not measure model quality.

Targeted CI should run this suite and `test_keeper_task_skill_turn_exact`, which
covers the shared exact-reference/resource reader. The PR workflow builds
`@check` and also attempts the edited suites in a nonblocking step. A green PR
check alone therefore does not prove these tests passed; use the targeted Test
run's actual suite results. No local Dune build was run. `ocamldep -modules` was
used only to check syntax.

This change does not add tools to Librarian, Board-attention or Effect exact-output
calls. Those calls remain bounded selection/judgment operations over supplied
inputs. Fusion's separate web-tool path is unchanged. Extending those roles needs
its own output-protocol and capability tests; a Skill instruction cannot invent
that execution surface. Production Task submission and the other roles remain unmeasured. The isolated
Goal run below establishes actual Skill use, not a quality improvement baseline.

## Real-model acceptance runner

`scripts/harness/workload/standalone_verifier_skill_acceptance.py` takes an
already-built binary and an explicit runtime config. It creates and tears down
its own temporary workspace and server, then submits three synthetic Goal proofs:
matching evidence, the wrong revision, and a missing artifact. Provider credentials
come from the environment variables declared by the supplied config and model
overlay. Production storage and scheduler environment settings are not inherited.

```sh
python3 scripts/harness/workload/standalone_verifier_skill_acceptance.py \
  --binary /path/to/ci/masc-macos-arm64 \
  --runtime-config /path/to/runtime.toml \
  --models-overlay /path/to/agent-core-models-overlay.toml \
  --output-dir /tmp/standalone-verifier-evidence
```

The output directory must be new. The receipt records the binary/config/installed
Skill hashes, final Goal state, exact committed run, evaluator runtime, and observed
tool calls. Acceptance requires a successful `evidence-review` body read, a read of
the fixture path, and one expected verdict in that completion order. Existing-file reads must
return the exact complete fixture content and path, with no truncation. A correct verdict without
Skill use does not pass this workflow probe. This tests Goal proof through the
shared reviewer, not Task submission, every standalone role, or production quality.

`python3 test/test_standalone_verifier_skill_acceptance.py` exercises receipt
validation locally. These tests reject unrelated runs, failed reads of existing fixtures,
missing Skill use, other files, other Skills and duplicate verdicts. They exercise
the receipt checker, not a model. The first real-model receipt is [recorded here](20260909/README.md).

The first release build also found a stale `report_review_verdict` parameter
golden from the preceding role-prompt change. The one changed line in
`test/golden/tool_parity_params.txt` was copied from the release CI generator's
actual diff (run 34233401328), not regenerated by a local build. The next release
build must confirm the generator comparison is clean.

Tool completion timestamps do not prove that the model consumed the Skill before
choosing its evidence lookup: both requests can occur in one batch. Also, a Goal
run can aggregate tools across failed model attempts. Tool observations currently
lack attempt identity, so review the full server log for failover before making
one-model workflow claims. The runner does not establish attempt-level causality.
