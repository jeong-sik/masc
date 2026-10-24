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

This proves the production loop in the installed SDK evaluator. Existing long
native-workflow and navigation results retain their earlier sources; this change
adds no lifetime budget and does not replay those tasks.

## Compiled host integration

[host-34cbedbe](host-34cbedbe/) records two isolated server/worker/SDK runs using
candidate `34cbedbe5746855db9033921f4b0c9365f1fbbb6`. Its three binaries match the
[successful macOS build](https://github.com/jeong-sik/masc/actions/runs/40110786294)
receipt. The [focused live-Ego suite](https://github.com/jeong-sik/masc/actions/runs/40110779108)
also completed successfully for that source. Neither result validates later
shared-client policy changes.

Each phase records the embedded source, executable hashes and effective private
root through full health, then captures server-to-worker-to-SDK parentage and
process birth times. No Keeper/model task or form submission ran. The ordinary
browser-client snapshot starts the configured SDK and owns the task space.

- Worker loss: SIGKILL only the captured worker. Its SDK disappeared within
  0.0652 seconds of observation without a manual SDK signal. The server was then
  stopped with SIGTERM; its original server, worker and SDK were all absent.
- Server shutdown: a fresh private server resumed the same agent-owned space28.
  SIGTERM only that captured server. The server, worker and SDK were all absent
  after shutdown, without a separate manual SDK signal. This is an idle native
  session proof; it does not simulate uninterruptible JavaScript CPU work.
- The final actual TaskSpace list contains no space named
  `masc-ego-owner-loss-20261025`; normal shutdown removed it. No extra finish call
  was needed. Production binaries, runtime state and other spaces were untouched.

[scope.json](host-34cbedbe/scope.json) records that the two owner-related source
files are unchanged between the executed34c candidate and source12c001e. The new
shared-client transport cache is outside this binary proof. Its focused run
[40112787489](https://github.com/jeong-sik/masc/actions/runs/40112787489) completed
successfully on source12c: actual client4, reply-policy1 and lane14 tests
(19 total; [receipt](current-client-policy-ci.json)). This compiles and exercises
the new socket boundary. These observations establish the scoped owner-loss
repair, not full regression, release, installation or all browser behavior.


## Current shared-client policy: actual Keeper on12c

[keeper-12c001e5](keeper-12c001e5/) binds the new metadata/routing integration to
source `12c001e55e27c7a9340ae27f956e112fd5360c76` and successful macOS build
[40113070920](https://github.com/jeong-sik/masc/actions/runs/40113070920).
All three downloaded binary hashes were checked; embedded full health, effective
private root and live server/worker hashes match its receipt. Later source
commits add documentation/evidence only.

A real `glm-coding.glm-5.3-flash` Keeper executed the original operation
`ego-native-proof-12c-policy-1` and reached `Succeeded`. The nine retained tool
completions include ordinary BrowserGoto, ordinary BrowserAct reload, native
snapshot, ordinary BrowserInteract `target.ref=1` click and a final native
snapshot. They retain one observed client and tab1 in actual space30/p1; no
workflow substitutes for these ordinary calls. One BrowserRead omitted its
browser binding and was refused before dispatch; the same operation recovered
with the observed binding. That failure is preserved.

The fresh local application recorded exactly one confirmation click. The final
native snapshot, title and independently captured/visually inspected screenshot
all show `네이티브 연결 검증 완료`. This was a new single-click test application,
not another delivery form submission. The provider record contains run identity
and model metadata only; raw reasoning, credentials and private event streams
are excluded. Browser inputs/results and their source file/line/hash provenance
are retained. The screenshot is the reviewer's SDK capture, not a Keeper image.

This short run proves the actual current client metadata/caller path, not a new
long-duration result. The current-source Unix-socket tests separately prove
SDK-owned calls outlive the transport window and other routes stay bounded.
The earlier130.14-second original-caller result remains bound to14c9, and
navigation evidence remains bound to a96.

Normal Keeper/server shutdown ended the matched server/worker/SDK without an
extra SDK signal. The owned fixture was then stopped. All four captured PIDs
are absent; the final actual TaskSpace list shows the owned space30 absent,
without a second finish request. Production binaries/state were not changed.
No full regression, merge, installation or release claim is made.
