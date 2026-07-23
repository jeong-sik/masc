(** RFC-0233 §2.2 — closed identity for keeper prompt-assembly blocks.

    Each constructor names one injection site of the per-turn context
    assembly. Adding a new injection site without extending this variant
    is a compile-time error at the TurnRecord write site — that is the
    leverage that keeps the record honest.

    [Persona] is the rendered system prompt (keeper_prompt.ml).
    [Dynamic_context] is the composite soft-context string built by
    keeper_turn.ml/keeper_run_prompt.ml (continuity snapshot, skill
    route, worktree, telemetry feedback, turn instructions, recent
    failure memory) — recorded as one block until the producer threads
    a typed decomposition. [Continuity] and [Connected_surface] exist
    for that decomposition and for the unified-path user-message block;
    they have no producer yet. [Other] carries forward-compatible rows
    read back from disk. *)

type t =
  | Persona
  | Continuity
  | Dynamic_context
  | Temporal_summary
  | Claimed_task_nudge
  | Retry_nudge
  | Memory_os_recall
  | Connected_surface
  | Other of string

val equal : t -> t -> bool
val to_string : t -> string

val of_string : string -> t
(** Total: unknown names map to [Other name], so old readers survive new
    writers and disk rows never fail to decode on this field. *)

val all_known : t list
(** Every constructor except [Other] — for exhaustive codec tests. *)
