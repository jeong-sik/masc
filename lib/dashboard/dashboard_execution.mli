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

val terminal_reason_requires_attention : Yojson.Safe.t -> bool
(** Strict typed projection for a runtime-trust [latest_terminal_reason].
    Missing reason is non-attention; malformed or non-success dispositions are
    attention. Exposed for wire-contract regression tests. *)
