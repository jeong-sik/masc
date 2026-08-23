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

(** #9766: per-render phase timing surfaced in the [slow render] WARN.
    Pure value type so unit tests can pin the formatter without
    booting Eio. *)
type render_phase_timings_ms = {
  total_ms : float;
  snapshot_ms : float;
  operations_ms : float;
  enrich_ms : float;
  data_load_ms : float;
  assemble_ms : float;
  n_keepers : int;
}

val per_keeper_enrich_ms : render_phase_timings_ms -> float
(** Average enrich-phase ms per keeper.  Returns [0.0] when
    [n_keepers = 0] to avoid divide-by-zero in startup races. *)

val format_slow_render_timings : render_phase_timings_ms -> string
(** Render the breakdown into the WARN suffix.  Stable format so
    log scrapers can parse it. *)

val record_render_phase_timings : render_phase_timings_ms -> unit
(** Emit the render phase breakdown into Otel_metric_store.  This mirrors the
    slow-render log payload so dashboard N+1 / enrichment cost is visible
    even when the render stays below the warning threshold. *)

module For_test : sig
  val agents_json :
    keepers:Yojson.Safe.t list ->
    agents:Masc_domain.agent list ->
    Yojson.Safe.t
  (** Exact production projection for the ["agents"] execution-dashboard field. *)
end
