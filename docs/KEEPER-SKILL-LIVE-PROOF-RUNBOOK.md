# Keeper Skill live proof runbook

This runbook proves that one autonomous Keeper selected and used a Skill. A
catalog entry, exposed tool, unit test, or synthetic ledger fixture is not this
proof.

The scripts observe facts. They do not force a Skill invocation, retry a
natural message, or gate the Keeper's next action.

## Completion matrix

All rows must refer to one clean source tree, server process, workspace,
Keeper, `Turn_ref`, and `skill_tool_use_id`.

| Measurement | Pass value | Authority |
|---|---:|---|
| natural Keeper messages submitted | 1 | producer receipt `producer_calls.masc_keeper_msg` |
| terminal Keeper operations | 1 `Succeeded` | typed operation receipt |
| exact-turn Skill activations | 1 | OCaml-decoded historical ledger projection |
| selected `skill_tool_use_id` values | 1 | exact `Turn_ref` join |
| typed projection/raw durable mismatches | 0 | join before/after comparison |
| verified deliveries | at least 1 | activation delivery boundary |
| later model-selected actions | at least 1 | activation actions |
| invalid transitions | 0 | ledger scoped summary |
| Dashboard exact-row screenshots | 1 | collector artifact manifest |
| TUI exact-row screenshots | 1 | TUI capture manifest |
| source/server/process identity changes during proof | 0 | source and `/health?full=1` snapshots |
| `INCOMPLETE` markers after success | 0 | every evidence directory |

`no_skill_observed`, `multiple_skill_activations`, and `not_recorded` are
truthful observations, but none passes this matrix. Dashboard rollover is not a
failure when the exact historical projection remains typed and stable.

## Time order

| Time | Actor | Effect | Durable or captured output |
|---:|---|---|---|
| t0 | operator | freeze clean source HEAD/tree and TUI build | build manifest + executable SHA-256 |
| t1 | producer | read server identity and exact existing Keeper/runtime | health snapshot |
| t2 | producer | submit the unchanged natural message once | queued operation id |
| t3 | Keeper | choose whether to call a Skill and continue acting | operation `Turn_ref` |
| t4 | runtime | record activation, delivery, and later actions | session Skill ledger |
| t5 | join | load t3's trace through the OCaml typed decoder and compare raw bytes | exact 0/1/many result |
| t6 | collector | require one exact id, delivery, action, and zero invalid transitions | proof JSON + Dashboard PNG |
| t7 | TUI capture | select the exact Keeper and receipt row | TUI JSON + PNG |
| t8 | verifier | compare all manifest hashes and identity tuples | pass/fail matrix |

## Inputs

Runtime and Skill sources remain configured by `runtime.toml`. The values below
are per-execution selectors and evidence destinations, not new configuration
or environment-variable fallbacks.

- clean repository path and its exact deployed commit
- base URL and token file for that server
- effective base path reported by `/health?full=1`
- one existing Keeper and its declarative runtime id
- MCP protocol version accepted by the running server/client pair
- one message file containing the natural task, without prescribing a Skill
- fresh output directories
- explicit request, observation, polling, and capture durations

## Execute

Use ephemeral shell variables only to keep the command readable. Do not reuse
an evidence directory from another run.

```sh
REPO=/absolute/path/to/masc
BASE_URL=http://127.0.0.1:8935
BASE_PATH=/absolute/effective/base
TOKEN_FILE=/absolute/path/to/token
KEEPER=exact-existing-keeper
RUNTIME_ID=keeper-declarative-runtime
MCP_PROTOCOL_VERSION=validated-protocol-version
MESSAGE_FILE=/absolute/path/to/natural-task.txt
EVIDENCE_ROOT=/absolute/path/to/fresh-evidence-root
SOURCE_SHA=$(git -C "$REPO" rev-parse HEAD)
SOURCE_TREE=$(git -C "$REPO" rev-parse HEAD^{tree})
```

First build the TUI in the isolated exact-head producer:

```sh
python3 "$REPO/scripts/harness/workload/produce_tui_build_evidence.py" \
  --repo "$REPO" \
  --expected-source-sha "$SOURCE_SHA" \
  --expected-source-tree "$SOURCE_TREE" \
  --out "$EVIDENCE_ROOT/tui-build"
```

Submit one natural Keeper message. The producer performs exactly one
`masc_keeper_msg` call and only observes that operation afterward:

```sh
python3 "$REPO/scripts/harness/workload/produce_natural_keeper_skill_proof.py" \
  --base-url "$BASE_URL" \
  --expected-base-path "$BASE_PATH" \
  --source-repo "$REPO" \
  --expected-source-sha "$SOURCE_SHA" \
  --token-file "$TOKEN_FILE" \
  --keeper "$KEEPER" \
  --runtime-id "$RUNTIME_ID" \
  --message-file "$MESSAGE_FILE" \
  --out "$EVIDENCE_ROOT/natural" \
  --mcp-protocol-version "$MCP_PROTOCOL_VERSION" \
  --request-timeout-seconds 30 \
  --observation-timeout-seconds 900 \
  --poll-interval-seconds 2
```

Hash the immutable producer receipt out of band, then join its `Turn_ref` to
the exact typed historical ledger:

```sh
PRODUCER_SHA=$(shasum -a 256 "$EVIDENCE_ROOT/natural/receipt.json" | awk '{print $1}')

python3 "$REPO/scripts/harness/workload/join_natural_keeper_skill_ledger.py" \
  --producer-receipt "$EVIDENCE_ROOT/natural/receipt.json" \
  --expected-producer-receipt-sha256 "$PRODUCER_SHA" \
  --base-url "$BASE_URL" \
  --token-file "$TOKEN_FILE" \
  --out "$EVIDENCE_ROOT/join" \
  --timeout 30
```

Continue only when `join.json` has `result.kind = exact_skill_invocation` and
`result.match_count = 1`. Copy its exact selected id; do not select by time,
Skill name, prefix, or response text.

```sh
SKILL_TOOL_USE_ID=$(jq -er '.result.selected_skill_tool_use_id' "$EVIDENCE_ROOT/join/join.json")
TUI_BUILD_SHA=$(shasum -a 256 "$EVIDENCE_ROOT/tui-build/build-evidence.json" | awk '{print $1}')

python3 "$REPO/scripts/harness/workload/keeper_skill_use_proof.py" \
  --base-url "$BASE_URL" \
  --keeper "$KEEPER" \
  --expected-source-sha "$SOURCE_SHA" \
  --tui-build-evidence "$EVIDENCE_ROOT/tui-build/build-evidence.json" \
  --expected-tui-build-evidence-sha256 "$TUI_BUILD_SHA" \
  --skill-tool-use-id "$SKILL_TOOL_USE_ID" \
  --out "$EVIDENCE_ROOT/proof" \
  --timeout 30
```

Finally capture the same exact row in the TUI:

```sh
PROOF_SHA=$(shasum -a 256 "$EVIDENCE_ROOT/proof/evidence.json" | awk '{print $1}')

python3 "$REPO/scripts/harness/workload/capture_keeper_skill_tui_proof.py" \
  --proof "$EVIDENCE_ROOT/proof/evidence.json" \
  --expected-proof-sha256 "$PROOF_SHA" \
  --out "$EVIDENCE_ROOT/tui" \
  --cols 180 \
  --rows 42 \
  --timeout 60
```

## Three execution paths

The same identity and evidence contract applies to three independently useful
paths. A campaign reports them separately; success in one does not imply the
others.

| Path | Natural input | Required additional observation |
|---|---|---|
| instruction Skill | task whose useful context lives in `SKILL.md` or a resource | served body/resource digest |
| composition Skill | task naturally suited to the composition tool | composition invocation plus later action |
| runtime failover | either task while the provider runtime changes | invocation, delivery, and action runtime ids retained separately |

For failover, equality of runtime ids is not failure by itself unless failover
was actually induced. The campaign must separately prove the observed provider
failure and recovery; this runbook never infers failover from different labels.

## Interpretation

This bundle proves observable ordering: Skill content was invoked, reached a
typed delivery boundary, and a later model-selected action occurred with that
content available. It does not claim access to private chain-of-thought or prove
that one hidden token caused the action.

Do not call the result deployed or live until the source commit is merged, the
server reports that exact commit and process id, and the complete bundle above
was captured from that process.
