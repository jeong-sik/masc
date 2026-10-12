# Pending input execution-source authority

Base5304b7f68fd44578cff09c347841b31ad8059660.

keeper_message_waiting_requests built its started-execution set from raw string
turn_log_execution_id. A retained started Autonomous_turn whose display ID
matches a direct Operation could therefore retire that direct pending input.
This cross-source collision remains possible even after #42586/#42588 correctly
distinguished persistence from execution start.

Reuse the existing execution_source_key and turn_log_execution_source_key for
both set insertion and membership. Operation keys include the batch execution
ID; autonomous keys retain typed trace ID + absolute turn. No parsing heuristic,
new display ID, source conversion, or new execution grouping authority added.
The same operation's sibling start still retires pending; other sources do not.

Direct bounded probe /tmp/masc-pending-start-source-20261012/{probe.py,parent.ml,current.ml,parent.log,current.log}.
Actual complete waiting-request function, source-key declarations and source
helpers interpreted. Minimal state/log/transcript/queue accessor doubles and
Turn_ref tuple/accessors, no real HTTP/journal/reducer/render or ID parser.
Probe uses the minimal type scaffold from prior saved persisted-input probe;
these dependencies are explicit, not a standalone production test runner.
Parent exit2: autonomous source consumed same-text direct input.
Current exit0: collision retains pending; same typed operation retires pending;
unrelated operation retains it. Registered fixture also adds typed source/state
controls but is unexecuted; checks concern requests/delivery, not UI layout.

Production/fixture syntax-only parse and diff check pass. No full typecheck,
build/CI/provider/runtime/UI/screenshots/installation/formal approval or merge
proof. Full thinking/speech/tool/interleaving/broadcast/async goal remains active.
