# Repeated acknowledged input and session CPU

The comparison workflow accepts `input_cycles`, defaulting to one. Each cycle
contains ten transitions: roster arrows, wheel and page keys in both directions,
and detail keys and wheel in both directions. Every input requires a completed
frame with its distinct expected selection/window before the next input is sent.
This is repeated closed-loop interaction, not a fixed-rate overload test.

Each sample retains its cycle and the elapsed time from the preceding timed
acknowledgement to its input. The first sample of each roster/detail phase has
no preceding timed acknowledgement. This exposes observer preparation overhead;
navigation, draft entry and resize between the two phases are not a timed gap.

The scenario also records `RUSAGE_CHILDREN` user/system CPU after the helper
reaps its launcher. The launcher waits for the TUI. The numbers therefore cover
the whole launcher/TUI session and waited descendants, including startup,
navigation, draft entry and shutdown, and exclude observer CPU. Wall time covers
the whole helper call, including fixture setup/cleanup. Neither value is CPU or
wall time spent solely in the timed actions. No per-action CPU claim is made.
See [Python resource usage documentation](https://docs.python.org/3/library/resource.html#resource.RUSAGE_CHILDREN).

## Verification

- Five Python receipt tests pass. They reject missing/duplicate/changed cycle
  samples, invalid latency or resource values, inconsistent CPU totals, missing
  gaps, nonfinite/negative gaps, and incorrect phase boundaries.
- Python syntax and `git diff --check` pass; no local OCaml build.
- A local existing binary, copied without a neighboring server executable,
  completed two cycles (20 transitions), draft verification, exit and termios
  restoration using only temporary fixtures. Its SHA-256 is
  `514de059bef299d9998c7453bef842318ec0acdcac37d7c334c0abdd59844e11`.
  `local-smoke.stdout.txt` retains the receipt: child CPU 0.131390 seconds and
  whole helper wall time 3.25878025 seconds. This verifies the harness; it is
  not a source-attributed optimization comparison or a production measurement.

The comparator retains every raw observation and CPU receipt and verifies the
same actions/cycles for both binaries. Same-runner repeated-input comparisons
remain necessary before attributing a CPU or latency change to a source edit.
