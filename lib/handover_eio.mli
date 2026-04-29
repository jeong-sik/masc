(** Handover_eio — agent capsule transfer ("last will and
    testament" pattern).

    When an agent exits (context limit, timeout, crash), it leaves
    behind a structured {!handover_record} for the next agent to
    inherit.  Records are persisted as JSON under
    \[<masc_dir>/handovers/<id>.json\] and discovered via
    {!list_handovers} / {!get_pending_handovers}.

    Internal: \[handover_rng\] (Random.State.t),
    \[trigger_reason_to_string\] (helper consumed by
    {!create_handover}), \[ensure_dir\], \[handover_dir_path\] /
    \[handover_file_path\] (path helpers).  Future "configurable
    base path" PR can reopen the path helpers explicitly. *)

(** {1 Types} *)

type handover_record = {
  id : string;
  from_agent : string;
  to_agent : string option;  (** [None] = unclaimed. *)
  task_id : string;
  session_id : string;
  current_goal : string;
  progress_summary : string;
  completed_steps : string list;
  pending_steps : string list;
  key_decisions : string list;  (** Why-level rationale. *)
  assumptions : string list;
  warnings : string list;
  unresolved_errors : string list;  (** PDCA error state. *)
  modified_files : string list;
  created_at : float;  (** Unix timestamp. *)
  context_usage_percent : int;
  handover_reason : string;  (** {!trigger_reason_to_string} output. *)
}
(** The capsule passed to the next agent.  16 fields covering core
    state, thinking context, error state, file changes, and
    metadata. *)

(** Why the outgoing agent triggered the handover. *)
type trigger_reason =
  | ContextLimit of int  (** Percentage of context budget consumed. *)
  | Timeout of int  (** Seconds before timeout fired. *)
  | Explicit  (** Operator-driven handover. *)
  | FatalError of string  (** Crash detail. *)
  | TaskComplete  (** Successful completion handoff. *)

(** {1 Construction} *)

val generate_id : unit -> string
(** [generate_id ()] returns ["handover-<timestamp_ms>-<5-digit-random>"].
    Uses a fiber-safe internal {!Random.State.t}; collisions in the
    same millisecond require both [Random.int 100000] outputs to
    collide. *)

val create_handover :
  from_agent:string ->
  task_id:string ->
  session_id:string ->
  reason:trigger_reason ->
  handover_record
(** [create_handover ~from_agent ~task_id ~session_id ~reason]
    returns a fresh empty record:
    [id = generate_id ()], [to_agent = None],
    [created_at = Time_compat.now ()],
    [handover_reason = trigger_reason_to_string reason], all
    list / string fields empty / "". *)

(** {1 JSON round-trip} *)

val handover_to_json : handover_record -> Yojson.Safe.t
(** Hand-written serialiser (no PPX) — kept stable across refactors.
    Emits all 16 record fields. *)

val handover_of_json : Yojson.Safe.t -> handover_record option
(** [handover_of_json json] is the inverse of {!handover_to_json}.
    Returns [None] when the JSON shape does not match (missing /
    wrong-typed fields). *)

(** {1 Persistence}

    All persistence operations take an
    [fs] (Eio filesystem capability) and a {!Coord_utils.config}.
    They run synchronously inside whatever fiber the caller
    supplies. *)

val save_handover :
  fs:_ Eio.Path.t ->
  Coord_utils.config ->
  handover_record ->
  (unit, string) result
(** [save_handover ~fs config h] writes \[<config>/handovers/<h.id>.json\].
    Creates the directory if missing.  Errors stringify any
    underlying [Sys_error] / [Eio] exception. *)

val load_handover :
  fs:_ Eio.Path.t ->
  Coord_utils.config ->
  string ->
  (handover_record, string) result
(** [load_handover ~fs config handover_id] reads + parses
    \[<config>/handovers/<handover_id>.json\].  Returns
    [Error _] on missing file, IO failure, or JSON parse failure. *)

val list_handovers :
  fs:_ Eio.Path.t ->
  Coord_utils.config ->
  handover_record list
(** [list_handovers ~fs config] returns all handovers in the
    persistence directory, sorted by [created_at] descending
    (newest first).  Excludes [pending.json] (legacy index file).
    Returns [\[\]] when the directory is missing.  Per-entry
    failures are logged via {!Safe_ops} drop reasons but do not
    fail the whole call. *)

val get_pending_handovers :
  fs:_ Eio.Path.t ->
  Coord_utils.config ->
  handover_record list
(** [get_pending_handovers ~fs config] is {!list_handovers}
    filtered to records with [to_agent = None]. *)

val claim_handover :
  fs:_ Eio.Path.t ->
  Coord_utils.config ->
  handover_id:string ->
  agent_name:string ->
  (handover_record, string) result
(** [claim_handover ~fs config ~handover_id ~agent_name] atomically:

    + Loads the record via {!load_handover}.
    + Returns [Error "Handover already claimed by <name>"] when
      [to_agent = Some _].
    + Sets [to_agent = Some agent_name] and persists via
      {!save_handover}.
    + Returns [Ok updated_record] on success. *)

(** {1 Rendering} *)

val format_as_markdown : handover_record -> string
(** [format_as_markdown h] renders [h] as a structured Markdown
    document with sections: header, current goal, progress,
    completed/pending steps, key decisions, assumptions, warnings,
    unresolved errors, modified files.  Empty list sections are
    omitted entirely (no empty headers). *)
