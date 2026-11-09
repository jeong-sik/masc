Run `20261108T232900Z`: 2026-11-08T23:29:01Z → 2026-11-08T23:38:55Z, 3 repeats, medians over repeats.

- binary: `~/.local/bin/masc` version 0.69.0 build-commit `9c7452c0e2086d3c1b557cba9f7e649089bf86d7` sha256 `f6e3db697c5816f030359c3b926638c3576ff2f10bbc0db1a833dd6aef646c3a`
- server: owned=True listener mode `auto` h2_mode_env=None boot 0.9 s exit 0
- client: h2 4.4.1, httpcore 1.0.9, httpx 0.28.1; host macOS-27.2-arm64-arm-64bit-Mach-O arm64
- arguments: requests 600 at concurrency 100, serial 100, download concurrency 4, sse 50 streams for 32.0 s

### serial

| path | h1-6 | h1 | h2c | tls-h1 | tls-h2 |
|---|---|---|---|---|---|
| `/favicon.svg` p50 ms | 1.0 | 0.7 | 0.9 | 0.8 | 1.3 |
| `/favicon.svg` p99 ms | 2.8 | 3.0 | 1.6 | 5.1 | 2.2 |
| `/favicon.svg` ok | 300/300 | 300/300 | 300/300 | 300/300 | 300/300 |
| `/health` p50 ms | 1.8 | 1.4 | 2.1 | 2.0 | 2.3 |
| `/health` p99 ms | 3.9 | 9.6 | 2.8 | 6.5 | 3.0 |
| `/health` ok | 300/300 | 300/300 | 300/300 | 300/300 | 300/300 |

### burst

| path | h1-6 | h1 | h2c | tls-h1 | tls-h2 |
|---|---|---|---|---|---|
| `/favicon.svg` p50 ms | 106.2 | 125.3 | 58.0 | 125.6 | 86.0 |
| `/favicon.svg` p99 ms | 502.5 | 708.1 | 94.1 | 574.4 | 131.1 |
| `/favicon.svg` req/s | 682.5 | 547.7 | 1557.3 | 556.1 | 1072.5 |
| `/favicon.svg` ok | 1800/1800 | 1800/1800 | 1800/1800 | 1800/1800 | 1800/1800 |
| `/health` p50 ms | 143.5 | 245.1 | 92.5 | 133.4 | 129.2 |
| `/health` p99 ms | 672.9 | 1410.5 | 199.0 | 569.3 | 217.2 |
| `/health` req/s | 516.6 | 262.2 | 934.0 | 565.6 | 793.1 |
| `/health` ok | 1800/1800 | 1800/1800 | 1800/1800 | 1800/1800 | 1800/1800 |

### download `/dashboard/assets/index-Z7C9n29H.js` (878726 B each, 4 at once)

| | h1-6 | h1 | h2c | tls-h1 | tls-h2 |
|---|---|---|---|---|---|
| MB/s | 409.1 | 449.5 | 174.7 | 88.2 | 80.8 |
| wall s | 0.01 | 0.01 | 0.02 | 0.04 | 0.04 |
| ok | 12/12 | 12/12 | 12/12 | 12/12 | 12/12 |

### sse `/api/v1/stream/fleet` (50 streams held 32 s)

| | h1-6 | h1 | h2c | tls-h1 | tls-h2 |
|---|---|---|---|---|---|
| established | 6/50 | 50/50 | 50/50 | 6/50 | 50/50 |
| established p99 ms | 12.1 | 25.6 | 21.2 | 32.3 | 34.7 |
| frames per stream p50 | 2 | 2 | 2 | 2 | 2 |
| statuses | 200 | 200 | 200 | 200 | 200 |
| first error | PoolTimeout:  | — | — | PoolTimeout:  | — |

### curl `/dashboard/assets/index-Z7C9n29H.js` (one download per sample, all repeats pooled)

| | h1 | h2c | tls-h2 |
|---|---|---|---|
| MB/s median | 494.8 | 416.1 | 55.8 |
| MB/s min | 328.6 | 329.7 | 12.2 |
| MB/s max | 597.4 | 476.0 | 58.8 |
| samples ok | 15/15 | 15/15 | 15/15 |

