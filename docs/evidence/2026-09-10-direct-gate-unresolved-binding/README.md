# Preserve unresolved Gate source identities

Gate source lookup ran before the checkpoint-failure recovery boundary. An unavailable approval store therefore returned an ordinary runtime error and could clear a fresh operation's original input. The same recovery path also lacked a place to retain the frozen runtime suffix without fabricating a checkpoint.

The semantic journal now has a typed Gate-binding recovery origin. It records producer-issued approval IDs, already-bound obligations and the frozen runtime suffix separately from checkpoint authority. The existing transaction retains the complete original operation input and queues it in a nonclaimable state. Both source lookup and checkpoint preparation run inside that preservation boundary. Owner and stream delivery keep the request nonterminal.

A later approval alone cannot authorize replay from an unknown checkpoint. This representation deliberately requires an actual reconciliation witness before resuming. It does not declare the task complete, retry full original input, or invent successful source binding.

Added production-fixture scenarios expose the approval store's unavailable state after its real Gate producer has created a request, and fail checkpoint retention while a frozen runtime suffix exists. The restart test retains unbound approval IDs, the suffix, full task input, attachments and channel without making a model claim. Source parsing and diff checks passed; no local build. CI, review and installed-runtime closure are pending.
