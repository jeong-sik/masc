# Private JSONL FIFO open probes, 2026-10-30

These probes investigate FIFO opens before a regular-file check. They do not
run the full repository test, Eio transaction executor, Keeper or CI. The
macOS probe extracts the actual open helpers, slice reader and selected test
functions, then links them against stubs for transaction coordination, binding
validation, descriptor settlement and Eio. The test process installs a SIGCHLD
handler. The baseline test is instrumented with the new error variant solely so
that the unchanged baseline slice reader typechecks against the new test; its
open behavior is not changed.

On macOS 26.6.1 arm64 with OCaml 5.5.1, the extracted baseline at
`f04a41ff2658fff45f019e3fffd42079a0de26dd` timed out in the transaction
read and slice read; its stable-lock FIFO and regular/symlink slice cases passed.
The modified source passed all four cases. Both used the same test source hash.
The local receipts include host-specific output paths, so
[macos-summary.json](macos-summary.json) is a sanitized derivative; it preserves
the original receipt SHA-256 values and source/test hashes, which do not certify
the derivative bytes. Timings describe these individual harness runs only.

[linux-open-receipt.json](linux-open-receipt.json) is the unmodified output of
[linux-open-probe.py](linux-open-probe.py), run once inside an isolated QEMU
Linux 6.18.1 aarch64 Lima guest. With no FIFO writer, a blocking read open
exceeded one second, while the three tested nonblocking opens returned FIFO
file descriptors; the tested nonblocking regular-file opens also returned.
This is a kernel syscall probe, not an OCaml or MASC test. POSIX does not define
FIFO `O_RDWR` behavior for all systems. Neither probe proves fencing against
path replacement or that a filesystem or device cannot block for other reasons.

To reproduce the extracted macOS comparison from a checkout containing this
change (the output directories are ignored working output):

```sh
mkdir -p artifacts/private-jsonl-fifo-repro
git show f04a41ff2658fff45f019e3fffd42079a0de26dd:lib/fs_compat/fs_compat.ml > artifacts/private-jsonl-fifo-repro/baseline.ml
python3 docs/evidence/private-jsonl-fifo-20261030/extract.py artifacts/private-jsonl-fifo-repro/baseline.ml test/test_fs_compat_durable_append.ml artifacts/private-jsonl-fifo-repro/baseline
python3 docs/evidence/private-jsonl-fifo-20261030/extract.py lib/fs_compat/fs_compat.ml test/test_fs_compat_durable_append.ml artifacts/private-jsonl-fifo-repro/fixed
```

The baseline run exits nonzero on the expected timeouts. The helper requires
`ocamlfind`, `unix`, `threads`, `alcotest` and `mtime.clock.os`.
