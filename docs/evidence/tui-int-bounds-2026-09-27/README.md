# Use integer bounds in TUI layout and scrolling

## Observations

The native artifact `10911156552` from [run 36255838724](https://github.com/jeong-sik/masc/actions/runs/36255838724)
has source `56884cdc2d82d8b4b3f9b64597c6e770228e9712`. Its ZIP size/digest,
manifest/source and all three binary hashes were verified. Its two affected
source files are byte-identical to main base
`a9e0c8941eadf17b2a336b159d71eb022f8185d3` (recorded hashes in
source-observation.json). Other product files differ between the isolated
probe and main; this is not a current-main performance measurement.

A five-second native profile of sustained synthetic Info scrolling contains
`Stdlib.min` and `Stdlib.max` calling generic `compare_val`. The sample is a
reason to investigate that path. Unwinding does not attribute every generic
comparison to these two modules or establish its fraction of frame time.

Disassembling the verified binary with `otool -tvV` finds 93 direct branches
to the generic bounds within message-layout and scroll functions. Their
symbols and instructions are recorded in baseline-bound-call-sites.json;
complete selected function bodies are retained compressed. Static sites
are not dynamic call counts or a latency measurement.

## Change

The layout module's 65 and scroll module's 21 integer bound expressions now
use `Int.min` / `Int.max`. Their operands are cell widths, byte offsets,
row counts, indices or scroll positions. Float bounds remain `Float.max`.
Arithmetic, branch order, integer overflow behavior, interfaces and render
text are unchanged. There is no new cache, helper, configuration or fallback.
The [OCaml 5.5 Int interface](https://ocaml.org/manual/5.5/api/Int.html)
defines the same minimum/maximum operation specifically for integers;
the installed 5.5.1 implementation uses integer comparisons directly.
The [candidate disassembly](codegen/README.md) now confirms that the selected
modules have zero direct branches to generic bounds, versus 93 in baseline.
This generated-path change does not establish a latency improvement.

Existing message-layout and scroll suites already cover Unicode/ANSI layout,
clipping, empty/narrow windows, stale scroll bounds and page/cursor behavior.
This arithmetic specialization adds no new behavior, so it reuses those
regressions. Syntax parsing and diff whitespace checks pass. No local OCaml
build was run. Source focused CI at `887d52fed1f73d7191018ded9ea67433dbef848c`
passed 108 layout and 14 scroll cases. Later evidence-head PR gates remain
separate. The [completed PTY comparison](comparison/README.md) contains all
600 observations and six draft-preservation checks.

Overall median/p95 was 0.3384165/1.497875 ms for baseline and
0.273937/0.71475 ms for candidate; the aggregate roster and Info values were
also lower. Info repetition 2 was worse, and every candidate observation
still exceeded 0.1 ms. The complete per-session results and shared-runner
limits accompany the receipts; this is not a general causal speedup claim.

## Profile protocol and limits

Both retained diagnostic attempts acknowledged 24,006 inputs: one roster
cycle, then 6,000 Info cycles, with 250 retained alpha Channels bindings.
The unchanged corrected observer is
`304f5f6f67edcb38e3b2ad5da6759d64f73a4983`; runner/scenario/helper hashes
and full observation/stdout receipts are retained for each attempt.

The initial attempt mostly sampled idle polling and is retained under
initial-idle-profile. Its missing hot stacks are not proof that any path
was eliminated; exact overlap with input processing was not recorded.
The second runner waits for the sampler's readiness banner before releasing
Info inputs and records first/last input timestamps. Its sample contains
active rendering stacks. The count of writes while the sampler process is
alive may include its post-collection analysis and is not a count of writes
inside the five-second sampling window.

These instrumented attempts are diagnostics, not a before/after comparison.
The readiness wait and per-write sampler polling affect execution. Child CPU
also includes sampler, ps and pgrep, despite the inherited raw resource
scope; profile.json explicitly corrects that scope. Both samplers exited
zero and the harness reaped its TUI/launcher. No sampled latency, absent
stack, or child CPU total is used as proof of an optimization.

Temporary paths are normalized only as recorded in redaction.json; original
and published hashes remain distinct. files.json covers published bytes.
Use ready-profile/run-profile.py with the anchored observer checkout,
verified artifact directory and a new output directory to reproduce the
instrumented diagnosis. This does not access the operator workspace.

No general speedup, allocation-volume reduction, production deployment,
physical-display measurement, or 0.1ms achievement is claimed.
