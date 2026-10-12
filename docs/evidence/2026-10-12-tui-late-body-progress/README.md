# Late body preserves current progress

Base: `bb1a69d2927a94c483a4fb975336e50fcf95da59` (rebuilt L17 tip; original base `9a5a9e455140471fc1a36f45951808e036eb0a90` (#42509)).

Source sequence: a content occurrence is observed and closed; a current provider retry takes progress ownership; same-response Text without piece coordinates (or Thinking with unavailable index) arrives. Body handling formerly replaced the model signal unconditionally, erasing retry progress. The same issue applies to tool-return and response-ended signals.

Text and Thinking body handlers now preserve retry, tool-return and response-ended signals while still retaining exposed bytes. A new indexed observed piece or a new response can still take activity ownership. No text or heuristic matching added. Ownership distinction is unavailable on this base (no response-identity events), so all late bodies preserve progress signals.

Two changed OCaml files passed syntax-only parsing; diff whitespace passed. Registered full transcript-state fixture covers Text and unindexed Thinking byte retention, retry preservation and explicit new-piece activity; fixture unexecuted. No build/CI/installed runtime/TUI screenshots/formal approval/merge. Broad goal remains active.
