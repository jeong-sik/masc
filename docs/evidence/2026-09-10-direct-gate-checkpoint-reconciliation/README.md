# Gate checkpoint retention failure

A fresh direct operation could create a durable Gate request, then fail to retain its checkpoint. Returning an ordinary runtime failure cleared the request input despite the outstanding effect. This repair atomically retains the original input and typed Gate obligations in the existing semantic `Recovering/Interrupted_execution` state and leaves the same operation queued but nonclaimable. Owner completion and stream persistence treat that state as nonterminal.

A durable approval does not prove the missing checkpoint. It cannot make this operation claimable or restart the model from the full original input. Independent work remains runnable. A future reconciliation must supply an actual checkpoint/effect witness; no automatic recovery witness is invented here.

Added cases cover a real retention destination failure in the Gate producer/Owner fixture, and SQLite restart with original task/channel/attachments and exact approval identity retained. The latter also checks that approval cannot manufacture a checkpoint and independent work is claimable. Source parsing and diff checks passed; no local build. CI and deployed behavior remain separate pending evidence.
