(** Fusion — in-memory run registry for in-progress + recent fusion visibility
    (RFC-0266 §7 Phase 2/Phase D).

    The fusion tool calls {!register_running} at fork start and the sink/failure
    path calls {!mark_completed} on finish, so a status surface (Phase 3 tool,
    Phase 4 dashboard) can report what is deliberating now and what just
    finished. Lock-free Atomic + CAS; optional append-only JSONL backing so
    recent history survives server restart.

    Never wakes a keeper. *)

type run_status =
  | Running
  | Completed of {
      ok : bool;
      failure : string option;
          (** [ok=false]일 때 사람-가독 실패 사유([Fusion_types.judge_failure_text]
              또는 denied/sink_failed/aborted 라벨). 2026-07-01 사고에서
              [masc_fusion_status]가 status="failed"만 반환해 키퍼가 원인을 추측·
              폴링했다 — 상태 표면이 사유를 함께 나른다. [ok=true]면 [None]. *)
      failure_code : string option;
          (** 안정 분류 태그([Fusion_types.judge_failure_tag] 어휘 +
              denied/sink_failed/aborted/cancelled). [ok=true]면 [None]. *)
    }

type run = {
  run_id : string;
  keeper : string;
  preset : string;
  started_at : float;  (** unix seconds from the keeper clock at fork start *)
  status : run_status;
}

type t

val create : ?path:Eio.Fs.dir_ty Eio.Path.t -> unit -> t
(** A fresh, isolated registry. Production uses the process-wide {!global}
    (initialized from disk at server boot); tests use [create ()] so each case
    starts empty (no shared-state reset backdoor). *)

val replay : Eio.Fs.dir_ty Eio.Path.t -> t
(** Hydrate a registry from an append-only JSONL file. Missing or unreadable
    files yield an empty registry. Replayed completed runs are pruned to the
    newest {!max_completed_retained}. *)

val register_running :
  t -> run_id:string -> keeper:string -> preset:string -> started_at:float -> unit
(** Record a run as [Running]. A repeated [run_id] replaces its prior entry.
    When the registry was created with a path, appends a [Register] event. *)

val mark_completed
  :  t
  -> run_id:string
  -> ?failure:string
  -> ?failure_code:string
  -> ok:bool
  -> unit
  -> unit
(** Transition a run to [Completed]. No-op if [run_id] is unknown. [ok] is the
    judge/sink outcome (false for denied/sink_failed/aborted). [failure]/
    [failure_code]는 [ok=false]일 때의 사유·분류 태그 — 상태 표면(tool/HTTP/SSE)이
    사유 없이 "failed"만 보이는 opaque 실패가 되지 않게 함께 기록한다. When
    the registry was created with a path, appends a [Complete] event. *)

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
(** Canonical per-run JSON: [{run_id, keeper, preset, started_at, status}] +
    실패 시 additive [error]/[failure_code] 필드. The single serializer for
    every fusion-run surface (tool / HTTP list / SSE delta). *)

val global : unit -> t
(** Process-wide registry the fusion tool/sink write to (server-lifetime). Use
    {!set_global} to install a path-backed, replayed instance at boot. *)

val set_global : t -> unit
(** Install a registry as the process-wide {!global}. Called once at server
    boot after replaying the persisted JSONL. *)

val max_completed_retained : int
(** Retention bound for completed runs (newest first). Exposed for tests. *)
