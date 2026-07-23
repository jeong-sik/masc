# Checkpoint Purge Runbook (RFC-0351 S1)

RFC-0351:105 requires the operational cleanup procedure (backup included) to
be documented before S2. This runbook covers `masc-checkpoint-purge`
(#25537): the deterministic offline reduction of a keeper's canonical OAS
checkpoint. No LLM is involved at any step.

## What the tool does

Three closed rules, applied in this order (the order is a correctness
property — R2 before R1 is what makes a single pass a fixpoint):

| Rule | Action | Never touches |
|---|---|---|
| R2 reasoning strip | removes unsigned `Thinking`/`ReasoningDetails` blocks from assistant messages without `ToolUse` | signed thinking, `RedactedThinking` (byte-exact replay contract) |
| R3 tool-result clear | replaces `ToolResult` content in closed tool cycles with a fixed marker | `tool_use_id` pairing, typed outcome |
| R1 duplicate collapse | byte-identical text-only messages repeated 3+ times keep first and last occurrence | tool cycles, message order |

The last 20 messages (and the structural protected suffix) pass through
byte-exact. Input and output both run `Keeper_compaction_unit.validate`;
a structurally broken checkpoint is refused, never repaired (#25443 owns
the write boundary). `session_id`/`turn_count` are unchanged, so the save
lands as an equal-watermark re-save through the locked validated store.

## Procedure

1. **Confirm the keeper is stopped.** `masc_keeper_list` — the keeper must
   not be `active`/`keepalive_running`. A live keeper's next save overwrites
   the purge. (`masc_keeper_down <name>` if needed; restart is an operator
   decision.)
2. **Dry-run first.** Always. The report shows per-rule counts and the byte
   delta; a second dry-run after an apply must show all zeros (fixpoint).

   ```sh
   masc-checkpoint-purge --trace <trace-id> --base <base-path>/.masc
   ```
3. **Apply.** The tool writes a byte-exact backup before saving:

   ```sh
   masc-checkpoint-purge --trace <trace-id> --base <base-path>/.masc --apply
   # backup: {base}/backups-checkpoint-purge-<trace>-<ts>Z/<trace>.json
   ```
4. **Verify fixpoint.** Re-run the dry-run; expect `+0.0%` and zero rule
   counts.
5. **Keep the backup** until the keeper has completed at least one healthy
   turn after restart. Rollback is a plain file copy over the canonical
   checkpoint (server stopped).

## What the tool refuses (and what to do)

`checkpoint failed structural validation` (e.g. `Overlapping_tool_cycle`)
means the write boundary admitted a broken history (#25443). Do not
hand-edit the JSON and do not extend the tool to repair it — repair-on-read
is the workaround class this system rejects. Record the trace and error in
#25443 and leave the file untouched; such keepers likely cannot save new
checkpoints under strict validation and need the #25443 fix, not a purge.

## Fleet log

| Date (UTC) | Trace / keeper | Result | Backup |
|---|---|---|---|
| 2026-07-21 | sangsu | 885→313 msgs, 631KB→202KB (−68%, two passes: pre-fixpoint binary then final) | `backups-checkpoint-purge-trace-1780648779957-00000-20260721T133717Z`, `…T134005Z` |
| 2026-07-21 | taskmaster | −35.4% (1.0MB→650KB) | `…T155445Z` set |
| 2026-07-21 | nick0cave | −42.0% (1.1MB→630KB) | 〃 |
| 2026-07-21 | analyst | 1730→789 msgs, −38.6% | 〃 |
| 2026-07-21 | ramarama | 824→434 msgs, −48.0% | 〃 |
| 2026-07-21 | verifier | −27.1% | 〃 |
| 2026-07-21 | base | −28.6% | 〃 |
| 2026-07-21 | hitl-verifier | −4.1% | 〃 |
| 2026-07-21 | executor, idealist, garnet, rondo, albini | **refused** — `Overlapping_tool_cycle` (recorded in #25443) | untouched |
| 2026-07-21 | mad-improver (−48% available), issue_king, hitl-switch-verifier | skipped — keeper active at rollout time | — |

Known open item: user-block base64 images are outside R1–R3 (garnet carries
2.46MB of PNG payload, 77% of its checkpoint — #25542); an image rule needs
a decision before it is added.

## Relation to the sanctioned pipeline

This tool is a one-shot operational lever, not a runtime mechanism: the
runtime path stays compaction (until RFC-0351 S4 retires it) plus the S0
settlement ceilings (#25536, #25541, #25544). If a purge is needed twice on
the same keeper, that is a signal the inflow paths (#25462 wake markers,
oversized tool results) are not closed — fix the inflow, do not schedule
the purge.
