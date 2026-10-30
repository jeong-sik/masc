# rtev_trace: what the live server's domains are doing

Two consumers of the OCaml runtime-events ring that masc opens at boot
(`Masc_runtime_events.start_listener`, on unless `MASC_RUNTIME_EVENTS=false`).
They attach to a running process and read; the server is not touched.

The ring is `<pid>.events` in the directory the server started in
(`OCAML_RUNTIME_EVENTS_DIR` when set). Find the pid with
`pgrep -f 'main_eio.exe.*8935'`; a restart changes it and a cursor on the
old file fails.

```
dune exec tools/rtev_trace/rtev_watch.exe  -- <dir> <pid> <seconds>
dune exec tools/rtev_trace/rtev_fibers.exe -- <dir> <pid> <seconds>
```

Both drain the ring's backlog first, so the window starts when the command
starts.

`rtev_watch` reports every GC phase (count, per second, total, mean, p50,
p99, max) aggregated over domains and per domain, the runtime counters per
domain, and for each stop-the-world section which domain reached the
barrier last and how late. `stw_handler` is what every domain pays per
STW; `stw_api_barrier` is the leader waiting for the others.

`rtev_fibers` uses the events Eio emits on fiber switches and suspends. Per
domain it reports how many fiber runs happened, how much of the window
they covered, how many ran 10/50/100 ms or longer without giving the
scheduler back, and the longest ones with the operation the fiber resumed
from, the one it suspended on (an empty reason is `Fiber.yield`; a file
operation names its file, `fs-compat-append-file chat.jsonl`, so a run
between two of them is placed without further instrumentation), the GC
time inside the run, and how many `masc.turn` spans were open on that
domain. Each long run also prints the fiber's ancestry: the cancellation
context it was forked in (kind and name when the switch was named) and the
fiber that created that context, up to six levels, so a loop that shows up
only as `fstat -> fstat` can be traced to the code that forked it. A fiber
that opens a named switch (`Eio.Switch.run ~name`) is labelled by the first
name it opened in the window, and by `first > newest` when Eio's own named
switches (`with_open_in`, `both`, `Buf_write.with_flow`, ...) came later;
masc names its maintenance loops per iteration, each keeper cycle and each
HTTP connection this way, so a tracer attached at any time sees them. Two further sections list the
longest runs on domain 0 alone and group its runs of 10 ms or more by label
and open `masc.turn` depth. Domain 0 is the main domain; a run there of 100 ms is 100 ms of
scheduler lag for every other fiber on it.

`rtev_fibers` also reads the traced sections Eio reports for
`Eio.Private.Trace.with_span`; masc opens one per pool job, named after the
submitting function (RFC-0474 L4c). For each section it counts the time the
section's fibers ran, including fibers created inside it, and the time they
spent suspended, by suspend reason. Sections nest, and an outer section also
counts the time spent in the sections inside it. Both numbers are sums over
the section's fibers, not a split of its wall time: a job whose fibers run
at the same time on several domains, or whose parent waits while a child
waits on something else, counts the same stretch of wall time more than once,
so a run or wait can exceed the wall time and `run%` can pass 100. For a job
that runs one fiber at a time the sums split the wall time into computing
and waiting, and into what it waited on. Sections are grouped by name and
the longest are listed.

It also reads the lock events Eio emits (`Try_get`, `Get`, `Put`). Mutexes
are created at module initialisation, before the tracer attaches, so a lock
is known by its object id only. For the locks fibers waited on longest it
lists who waited and who held them, by section, the longest holds with what
the holder suspended on while holding, and what holders suspended on just
before taking and just after releasing the lock. A holder that suspends on a
file stat keeps every waiter behind that stat; the file operations around
the critical section place an unnamed lock in the code.

Numbers from these tools are recorded in
`docs/rfc/RFC-main-domain-scheduler-latency.md` section 8.7.
