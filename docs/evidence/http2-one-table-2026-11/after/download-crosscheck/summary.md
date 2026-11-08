Run `after-download-20261108T234030Z`: 2026-11-08T23:40:30Z → 2026-11-08T23:40:33Z, 3 repeats, medians over repeats.

- binary: `~/.local/bin/masc` version 0.69.0 build-commit `9c7452c0e2086d3c1b557cba9f7e649089bf86d7` sha256 `f6e3db697c5816f030359c3b926638c3576ff2f10bbc0db1a833dd6aef646c3a`
- server: owned=True listener mode `auto` h2_mode_env=None boot 0.8 s exit 0
- client: h2 4.4.1, httpcore 1.0.9, httpx 0.28.1; host macOS-27.2-arm64-arm-64bit-Mach-O arm64
- arguments: requests 600 at concurrency 100, serial 100, download concurrency 4, sse 50 streams for 32.0 s

### download `/dashboard/assets/index-Z7C9n29H.js` (878726 B each, 4 at once)

| | h1-6 | h1 | h2c | tls-h1 | tls-h2 |
|---|---|---|---|---|---|
| MB/s | 423.2 | 425.9 | 196.3 | 92.8 | 87.4 |
| wall s | 0.01 | 0.01 | 0.02 | 0.04 | 0.04 |
| ok | 12/12 | 12/12 | 12/12 | 12/12 | 12/12 |

### curl `/dashboard/assets/index-Z7C9n29H.js` (one download per sample, all repeats pooled)

| | h1 | h2c | tls-h2 |
|---|---|---|---|
| MB/s median | 596.6 | 436.1 | 58.9 |
| MB/s min | 434.2 | 346.6 | 19.1 |
| MB/s max | 686.0 | 518.1 | 62.6 |
| samples ok | 15/15 | 15/15 | 15/15 |

