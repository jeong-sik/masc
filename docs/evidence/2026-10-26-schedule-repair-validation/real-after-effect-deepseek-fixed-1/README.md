Independent raw-artifact review of `real-after-effect-deepseek-fixed-1` confirms the v3 observer's 11 recorded checks all pass, the observed overlap is present, each exact requested note exists once with the correct Keeper author/body, both exact sources have durable Completed/ACK evidence, the final recorded live turn is idle, and the owned server's recorded return code is 0. This proves the measured after-effect busy-queue flow for this run. It does not prove an after-effect checkpoint/readmission sequence: the complete original ledger contains no checkpoint or first-source readmission.

The measured executable is product head `94b2df25abcdfe20c658322f4156ad63f5546c34` with SHA-256 `a0bd5c3903ef6425024e47b9dc92a7615f4efbb941357ea36e74ac5a18284668`. The actual file digest matches the raw provenance and measured build identity. The v3 observer script digest matches `6ef94873203553b493c5b0d586070fc124f25d945028cab298f2f2dd5275eeff`; the observer checkout remains separately `e883ccc0ad91ff0ab8dcab60837aee6290eb7a88`. This is one owned Keeper using `ollama_cloud.ollama-cloud-deepseek-v4-1-flash`.

The complete original reaction ledger contains 8 rows, preserving this causal order:

| Event | Server-recorded Unix time |
|---|---:|
| First source starts | 1793026382.944305 |
| First note stored | 1793026417.467048 |
| Second source arrives / stimulus recorded | 1793026420.201364 / 1793026420.225260 |
| First source completes / ACK | 1793026421.589550 / 1793026421.589584 |
| Second source starts | 1793026421.598716 |
| Second note stored | 1793026424.535058 |
| Second source completes / ACK | 1793026427.590824 / 1793026427.590862 |

`overlap.json` independently records both exact occurrences in the pending bucket, with first-source `turn_started_seen=true`, `turn_finished_seen=false`, `event_queue_ack_seen=false`, and second-source not yet started. Thus the second request arrived after the first durable effect while the first turn remained unfinished. The first request then completed normally and ACKed before the second source began. Server log resume counts 0 and 7 are continuation snapshots; they do not establish that the first source yielded or was readmitted. No `yielded_to_durable_stimulus` or checkpoint disposition appears in this run's complete ledger/log evidence.

The first successful note-add receipt belongs to `keeper_turn_id=1`, tool turn 4, with durable note id 6. The second belongs to `keeper_turn_id=2`, tool turn 8, with durable note id 11. Both write outputs, subsequent exact note-list readbacks, final observer readbacks and the durable schedule ledger agree on the respective public schedule ids, exact marker bodies and author `audit-live-deepseek`. The complete tool-call ledger contains exactly two note-add calls. Exact occurrence/post id, schedule-instance id, due time and payload digest match the ACK payloads and the final terminal projections. There is one ACK per source. Final queue pending/outbox counts are zero.

The raw tool-call ledger also records an `Execute` error before the first note was written: `ls -la .` was refused with typed `github_identity_snapshot_unavailable` and no observed shim execution receipt. This does not negate the later note-effect checks; it prevents describing the run as every tool call succeeding or proving guest command execution. Only the selected typed failure summary is retained here.

The server received SIGTERM after terminal/effect observation, logged shutdown completion, and `process-ended.json` records return code 0. This is normal producer termination for this run, not restart or crash-recovery evidence. The observer's original 11 checks remain unchanged. The paired earlier fixed-1 run supplies checkpoint-retention/readmission evidence with its own observer failure and exit-status limitations; those are separate runs and cannot be combined into a single after-effect checkpoint PASS.

This review issued no runtime/API requests, process actions, builds, CI operations or source changes. Selected receipts preserve exact note IO and causal execution fields; reaction receipts select exact identities and typed terminal facts, omitting payload messages and unrelated content. Original input hashes were unchanged across the review. No thinking, credential, auth file or control-token values are copied into this derivative. The supported scope is these two owned durable notes and exact queue settlement on one provider. Arbitrary-effect exactly-once execution, another provider, external delivery, account failover, full scheduling-feature correctness and after-effect checkpoint/restart behavior remain outside this evidence.
