# Ghostty 1.3.1 portrait decompression crash

On 2026-09-29, launching installed `masc-tui` at commit
`60deb5adcc4a7d6a83a8f54c6a83b00336308805` closed every Ghostty window.
The installed binary passed `codesign --verify`; its version was 0.46.0.
The host was macOS 26.6.1 (25G76), arm64, Ghostty 1.3.1 with Metal.

## Direct observations

- Two operator crashes at 01:23:51Z and 01:24:07Z were stored by Ghostty in
  `$XDG_STATE_HOME/ghostty/crash/*.ghosttycrash`, not Apple's DiagnosticReports.
- Both embedded minidumps resolve with the installed Ghostty executable and
  `atos` to `Io.Writer.unreachableRebase`, called from
  `compress.flate.Decompress.streamInner + 8448`. The relative PC is `0x7a5a90`.
  See [crash-summary.json](crash-summary.json); full memory dumps remain local.
- TUI logs from those launches report `Sys_error("Input/output error")` in
  `Masc_tui_portrait_view.flush` after losing the terminal.
- A separate PTY with fixture HTTP responses captured the installed TUI's
  `/about` portrait: `f=32,s=160,v=160,o=z,a=T,i=41,p=1,C=1,r=20,q=2`.
  Python's zlib decoded it to exactly 102,400 RGBA bytes.
- Replaying that portrait in a **new Ghostty process**, with default config
  files disabled, crashed it at 01:32:33Z with the **same PC and caller**.
  The existing operator Ghostty PID 75878 remained alive.
- Encoding the same pixels as RGBA PNG and sending `f=100` without `o=z`
  in another new process returned `CSI 1;1 R` to a cursor-position query.
  Twenty further replacements and an image deletion were written without
  losing the terminal. See [png.result.json](png.result.json).
  This PNG was encoded by Python for the protocol experiment, not by a
  newly compiled MASC binary. Transfer sizes were 4,773 bytes for the old
  payload and 4,218 bytes for the experimental PNG.
- The installed binary's existing `about_screen(no_color=True)` PTY scenario
  passed, supporting `NO_COLOR=1 masc-tui` as a temporary workaround.

## Why PNG

[Ghostty 1.3.1's image decoder](https://github.com/ghostty-org/ghostty/blob/v1.3.1/src/terminal/kitty/graphics_image.zig#L359-L396)
uses Zig's flate decompressor for Kitty `o=z`, while `f=100` without transport
compression uses its Wuffs PNG decoder. The TUI already probes PNG support
at startup. The change reuses `Rgb_png.encode_rgba`, keeping alpha, compact
payloads, image/placement identity, cursor preservation, and chunk boundaries.

## Main integration

PR #39798 removed the startup candle independently. The merged source keeps
that working Overview and its eleven PTY scenarios; PNG transmission applies
to `/about` and Keeper portraits. The historical startup crash above remains
evidence for the same inflater, not a claim that startup still draws a candle.

## Validation boundary

The crash and protocol comparison were measured in real Ghostty processes.
No screenshot was captured. The fixed OCaml source has not been built locally
(repository execution protocol). CI must validate the new binary and the
updated lossless PNG, portrait, and animated `/about` scenarios before delivery.
The installed TUI has not been replaced.
