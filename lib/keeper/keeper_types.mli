(** Keeper_types -- shared keeper contract, profile, meta codec/store, and
    health utilities.

    Support stores, path helpers, and JSONL helpers are owned by
    {!Keeper_types_support}; do not route new callers through this facade.

    Spec navigation (OCaml -> TLA+) — plan §19 anchor pattern.  Sibling
    to #11612 (rollover) and #11614 (post_turn).  Authoritative spec
    mirror is [specs/keeper-state-machine/KeeperGenerationLineage.tla].

    Spec lines 10-13 already cite this module among three modeled
    OCaml sources:
      - lib/keeper/keeper_post_turn.ml   (post-turn pipeline,
                                          anchored in #11614)
      - lib/keeper/keeper_rollover.ml    (rollover semantics,
                                          anchored in #11612)
      - lib/keeper/keeper_types.mli      (this file — type lineage)

    This block is the reverse-direction citation so code search for
    "KeeperGenerationLineage" lands here too.

    Type lineage covered (TLA+ -> OCaml):
      generation                 [keeper_meta.generation : int] —
                                 incremented on rollover.  See
                                 [Keeper_types_profile] and
                                 [Keeper_rollover.attempt].
      current_trace_id           [keeper_meta.trace_id : string] —
                                 replaced on successful handoff.
      trace_history              [keeper_meta.trace_history : string list] —
                                 append-only; most recent is at head
                                 or tail per the OCaml convention used
                                 in Keeper_rollover.
      ckpt_valid / ckpt_generation
                                 derived from [keeper_meta.checkpoint]
                                 fields, the parity check
                                 [keeper_phase = idle => ckpt is
                                 consistent with current generation]
                                 lives in [Keeper_post_turn] when the
                                 turn returns to idle.

    Spec out-of-scope (line 15-18 in spec): compaction strategy
    selection (KeeperCompactionLifecycle), Agent.run turn loop,
    long-term memory recall.  This module re-exports policy types
    only — no behavior.

    {b SSOT}: types and pure helpers come from
    {!Keeper_types_profile} and {!Keeper_meta_contract} via
    [include] below.  Each type has exactly one canonical
    definition in the owning submodule — do not redeclare here. *)

include module type of struct
  include Keeper_types_profile
end

include module type of struct
  include Keeper_meta_contract
end

(** {1 Runtime meta write sync hook} *)

val runtime_meta_write_sync_hook : (Coord.config -> keeper_meta -> unit) ref
val register_runtime_meta_write_sync : (Coord.config -> keeper_meta -> unit) -> unit

(** {1 JSON field scrubbing} *)

val config_field_names : string list
(** Config field names owned by TOML only — never written to JSON.
    Re-exported from {!Keeper_meta_json_scrub}. *)

val drop_assoc_keys : string list -> Yojson.Safe.t -> Yojson.Safe.t
val reject_removed_keeper_meta_fields : Yojson.Safe.t -> (unit, string) result
val scrub_persisted_keeper_meta_json :
  path:string -> Yojson.Safe.t -> Yojson.Safe.t * bool

(** {1 Meta serialization} *)

val meta_to_json : keeper_meta -> Yojson.Safe.t
val meta_of_json : Yojson.Safe.t -> (keeper_meta, string) result

(** {1 Meta file I/O} *)

val read_meta_file_path : string -> (keeper_meta option, string) result
val persisted_keeper_names : Coord.config -> string list
val configured_keeper_names : Coord.config -> string list
val keeper_names : Coord.config -> string list
val keepalive_keeper_names : Coord.config -> string list
val persistent_agent_names : Coord.config -> string list
val write_meta : ?force:bool -> Coord.config -> keeper_meta -> (unit, string) result

val write_meta_with_merge :
  ?max_retries:int ->
  merge:(latest:keeper_meta -> caller:keeper_meta -> keeper_meta) ->
  Coord.config ->
  keeper_meta ->
  (unit, string) result
(** CAS write with bounded retry and caller-supplied field merge (#9769).

    On CAS conflict the caller's [merge] function decides which fields
    to take from the disk snapshot and which from the caller. This eliminates the false
    sharing that caused turn-failure writes to lose the CAS race
    against concurrent heartbeat writers: the turn path never modifies
    [joined_room_ids] / [last_seen_seq_by_room], so preserving those
    from disk lets the retry succeed without clobbering heartbeat data.

    The merge function MUST set the returned [meta_version] to the
    disk's version so the next CAS check passes. The provided
    strategies in {!Keeper_meta_merge} do this. *)

val is_version_conflict_error : string -> bool
(** True when [write_meta] returned an error caused by CAS version
    mismatch (vs an actual I/O failure). Useful for callers that want
    to log conflicts at WARN and other failures at ERROR. *)
val read_meta_resolved :
  Coord.config -> string -> ((string * keeper_meta) option, string) result
val read_meta : Coord.config -> string -> (keeper_meta option, string) result

(** Read keeper meta only if the file's mtime changed since [last_mtime].
    Returns [Some (meta, new_mtime)] on change, [None] when unchanged.
    Avoids JSON parsing on every heartbeat when no operator modified the file. *)
val read_meta_if_changed :
  Coord.config -> string -> last_mtime:float ->
  (keeper_meta * float) option

(** {1 Fiber health (for keeper supervisor)} *)

type fiber_health =
  | Fiber_alive
  | Fiber_zombie
  | Fiber_dead
  | Fiber_unknown

(** {1 Keeper health state} *)

type keeper_health =
  | KH_healthy
  | KH_idle
  | KH_offline
  | KH_stale
  | KH_degraded
  | KH_zombie
  | KH_dead

type keeper_continuity =
  | Continuity_healthy
  | Continuity_recovering
  | Continuity_not_running

(** {1 Per-tool usage tracking} *)

type tool_call_entry = {
  count : int;
  successes : int;
  failures : int;
  last_used_at : float;
}

(** {1 Working Context Types (moved from Keeper_working_context)} *)

type working_context = {
  checkpoint : Agent_sdk.Checkpoint.t;
  max_tokens : int;
}

type session_context = {
  session_id : string;
  session_dir : string;
}
