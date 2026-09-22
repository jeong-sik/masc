# Checkpoint Purge Runbook (RFC-0351 S1)

RFC-0351:105 requires the operational cleanup procedure (backup included) to
be documented before S2. This runbook covers the Dashboard action and
`masc-checkpoint-purge` (#25537): the deterministic reduction of a stopped
keeper's canonical agent core checkpoint. No LLM is involved at any step.

## What the tool does

Two closed rules. Neither removes a message:

| Rule | Action | Never touches |
|---|---|---|
| Reasoning strip | removes unsigned `Thinking`/`ReasoningDetails` blocks from assistant messages; a message the strip would leave empty is kept as it was | signed thinking, `RedactedThinking` (byte-exact replay contract) |
| Tool-result clear | replaces successful `ToolResult` content in closed tool cycles with a fixed marker | `tool_use_id` pairing, typed outcome, failed results |

Every `User` and `Assistant` message opens an atom. The turn-boundary log,
the Librarian position, the Librarian working state and the request front
name a place by its atom number and the digest of the message that opens
that atom, so these pass through byte-exact:

- the last 20 messages, the last atom whole, and the structural protected
  suffix;
- the opening message of each atom a `Turn_ended` line of the trace names;
- everything ahead of the end of a Librarian working state that fits the
  history. The request sends the working state in place of those atoms, so
  leaving them costs disk only.

After the rewrite the tool checks the atom count, each kept opening message
and the working state, and installs nothing if any of them moved. A
structurally broken checkpoint is recovered: the offending cycle and
everything after it are dropped, and the report says how many messages that
cost. With a Librarian position in the trace the recovery goes back further,
to the last turn end that a boundary line the position has counted states,
and the position moves there: the Librarian reads from a position only with
such a line (#37772). `session_id`/`turn_count` are unchanged, so the save lands as an
equal-watermark re-save through the locked validated store.

## Procedure

### Dashboard

1. Open the Keeper detail view and expand **Checkpoint & Snapshots**.
2. Select **정리 미리보기**. Preview is read-only and may run while the
   Keeper is active.
3. Stop the Keeper completely, preview again, then select **백업 후 청소**.
   Apply is unavailable while the Keeper is registered. The server takes the
   same lifecycle key used by boot, writes and reads back a byte-exact backup,
   then installs only against the exact checkpoint source reference it read.
4. Keep the displayed backup path until the Keeper completes a healthy turn.

### CLI

1. **Confirm the keeper is stopped.** `masc_keeper_list` — the keeper must
   not be `active`/`keepalive_running`. A live keeper's next save overwrites
   the purge. (`masc_keeper_down <name>` if needed; restart is an operator
   decision.)
2. **Dry-run first.** Always. The keeper's meta names the trace; pass
   `--trace <trace-id>` only to have the tool refuse when the keeper is on
   another trace. The checkpoint's own `agent_name` is the agent's runtime
   id, not the keeper, so the tool never reads it. The report shows per-rule counts and the byte
   delta; a second dry-run after an apply must show all zeros (fixpoint).

   ```sh
   masc-checkpoint-purge --keeper <keeper-name> --base <base-path>
   ```
3. **Apply.** The tool writes a byte-exact backup before saving:

   ```sh
   masc-checkpoint-purge --keeper <keeper-name> --base <base-path> --apply
   # backup: {runtime-root}/backups-checkpoint-purge-<trace>-<ts>Z/<trace>.json
   ```
4. **Verify fixpoint.** Re-run the dry-run; expect `+0.0%` and zero rule
   counts.
5. **Keep the backup** until the keeper has completed at least one healthy
   turn after restart. Rollback is a plain file copy over the canonical
   checkpoint (server stopped).

## What the tool refuses (and what to do)

| Refusal | Why | What to do |
|---|---|---|
| Keeper still registered | a live keeper's next save overwrites the purge | stop it completely, preview again |
| the Librarian has read N of M atoms | the rewrite would clear tool output and reasoning the Librarian has not absorbed | let the Librarian catch up, then purge |
| turn-boundary log or Librarian working state unreadable | which messages must stay byte-exact is unknown | repair or remove the unreadable file first |
| the Librarian working state fits the history before the purge and not after it | a recovery dropped a tail the working state covers | with the server stopped, remove `<runtime keepers dir>/<keeper>/librarian-continuity.json`, then purge; the Librarian writes it again from atom 0 |
| recovery drops the history from its structural break on, and none of the N turn-boundary lines the Librarian position has counted names an end ahead of the break | moved to an end no line states, the position would stop the Librarian for good (#37772) | leave the file untouched and record the keeper, the trace and the error in #37772 |
| structural validation fails even with its break set aside | the write boundary admitted a history recovery cannot cut back to a sound prefix (#25443) | leave the file untouched and record the trace and error in #25443 |

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
| 2026-07-29 | verifier | 510→341 msgs, 178133→154158 B (−13.5%); unstick from `request_body_too_large(262507>262144)` wedge | `backups-checkpoint-purge-trace-1785189111950-00007-20260729T161155Z` |
| 2026-07-30 | keeper-executor-agent | 585→581 msgs, 1112843→522174 B (−53.1%, tool results 904건 정리); unstick from `request_body_too_large(1049460>1048576)` + compaction suspension wedge | `backups-checkpoint-purge-trace-1785369403346-00000-20260730T074336Z` |

### Live resume after a purge (observed 2026-07-29)

`masc_keeper_down` marks the keeper operator-paused, so `…/boot` afterwards is
refused with "commit Resume_owner through the directive endpoint". The working
sequence against a local server:

```sh
KEEPER=verifier
TOKEN="$(curl -fsS http://127.0.0.1:8935/api/v1/dashboard/dev-token | jq -er '.token')"
OPERATOR_OPERATION_ID='<stable-unique-op-id>'
jq -cn \
  --arg operator_operation_id "$OPERATOR_OPERATION_ID" \
  '{action:"resume",operator_operation_id:$operator_operation_id}' |
curl -fsS -X POST -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  --data-binary @- \
  "http://127.0.0.1:8935/api/v1/keepers/$KEEPER/directive"
```

The nonce is the lane's durable owner generation and fences concurrent
operators. Read it from the typed trajectory projection instead of guessing. A
stale value fails closed and reports the current value in the error
(`expected 0, actual 1`) — refresh the projection and retry once with the same
stable operation ID; do not brute-force. A `committed` response with
`projection=committed_followup_failed` still lifts the pause; the follow-up
failure is a separate projection concern and was observed to leave the lane
cycling normally.

Known open item: user-block base64 images are outside both rules (garnet carries
2.46MB of PNG payload, 77% of its checkpoint — #25542); an image rule needs
a decision before it is added.

## Relation to the sanctioned pipeline

Purge is an explicit operator action, not an automatic runtime mechanism.
Settlement ceilings remain the normal capacity boundary (#25536, #25541,
#25544). If a purge is needed twice on
the same keeper, that is a signal the inflow paths (#25462 wake markers,
oversized tool results) are not closed — fix the inflow, do not schedule the
purge.
