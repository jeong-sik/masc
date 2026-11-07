Run `baseline-20261107T094314Z`: 2026-11-07T09:43:15Z → 2026-11-07T09:48:44Z, 3 repeats, medians over repeats.

- binary: `~/.local/bin/masc` version 0.68.0 build-commit `6afc364dd901726af020c84d491f33b139477d78` sha256 `87e13646e1e41b9785441e33b808a59bf4de8cb5b9ba2fe4a1af4e843c842ae7`
- server: owned=True listener mode `auto` h2_mode_env=None boot 1.8 s exit 0
- client: h2 4.4.1, httpcore 1.0.9, httpx 0.28.1; host macOS-27.2-arm64-arm-64bit-Mach-O arm64
- arguments: requests 600 at concurrency 100, serial 100, download concurrency 4, sse 50 streams for 32.0 s

### serial

| path | h1-6 | h1 | h2c |
|---|---|---|---|
| `/favicon.svg` p50 ms | 1.2 | 2.1 | 3.8 |
| `/favicon.svg` p99 ms | 4.6 | 15.7 | 39.1 |
| `/favicon.svg` ok | 300/300 | 300/300 | 300/300 |
| `/health` p50 ms | 6.4 | 4.4 | 7.9 |
| `/health` p99 ms | 26.8 | 33.1 | 51.0 |
| `/health` ok | 300/300 | 300/300 | 300/300 |

### burst

| path | h1-6 | h1 | h2c |
|---|---|---|---|
| `/favicon.svg` p50 ms | 199.9 | 473.3 | 234.7 |
| `/favicon.svg` p99 ms | 965.4 | 3283.6 | 419.4 |
| `/favicon.svg` req/s | 365.9 | 128.9 | 413.6 |
| `/favicon.svg` ok | 1800/1800 | 1800/1800 | 1800/1800 |
| `/health` p50 ms | 320.3 | 725.6 | 329.8 |
| `/health` p99 ms | 1325.1 | 7065.4 | 616.5 |
| `/health` req/s | 245.5 | 68.9 | 292.5 |
| `/health` ok | 1800/1800 | 1800/1800 | 1800/1800 |

### download `/dashboard/assets/index-Z7C9n29H.js` (878726 B each, 4 at once)

| | h1-6 | h1 | h2c |
|---|---|---|---|
| MB/s | 155.1 | 194.9 | 25.1 |
| wall s | 0.02 | 0.02 | 0.14 |
| ok | 12/12 | 12/12 | 12/12 |

### sse `/api/v1/stream/fleet` (50 streams held 32 s)

| | h1-6 | h1 | h2c |
|---|---|---|---|
| established | 6/50 | 50/50 | 0/50 |
| established p99 ms | 23.8 | 40.7 | — |
| frames per stream p50 | 2 | 2 | — |
| statuses | 200 | 200 | 404 |
| first error | PoolTimeout:  | — | status 404 |

