Run `baseline-download-20261107T095142Z`: 2026-11-07T09:51:42Z → 2026-11-07T09:51:49Z, 3 repeats, medians over repeats.

- binary: `~/.local/bin/masc` version 0.68.0 build-commit `6afc364dd901726af020c84d491f33b139477d78` sha256 `87e13646e1e41b9785441e33b808a59bf4de8cb5b9ba2fe4a1af4e843c842ae7`
- server: owned=True listener mode `auto` h2_mode_env=None boot 3.9 s exit 0
- client: h2 4.4.1, httpcore 1.0.9, httpx 0.28.1; host macOS-27.2-arm64-arm-64bit-Mach-O arm64
- arguments: requests 600 at concurrency 100, serial 100, download concurrency 4, sse 50 streams for 35.0 s

### download `/dashboard/assets/index-Z7C9n29H.js` (878726 B each, 4 at once)

| | h1-6 | h1 | h2c |
|---|---|---|---|
| MB/s | 142.8 | 117.4 | 50.8 |
| wall s | 0.02 | 0.03 | 0.07 |
| ok | 12/12 | 12/12 | 12/12 |

### curl `/dashboard/assets/index-Z7C9n29H.js` (one download per sample, all repeats pooled)

| | h1 | h2c |
|---|---|---|
| MB/s median | 278.3 | 232.9 |
| MB/s min | 25.0 | 41.5 |
| MB/s max | 438.7 | 345.3 |
| samples ok | 15/15 | 15/15 |

