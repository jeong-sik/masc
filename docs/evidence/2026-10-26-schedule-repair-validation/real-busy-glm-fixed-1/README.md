Independent raw-artifact review of `real-busy-glm-fixed-1` supports the measured checkpoint-retention and resumed-effect flow on GLM: the first exact scheduled source checkpoints without ACK, the second source completes and ACKs, the first source is readmitted, its requested note is written then, and the first source finally completes and ACKs. All 11 original observer checks pass, both exact requested notes exist once with the correct author/body, the final recorded live turn is idle, and the owned producer's recorded return code is 0.

The executable's actual SHA-256 is `a0bd5c3903ef6425024e47b9dc92a7615f4efbb941357ea36e74ac5a18284668`, matching the measured binary provenance for product head `94b2df25abcdfe20c658322f4156ad63f5546c34`. The observer checkout is separately `e883ccc0ad91ff0ab8dcab60837aee6290eb7a88`. The recorded v3 observer script digest matches the actual file digest `6ef94873203553b493c5b0d586070fc124f25d945028cab298f2f2dd5275eeff`. This run uses one owned Keeper, `audit-live-glm`, and runtime `glm-coding.glm-5-3` at the configured Z.ai coding endpoint.

The complete original reaction ledger contains 10 rows in this order:

| Event | Server-recorded Unix time |
|---|---:|
| First source starts | 1793026414.216670 |
| Second source arrives / stimulus recorded | 1793026416.955177 / 1793026416.962435 |
| First source checkpoints | 1793026426.969500 |
| Second source starts | 1793026426.973945 |
| Second note stored | 1793026453.873366 |
| Second source completes / ACK | 1793026504.780132 / 1793026504.780172 |
| First source is admitted again | 1793026504.785894 |
| First note stored | 1793026524.847097 |
| First source completes / ACK | 1793026550.904917 / 1793026550.904953 |

Both the sampled `overlap.json` and the full ledger establish arrival of the second exact request during the first unfinished turn. The complete ledger has exactly one first-source ACK, after its final completion, and none at checkpoint or before second-source completion. First-source readmission follows the second ACK, rather than interrupting the second source. Selected server log lines show yielding to the durable stimulus after one model turn and checkpoint resume counts 0, 1 and 8.

Effect attribution is stronger here than in the separate DeepSeek fixed-1 run. The second note-add receipt has `keeper_turn_id=2`, tool turn 3, and creates note id 10. The first note-add receipt has `keeper_turn_id=3`, tool turn 9, and creates note id 11 after the first source's readmission. Its pre-write notes-list receipt found no note, and its later note-list receipts confirm the same stored note. Both write outputs, note-list readbacks, final observer readbacks and durable schedule ledger agree on the exact public schedule ids, marker bodies and Keeper author. The complete tool-call ledger has exactly two note-add calls; its 13 recorded calls have `wire_outcome=ok`. This describes these retained calls, not a guarantee about future calls or arbitrary effects.

Exact occurrence/post id, schedule-instance id, due time and payload digest were compared between final schedule projections and the terminal ACK payloads. Final queue pending/outbox counts are zero, both exact sources project `matched_terminal_completed` with `matched_consumed_ack`, and the owner has no live turn. The first-source API reaction summary alone retains the checkpoint's earlier finish timestamp, so this review preserves and uses every original ledger row, including repeated start/finish event ids, to reconstruct final completion.

`process-ended.json` records producer return code 0 after the required effects and durable completions. The server log records SIGTERM and shutdown completion. This is normal termination of this owned run; no process restart or crash recovery occurred. All original observer checks remain unchanged. No independent numeric observer exit-code record is invented from the producer return code.

Selected reactions retain exact causal identities and terminal receipt fields while omitting payload messages. Selected note receipts preserve exact input/output with execution, trace and turn bindings. Original input hashes were unchanged across this review. No thinking, credential, auth file or control-token values are copied. The reviewer issued no runtime/API request, process operation, build, CI action or source change. The evidence establishes these two owned note effects and queue settlement on this GLM run. It does not establish arbitrary-effect exactly-once execution, account failover, external delivery, full scheduling-feature correctness, after-effect checkpointing, restart recovery, or successful behavior on providers that were not run.
