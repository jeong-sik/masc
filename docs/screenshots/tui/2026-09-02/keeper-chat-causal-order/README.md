# Keeper chat causal-order partial evidence

This directory preserves the successful visual portion of the exact-artifact
capture for product commit `2d541c8c7a834b4ffd93269fd75628e17f16f47e`.
The macOS arm64 binary came from release run
[`33524854233`](https://github.com/jeong-sik/masc/actions/runs/33524854233),
embeds artifact commit `cc6fa8e2a11f0cbf1b2cb3728ab2c8e612558920`,
and differs from the product commit only in `.github/workflows/release.yml`.

The browser evidence is deliberately marked **partial**, not passed. The
responsive queue scenario reached every visual and causal assertion through
screenshot 07, then failed its final HTTP accounting because one ancillary
POST was not in the fixture allow-list. The browser steer scenario therefore
did not start.

The important frames are:

- `05-chat-next-separated.png`: unseen input is a `NEXT` lane below the causal
  transcript, with submitted clock `02:20:37`.
- `06-chat-next-active-same-slot.png`: the promoted USER takes the same visual
  slot and retains `02:20:37`; the first turn stays grouped USER, TOOL,
  ASSISTANT above it.
- `07-chat-causal-turns-settled.png`: the durable-history reload completed and
  the DOM assertions proved first USER < TOOL < ASSISTANT < second USER <
  ASSISTANT. The ttyd resize badge and viewport clipping mean this PNG is not
  standalone proof of every one of those rows.

`evidence.partial.json` records the exact SHA/hash boundary and the failed
terminal assertion. It does **not** claim that this binary is exact to the
later PR merge head.

`steer-pty.json` is a separate fresh PTY interaction against the same exact
artifact binary. It passed the incremental-frame-safe assertions, observed
ordinary NEXT before STEER, observed STEER ahead of NEXT after the interrupt,
and recorded dispatch order `original`, `corrected-course`, `ordinary-next`.
The interrupt body carries the exact original request ID. This is interaction
and HTTP evidence, not a browser screenshot.
