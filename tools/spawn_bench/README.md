# spawn_bench

Measures the wall time of starting `/usr/bin/true` with a large live heap, once
through eio_posix's fork-based process manager and once through
`Posix_spawn_process_mgr`.

```
dune exec tools/spawn_bench/spawn_bench.exe -- 1500 20
```

The first argument is the live heap to hold in MB, the second the number of
spawns per manager. 2026-09-05 on an M3 Max with 1,515 MB live:

| manager | p50 | p90 | max |
|---|---|---|---|
| fork (eio_posix) | 43.7 ms | 47.3 ms | 75.6 ms |
| posix_spawn | 1.2 ms | 1.3 ms | 1.4 ms |

The live server measured higher per fork (about 141 ms in stack samples) because
its malloc state is larger than this bench's; the ratio is what the bench shows.
