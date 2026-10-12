# Persisted input still awaits execution

Base ca0bb173b3812a53d998d31fde822dbecf1c37cb.

server_routes_http_keeper_stream.append_queued_user_row_once persists input as
part of operation_prepare before execution. TUI keeper_message_waiting_requests
nonetheless removed a pending request whenever a persisted user row existed.
History refresh during queue wait could therefore remove its delivery state
without observing its execution begin. Persistence proves storage, not consumption.

Remove this persisted_user predicate. The existing same-execution Run_started
set, transcript phase and continuation policy still decide pending retirement.
A sibling batch watcher can prove the same bound execution started; unrelated
execution starts do not. Stored queued inputs retain Keeper_queued, and an
unconfirmed reconnect retains Rechecking_delivery. No speech/body change added.

Direct bounded probe: /tmp/masc-persisted-input-awaits-start-20261012/{probe.py,parent.ml,current.ml,parent.log,current.log}.
Actual complete keeper_message_waiting_requests function interpreted with minimal
state/record declarations and explicit transcript/log/queue accessor doubles.
No real journal/reducer/queue transition, HTTP dispatch or renderer executed.
Empty local queue; same_request_identity fail-fast sentinel is not reached.
Parent exit2: persisted queue input lost pending delivery before execution.
Current exit0: persisted queued/rechecking input retained; same bound execution
start retires pending; other execution start retains pending. These are request
and delivery decisions, not wording/layout/row-order assertions.

Existing registered fixture extended with persisted row + pending-request
assertion, unexecuted. Production and fixture syntax-only parsing plus diff
check pass. Server persistence ordering source-traced, not runtime measured.
No full typecheck/build/CI/runtime/UI/screenshots/installation/formal approval
or merge proof. Full interleaving/broadcast/async/provider goal remains active.
