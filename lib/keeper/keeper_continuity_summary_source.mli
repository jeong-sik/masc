(** Keeper_continuity_summary_source — closed sum naming the six
    paths through {!Keeper_world_observation.read_continuity_summary}.

    The function used to collapse five distinct fallback reasons into
    one [continuity_fallback_summary_text] return value with no signal:
    {ol
    {- Progress snapshot file found → rendered}
    {- Checkpoint loaded, [STATE] block snapshot found → rendered}
    {- Checkpoint loaded, OAS structured working_context snapshot found
       → rendered}
    {- Checkpoint loaded but no snapshot from either path → fallback}
    {- Checkpoint load returned [None] for [ctx] → fallback}
    {- Catch-all [| _ -> ] swallowed an exception and fell back}}

    Five of these (path 4, 5, 6) produce identical output — the
    meta-level fallback text — but mean very different things
    operationally.  In particular path 6 hides exceptions: OS errors,
    file corruption, Yojson parse failures, anything not [Cancelled].

    This typed source lets the counter label distinguish the six paths
    so operators can read "how often does the keeper actually have a
    fresh continuity summary" vs "how often is the operator looking at
    the stale meta fallback" — and which root cause put it there. *)

type t =
  | Progress_snapshot
      (** Path 1: [Keeper_memory_policy.read_progress_snapshot] returned
          [Some].  The most up-to-date source — written by
          [Keeper_post_turn.apply_continuity_summary] each turn. *)
  | Checkpoint_state_block
      (** Path 2: progress snapshot missing, OAS checkpoint loaded, and
          [latest_state_snapshot_from_messages] found a [STATE] block in
          the recent messages. *)
  | Checkpoint_structured
      (** Path 3: progress snapshot missing, OAS checkpoint loaded, no
          [STATE] block in messages, but
          [snapshot_of_structured_working_context] succeeded against the
          checkpoint's [working_context]. *)
  | Meta_fallback_no_snapshot
      (** Path 4: checkpoint ctx loaded but every snapshot source
          returned [None].  Meta-level [continuity_summary] is the only
          available text and may be stale. *)
  | Meta_fallback_no_ctx
      (** Path 5: [load_context_from_checkpoint] returned [None] for
          [ctx_opt].  Checkpoint file missing/empty/locked. *)
  | Meta_fallback_exception
      (** Path 6: a non-[Cancelled] exception was raised somewhere in
          the chain and silently caught by [| _ -> ].  Operators
          previously had no signal for this case. *)

val to_label : t -> string
