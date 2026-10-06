# Canonical sampling evidence read failures

Response to #40960 comment4178167108, based on `41680bd6a2592ef7c490d3ec6302daef9633955f`.

A valid recovery copy previously hid a corrupt canonical regular file. The public bounded and ordinary blob readers now select recovery only when the canonical entry is missing or is the explicitly supported directory obstruction. Existing regular files retain their digest/read/byte-limit failures. Symlinks, FIFOs and unknown path kinds do not authorize fallback. Classification uses the existing protected error boundary so inaccessible paths report a typed read failure.

Actual new native regression on original production failed: expected digest mismatch, received the recovery bytes (`red.log`). Independent source review caught an unprotected classification call in the first repair. A deterministic symlink loop in the canonical parent then reproduced Unix.ELOOP escaping that partial repair (`classification-red.log`). The final protected implementation passes all 29 worker tests, including both new failure boundaries, exact consumed-budget behavior, supported recovery and normal canonical reads.

Focused build: `DUNE_JOBS=2 opam exec --switch=5.5.1 -- scripts/dune-local.sh build test/test_lane_addon_worker.exe`. Final build handle60460 exit0; actual executable handle20483 exit0, 29 tests in7.871s. Test environment: empty MASC_BASE_PATH/ZAI_API_KEY/TYPESAFEAI_API_KEY; MASC_SKIP_SANDBOX_PREFLIGHT=1 and MASC_SKIP_DOCKER_PLAYGROUND=1. The initial build refused a split opam environment before compilation; that log is preserved and excluded from behavioral RED.

Independent review rechecked the final error boundary and sampling callers, finding no remaining P0–P2 in this repair. Raw logs remain byte-exact, including EOF whitespace. This is local focused native proof, not full suite, live provider, hosted CI, or release evidence.
