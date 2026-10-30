Independent raw-artifact review of `real-busy-deepseek-fixed-1` supports the narrow runtime behavior: the first scheduled source survives a checkpoint without premature terminal ACK, the second source completes, the first source is admitted again and completes, both requested durable notes exist once with the exact author/body, and the last recorded owner turn is idle. The original v2 observer run remains failed: 9 checks passed, `busy-overlap precondition was observed` failed, and observer exit was 1. This derivative does not rewrite that result or label the full observer run PASS.

The measured executable SHA-256 is `a0bd5c3903ef6425024e47b9dc92a7615f4efbb941357ea36e74ac5a18284668`, matching both the file and the self-observed binary provenance for product head `94b2df25abcdfe20c658322f4156ad63f5546c34`. The observer checkout is separately `e883ccc0ad91ff0ab8dcab60837aee6290eb7a88`. The measured v2 observer script digest matches the recorded provenance. The provider/runtime is `ollama_cloud.ollama-cloud-deepseek-v4-1-flash` at the configured Ollama Cloud endpoint; this is one provider and one owned Keeper.

The complete original reaction ledger has 10 rows. Exact occurrence/post, public schedule id, schedule-instance id, due time and payload digest were matched between the terminal ACK payloads and the final schedule projections. The causal order is:

| Event | Server-recorded Unix time |
|---|---:|
| First source starts | 1793026196.287609 |
| Second source arrives / stimulus recorded | 1793026198.997092 / 1793026199.010688 |
| First source finishes this attempt as checkpointed | 1793026199.053084 |
| Second source starts | 1793026199.056644 |
| Second note stored | 1793026203.477594 |
| First note stored | 1793026212.254440 |
| Second source completes / ACK | 1793026215.712960 / 1793026215.712989 |
| First source is admitted again | 1793026215.719052 |
| First source completes / ACK | 1793026218.389438 / 1793026218.389485 |

The durable ledger supplies additional overlap evidence that the sampled observer did not capture: the second stimulus row precedes the first checkpoint row by 42.396 ms; its arrival precedes that checkpoint by 55.992 ms. There is exactly one first-source ACK in the complete original ledger, after its final completion. There is no first-source ACK between checkpoint and second-source completion. The first source does not start again before the second source has completed and ACKed. Selected server log lines independently show yielding to the durable stimulus, then checkpoint resume counts 2 and 12.

Effect attribution matters: both successful `masc_schedule_note_add` receipts have `keeper_turn_id=2` (tool turns 4 and 9). The first request's note was written during the continuation admitted for the second source, before the first source's later readmission. This run therefore does not prove that the readmitted first-source turn newly performed its note write. It demonstrates that the retained conversation handled both requests, that both exact requested effects were present once, and that the first source remained nonterminal until its own later admission/completion. The two write receipts, subsequent exact note-list readbacks, final durable schedule ledger and observer readbacks agree on note ids 10 and 11, their respective public schedule ids, exact marker bodies and author `audit-live-deepseek`. The complete tool-call ledger contains exactly those two note-add calls.

Final recorded state has zero queue pending entries, zero transition outbox entries, both exact sources projected as `matched_terminal_completed` with `matched_consumed_ack`, and no live owner turn. The API's first-source reaction summary retains the earlier checkpoint's `turn_finished_recorded_at`; it is insufficient by itself to reconstruct the final attempt. The complete raw ledger preserves both starts and both finishes, which this review uses without deduplicating repeated event ids.

Shutdown was requested after the observer failed and after the terminal/idle reread. The shutdown record has `observer_exit_code=1` and `exit_code=null`; the server log later records shutdown completion, but the producer's numeric exit status is unavailable. No clean exit or restart proof is claimed.

The accompanying selected JSON receipts omit unrelated tool calls, payload messages, thinking, auth credentials and control tokens. `provenance.json` records each original input's digest and the exact field-selection transformations. Original checks and raw files were unchanged during review. This is static verification of retained actual-run evidence; the reviewer issued no runtime/API requests, builds, CI actions or process operations. It does not establish arbitrary-effect exactly-once execution, other-provider behavior, crash recovery, account failover, external delivery, full scheduling-feature correctness or an overall test PASS.
