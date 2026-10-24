# SDK session ends with its owner IPC

The earlier real-server cleanup left the old candidate's SDK process alive
after server SIGTERM. Source inspection found a separate, reproducible IPC
lifetime defect: the session loop only set closed/woke its receive loop. That
cannot interrupt the async script it is awaiting, and its existing queue could
run another script after the owner disconnected.

The production loop now uses one idempotent handler for socket end, close and
error. Owner loss exits only that SDK Node process. It does not finish a task
space, close Ego's GUI, run another queued script, or add a command timer.
Browser effects already dispatched remain unknown; they cannot be undone by
exiting. This requires a responsive Node event loop and is not a universal
interrupt for synchronous CPU work. Process exit also skips async SDK disposal;
this is the lost-owner path, not normal task-space cleanup.

## Actual installed CLI experiment

`scripts/check-ego-session-owner-loss.py` compiles the actual session_loop
function extracted from the production OCaml file, then gives that emitted
script to Node or `ego-browser nodejs`. No TaskSpace or Page API is invoked.
SDK-like persistent handles and pending calls are deliberately simulated inside
the real SDK evaluator. The probe's observation/cleanup windows are test bounds,
not production execution limits.

[before-results.json](before-results.json) binds the reproduction to the full
source file at c040e5cf6487e5f4e7842e7e1bc869cfb2ea037b by SHA256. After owner loss,
all five processes remained running at observation, and the queued-script case
wrote its late-effect marker. Each owned probe was then explicitly terminated.
The live-owner control call had answered normally before its owner disconnected.

[fixed-results.json](fixed-results.json) binds the corrected source and extracted
function hashes. Installed Ego0.6.0.20 exited all five processes with status0
following owner loss. No queued late-effect marker was written. The live-owner
pending call still answered before disconnection. Cases include idle persistent
handles, pending async work, a buffered next script, owner half-close and the
live-owner control. All ten recorded probe PIDs were confirmed absent afterward.

This proves the production loop in the installed SDK evaluator. It does not
claim a rebuilt full server's SIGTERM path yet. That integration result must be
bound separately to its candidate binary. Existing long native-workflow and
navigation results retain their earlier sources; this change adds no lifetime
budget and does not replay those tasks.
