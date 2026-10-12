# Late body preserves current progress

Base: `9a5a9e455140471fc1a36f45951808e036eb0a90` (#42509).

Source sequence: a content occurrence is observed and closed; a current provider retry takes progress ownership; same-response Text without piece coordinates (or Thinking with unavailable index) arrives. The helper formerly assigned Scoped_model_content even when it returned only closed inventory, erasing retry progress. The same issue applies to a newer tool-return signal.

The metadata-owned body helper now preserves retry, tool-return and response-ended signals. It retains exposed bytes under existing admission. A new indexed observed piece or a new response can still take activity ownership. No text or heuristic matching added.

Executed unchanged extracted production helper plus content state machine in a minimal typed OCaml interpreter harness. Parent exit 1: body without piece authority replaced current progress. Current exit 0: same-response retry/tool-return retained; different response remains eligible; missing-start closure/open-piece/future-stop/index-reuse cases retained. Harness/logs: `/tmp/masc-tui-late-body-progress-20261012/`. This is isolated production-function execution, not full transcript integration or typechecking.

Two changed OCaml files passed syntax-only parsing; diff whitespace passed. Registered full transcript-state fixture covers Text and unindexed Thinking byte retention, retry preservation and explicit new-piece activity; fixture unexecuted. No build/CI/installed runtime/TUI screenshots/formal approval/merge. Broad goal remains active.
