# Large retained-request hashing and scheduler responsiveness

## Observed failure

On 2026-10-22, a running server had a 971,857,237-byte Curator original-owner
record open. A two-second process sample showed its worker in Digestif's
`sha256_do_chunk`, while the main thread waited to reacquire the OCaml domain
lock after a filesystem call. An independently measured `/health` request took
15.967 seconds; subsequent Keeper and question reads took 70 and 34 milliseconds.
These observations establish intermittent shared stalls, not a permanently slow
Keeper endpoint or sole causality for every loading delay.

The [OCaml 5.5 C interface manual](https://ocaml.org/manual/5.5/intfc.html)
describes the domain lock and its interaction with C calls and system threads.
Moving work to a system thread alone does not make a long C feed release that
lock. `Lane_addon_store.digest` now feeds all original bytes to the same SHA-256
implementation in 64 KiB slices. This is an internal buffer size, not an input
limit. It permits system-thread scheduling between feeds; it introduces neither
an Eio suspension nor a cancellation checkpoint.

## Direct mechanism measurement

A standalone OCaml 5.5.1 native probe compared the old expression with the exact
new `digest_feed_bytes` and `digest` definitions copied from production source.
It used `threads`, `unix`, and `digestif.c`, a 128 MiB binary string
(`Char.chr (index mod 251)`), a hashing system thread, and a 1 ms main-thread
heartbeat. Each pair ran sequentially on the same process and input.
No repository Dune build or server executable was involved.

| Pair | Old maximum heartbeat gap (ms) | New maximum gap (ms) | Old hash time (ms) | New hash time (ms) |
| --- | ---: | ---: | ---: | ---: |
| 1 | 474.737 | 62.726 | 473.917 | 685.290 |
| 2 | 555.743 | 54.921 | 555.516 | 585.355 |
| 3 | 618.746 | 55.076 | 617.794 | 498.671 |

All six hashes were
`018d3c1e36e90f96662e9f84e5375d72fb9612bf320e0fea9d7dda2549bc1730`.
The extracted candidate definitions had SHA-256
`e9deb9f55e7d5baa940e009eec7fbbf6f98d4c0a5d53828da5524350d0eeac3c`.
The median heartbeat gap fell from 555.743 to 55.076 ms in this experiment.
Hash duration did not consistently improve; this is not a throughput claim or
a fixed latency guarantee. The remaining gap includes system-thread scheduling.

## Evidence boundaries and next checks

The existing evidence-store suite now exercises write/read round trips and
standard SHA-256 addresses for empty, binary, below-feed, exact-feed, and
multiple-feed inputs (0, 65,535, 65,536, and 131,089 bytes; the last case is both
binary and multiple-feed). These assertions were authored, not executed in this
coding session. Changed OCaml files passed parsing and `git diff --check`.

The standalone probe compiled and ran the extracted function, not the complete
Store module or its callers. Native integration, cancellation ownership, retained
request size, GC pressure, and installed TUI/Dashboard/API latency remain separate
checks. Retained requests were neither truncated nor removed by this change.
