# Performance and soak harnesses

## Main-domain scheduler lag: one server, three readings

`scheduler_lag_probe.sh` attaches to a running server (`MASC_URL`) and prints
`/health` latency percentiles, the server's own scheduler-lag ring
(`/health` `.scheduler`: how late a ready fiber on the main domain ran over the
last minute, with the count of samples at or above one second), and GC rates
computed from two `/health` readings (`.gc`: collections per minute,
allocation MB/s, heap and live size). It builds nothing and boots nothing.

It is the before/after instrument for
`docs/rfc/RFC-main-domain-scheduler-latency.md`: run it against the current
binary, deploy, run it again, paste both readings into the PR. It has no
threshold on purpose — a gate needs the baseline this script produces first.

## Inside the domains: runtime-events consumers

`scheduler_lag_probe.sh` says how late the main domain ran; it cannot say
why. `tools/rtev_trace/` holds two programs that attach to the runtime-events
ring masc opens at boot and read what each domain was doing: `rtev_watch`
for GC phases, counters and which domain reached each stop-the-world barrier
last, `rtev_fibers` for how long each fiber ran between suspends and what it
resumed from and suspended on. Run them in the same window as the probe;
the readings in RFC-main-domain-scheduler-latency section 8.7 were taken
that way.
