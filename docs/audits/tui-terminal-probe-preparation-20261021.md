# Owned terminal probe preparation

| Boundary | As-Is | To-Be in source |
|---|---|---|
| Authoritative startup settings | Applied before terminal ownership/query/key handling | Same; no temporary settings or late preference overwrite |
| Probe collection | Caller joins collector before remaining initialization/loop entry | Original switch-owned child collects while caller can finish initialization and enter loop |
| Pending stdin/buffer owner | Collector only while caller waits | Collector only; normal input/readiness cannot consume its buffer/replay |
| Waiting input consumer | Ordinary key wait after joined probe | Pending wait races the original future with the caller's existing render deadline |
| Handoff | Immediate original decoder installation after join | Owning loop polls without waiting, installs that exact decoder, publishes current capabilities, then permits normal input |
| First frame dependency | Loop/frame eligibility follows collection | No collection join before loop/frame eligibility; actual paint remains unverified |
| Missing/failed start | Capture created inside synchronous adapter | Original capture reserved before scheduling, scheduling failure/interruption retained without invented worker success |

Selected startup audit confirmed that the original settings promise still
precedes terminal ownership and input. The settings loader already reads the
file once through two owning parsers; duplicating that work was not the issue.
This leaf preserves authoritative settings and removes the independent terminal
collection join after them. It does not make input usable through an indefinitely
blocked settings read, solve a measured live Loading cause or close other axes.

Only the original producer touches the mutable read buffer during preparation.
Normal readiness reports no consumable input until owning-loop installation;
normal input waits only on the future or its existing render deadline, without
reading stdin or spinning. Deadline/caller cancellation withdraws that wait, not
the original producer. The root switch still owns the child and physical I/O
settlement. Polling a returned error propagates it; success installs the original
decoder before publication/input. Direct installation during production is a
programming error, as is preparing the same reader twice. These guards do not
pick behavior from error strings, request names or numeric heuristics.

Existing query bytes and their ordering after saved theme/page setup remain.
The collector keeps original early-input/replies/deadline/byte-cap behavior.
No bytes are finished, copied into a replacement reader or replayed into another
request. UTF-8, split OSC/CSI and bracketed paste continue through the same
buffer/decoder. Late palette/theme/graphics/geometry publication stays on the
owning UI path and requests the existing repaint. Before capabilities arrive,
existing unknown/default terminal-capability state remains unobserved, not proof
of refusal. Saved configuration has already been applied before any frame.

A supplied switch is checked. Without a switch or clock, the existing synchronous
collector/installation path remains explicit. Scheduling errors are original
failed/interrupted caller observations; worker entry/result/install are not
fabricated. Capture reservation before scheduling preserves known attempts even
when no child enters. Existing startup observation schema and offline reader
are reused. The adapter's returned-to-caller fact now belongs to the child;
loop installation is a later distinct boundary. Neither is paint/Task success.

Costs: one Eio child/future and retained wait closure per normal startup, owner
checks on input/readiness, and nonblocking future inspection per loop while
pending. Pending input waits replace normal readiness/deadline races with a
future/deadline race using the same caller timeout. There is no additional
persistent timer, retry, pool, backend, cadence or changed capture limit. The
existing system-thread collector and physical cleanup remain. Early frames may
use capability state that is still unobserved; late original publication repaints.
Other initialization or pool contention may prevent useful overlap. No measured
latency, CPU, first-paint or input improvement is claimed.

One new actual protocol/resource case uses a real pipe with the production
system-thread collector and input decoder. It withdraws a consumer wait, then
supplies original palette, UTF-8, late background/graphics/geometry and bracketed
paste bytes. The same producer must hand its buffer/decoder to the owning loop;
pending readiness cannot steal bytes; original input/paste and late observations
must survive, while a retained earlier observation stays immutable. It does not
start a terminal/PTY, render frames, assert helper invocation counts or set timing
thresholds. The case is authored and unexecuted. Direct Dune dependencies for its
Eio/context/Unix/paste consumers are declared.

Validation: parsing only for four ML/MLI files, interface first, and source/diff
inspection. No local build/typecheck/test, Python consumer/import/CLI/report,
CI dispatch/watch/poll, native/model/controller/audio/PTY execution, install/
restart/live write, agents, approval or merge. All six original axes and actual
matched Before/After remain open. Comparisons must retain failed, cancelled,
unstarted, unfinished and unobserved attempts and count new preparation/wait/
observation overhead; source eligibility is not actual visible readiness.
