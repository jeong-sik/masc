(** Fusion — in-memory run registry for in-progress + recent fusion visibility
    (RFC-0266 §7 Phase 2).

    The fusion tool calls {!register_running} at fork start and the sink/failure
    path calls {!mark_completed} on finish, so a status surface (Phase 3 tool,
    Phase 4 dashboard) can report what is deliberating now and what just
    finished. Lock-free Atomic + CAS; server-lifetime in-memory (no orphan
    [Running] survives a restart). Never wakes a keeper. *)

type run_status =
  | Running
  | Completed of { ok : bool }

type run = {
  run_id : string;
  keeper : string;
  preset : string;
  started_at : float;  (** unix seconds from the keeper clock at fork start *)
  status : run_status;
}

type t

val create : unit -> t
(** A fresh, isolated registry. Production uses {!global}; tests use [create ()]
    so each case starts empty (no shared-state reset backdoor). *)

val register_running :
  t -> run_id:string -> keeper:string -> preset:string -> started_at:float -> unit
(** Record a run as [Running]. A repeated [run_id] replaces its prior entry. *)

val mark_completed : t -> run_id:string -> ok:bool -> unit
(** Transition a run to [Completed]. No-op if [run_id] is unknown. [ok] is the
    judge/sink outcome (false for denied/sink_failed/aborted). *)

val list_runs : t -> run list
(** All tracked runs, newest [started_at] first ([Running] + recently
    [Completed]; older completed runs are pruned). *)

val get : t -> run_id:string -> run option
(** The run with [run_id], if still tracked. *)

val status_label : run_status -> string
(** Stable wire label: [Running -> "running"], [Completed {ok=true} ->
    "completed"], [Completed {ok=false} -> "failed"]. The one place the status
    vocabulary is defined, shared by the Phase 3 tool, the Phase 4 dashboard
    route, and the [fusion_run_status] SSE event so it never drifts. *)

val run_to_yojson : run -> Yojson.Safe.t
(** Canonical per-run JSON: [{run_id, keeper, preset, started_at, status}]. The
    single serializer for every fusion-run surface (tool / HTTP list / SSE
    delta). *)

val global : t
(** Process-wide registry the fusion tool/sink write to (server-lifetime). *)
