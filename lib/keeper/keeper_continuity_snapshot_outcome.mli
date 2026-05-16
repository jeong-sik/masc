(** Keeper_continuity_snapshot_outcome — closed sum naming the three paths
    out of {!Keeper_post_turn}'s [apply_continuity_summary].

    The function used to expose only one boolean: "did the snapshot get
    persisted, yes/no".  When it returned [None] (no [STATE] block, no
    structured working_context fallback) it silently returned [meta]
    unchanged.  That [None] branch is load-bearing because
    [meta.runtime.last_continuity_update_ts] only advances on the
    [Some] path, and the reflection-cooldown gate in
    {!Keeper_compact_policy} uses [last_continuity_update_ts] to decide
    whether compaction is allowed (line 68-79).  An LLM that stops
    emitting [STATE] therefore silently traps the cooldown until ratio
    hits the emergency threshold.

    This typed outcome makes each path observable so operators can tell
    "missing snapshot" from "structured fallback used" and tie that to
    cooldown stalls. *)

type t =
  | From_state_block
      (** [latest_state_snapshot_from_messages] returned [Some].  The LLM
          emitted a parseable [STATE] block this turn. *)
  | From_structured_checkpoint
      (** [STATE] block was absent but the OAS checkpoint
          [working_context] yielded a snapshot.  Cooldown advances. *)
  | Missing_no_snapshot
      (** Both paths returned [None].  [meta] is returned unchanged and
          [last_continuity_update_ts] is *not* advanced — the cooldown
          gate stays at its previous timestamp.  Rising rate of this
          variant is the operational signal that LLM-side [STATE]
          emission has regressed. *)

val to_label : t -> string
