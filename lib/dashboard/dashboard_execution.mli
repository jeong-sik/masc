type observation = { json : Yojson.Safe.t; next_deadline_unix : float option }

val observe_current :
  ?actor:string -> ?light:bool -> config:Workspace.config ->
  sw:Eio.Switch.t -> clock:'a Eio.Time.clock ->
  proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t option -> unit -> observation
(** Source-triggered current metadata, with policy/window deadlines from the
    same observation. It bypasses the actor and nested operator metadata TTLs.
    The caller owns the existing compute timeout and failure retry policy;
    this function never converts a timeout into a successful JSON envelope. *)

val json :
  ?actor:string ->
  ?fixture:string ->
  ?light:bool ->
  config:Workspace.config ->
  sw:Eio.Switch.t ->
  clock:'a Eio.Time.clock ->
  proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t option ->
  unit ->
  Yojson.Safe.t

(** [task_json ~goal_task_index task] serializes a task for the dashboard
    execution payload.  [goal_task_index] maps a task id to the goal ids it is
    linked to (RFC-0267 Phase 1); the task's canonical (first) goal is projected
    as the ["goal_id"] field — [`Null] when the task is unlinked.  Exposed so
    unit tests can pin the projection without booting Eio. *)
val task_json :
  goal_task_index:(string, string list) Hashtbl.t ->
  Masc_domain.task ->
  Yojson.Safe.t

(** List projection. Long descriptions become UTF-8-safe previews marked
    [detail_level=summary] with the full description SHA-256 revision. Other
    fields remain complete; {!task_json} still returns the full description. *)
val task_list_json :
  goal_task_index:(string, string list) Hashtbl.t ->
  Masc_domain.task -> Yojson.Safe.t

(** How many terminal tasks inside the recency window the execution payload
    carries. *)
val recent_terminal_limit : int

(** [recent_terminal_tasks ~cutoff tasks] selects the tasks that reached a
    terminal status at or after [cutoff], newest terminal timestamp first,
    bounded by {!recent_terminal_limit}.

    Ordering is part of the contract. Truncating in backlog order — insertion
    order — surfaced the oldest of the qualifying tasks once more than the limit
    ended inside the window, so a panel labelled "recent" omitted the most
    recent entries. A task whose terminal timestamp does not parse is left out
    rather than pinned to an invented time.

    Pure, so the ordering is testable without booting Eio. *)
val recent_terminal_tasks :
  cutoff:float ->
  Masc_domain.task list ->
  Masc_domain.task list

module For_test : sig
  val workspace_status_json : Workspace.config -> Yojson.Safe.t
  val terminal_reason_requires_attention : Yojson.Safe.t -> bool
  (** Exact terminal-reason projection used by the execution attention queue. *)

  val agents_json :
    keepers:Yojson.Safe.t list ->
    agents:Masc_domain.agent list ->
    Yojson.Safe.t
  (** Exact production projection for the ["agents"] execution-dashboard field. *)

  val render_under_timeout :
    clock:_ Eio.Time.clock ->
    timeout_s:float ->
    (unit -> Yojson.Safe.t) ->
    (Yojson.Safe.t, [ `Timeout ]) result
  (** The window {!json} renders under: the render's result whenever it
      finished, even in the scheduler pass the window closed; [`Timeout] only
      when it had not. *)

  val enrich_keeper_with_diagnostic :
    config:Workspace.config -> Yojson.Safe.t -> Yojson.Safe.t
  (** The per-row enrichment {!json} runs on each snapshot keeper row. A
      declaration row comes back without a diagnostic or trust even when the
      Keeper's metadata exists by now: the row still describes a Keeper that
      had not booted when the snapshot was taken. *)
end
