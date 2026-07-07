(** Keeper_recall_injection_window — in-process record of which fact identities
    Memory OS recall injected into a keeper's recent prompts.

    Write side: {!Keeper_memory_os_recall.render_if_enabled} notes the injected
    [claim_identity] keys after each non-empty render. Read side: the librarian
    write path (RFC-0285 §8) asks {!recently_injected} before treating a
    re-extracted claim as an independent re-observation — a claim the keeper
    just re-read from its own recall block is an echo of stored memory, not
    fresh evidence, so it must not advance the fact's truth anchor.

    This is deliberately separate from {!Keeper_recall_injection_ledger}: the
    ledger is an append-only telemetry artifact whose contract says it is never
    read on any decision path; this window is the load-bearing read model, kept
    in memory so a lost window degrades to the pre-RFC-0285-§8 status quo
    (anchor refresh on echo) rather than to wrong suppression.

    Properties:
    - In-memory only. A server restart empties the window; the first librarian
      run after a restart may refresh anchors it would otherwise suppress.
    - Bounded per keeper: entries older than {!window_turns} turns (or from a
      reset turn numbering) are dropped on the next {!note}.
    - Tests isolate by [keeper_id]; there is no reset entry point. *)

val window_turns : int
(** How many turns an injection record stays visible to {!recently_injected}.
    Chosen to over-approximate the librarian's episode slice span (cadence 3,
    compaction slices somewhat longer): a claim injected anywhere in the window
    the librarian may summarize counts as an echo. Over-approximation costs one
    skipped anchor refresh; under-approximation re-opens the echo loop. *)

val note : keeper_id:string -> turn:int -> keys:string list -> unit
(** Record the [claim_identity] keys recall injected for [keeper_id] at [turn].
    Re-noting the same turn replaces that turn's entry. [keys = []] is a no-op.
    Entries from turns newer than [turn] (a reset turn numbering) and entries
    older than {!window_turns} are pruned. *)

val recently_injected : keeper_id:string -> key:string -> bool
(** Whether [key] was injected into [keeper_id]'s prompt within the retained
    window. Unknown keepers and lost (restarted) windows answer [false]. *)
