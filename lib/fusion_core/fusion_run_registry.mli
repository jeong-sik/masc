(** Fusion — in-memory run registry for in-progress + recent fusion visibility
    (RFC-0266 §7 Phase 2/Phase D).

    The fusion tool calls {!register_running} at fork start and the sink/failure
    path calls {!mark_completed} on finish, so a status surface (Phase 3 tool,
    Phase 4 dashboard) can report what is deliberating now and what just
    finished. Lock-free Atomic + CAS; optional append-only JSONL backing so
    recent history survives server restart.

    Never wakes a keeper. *)

type recovery_reason = Worker_process_restarted

module Claim_id = Fusion_run_registry_event.Claim_id

type persistence_error =
  | Append_failed of
      { path : string
      ; detail : string
      }
  | Operation_already_registered of string

val persistence_error_to_string : persistence_error -> string

type completion_receipt =
  | Durable
  | Persistence_failed of persistence_error

type completion_error =
  | Unknown_run of string
  | Completion_persistence_failed of persistence_error

val completion_error_to_string : completion_error -> string

type run_status =
  | Running
  | Recovery_required of { reason : recovery_reason }
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
      receipt : completion_receipt;
    }

type worker_state =
  | Registered
  | Claimed of Claim_id.t
  | Started of Claim_id.t

type run = {
  operation : Fusion_types.fusion_operation;
  started_at : float;  (** unix seconds from the keeper clock at fork start *)
  worker_state : worker_state;
  status : run_status;
}

val operation_id : run -> string
val keeper : run -> string
val preset : run -> string
(** Lossless projections from the canonical immutable [operation]. *)

type t

val create : ?path:string -> unit -> t
(** A fresh, isolated registry. Production uses the process-wide {!global}
    (initialized from disk at server boot); tests use [create ()] so each case
    starts empty (no shared-state reset backdoor). *)

val replay : string -> t
(** Hydrate a registry from an append-only JSONL file. Missing files yield an
    empty registry. Unreadable files and malformed lines are logged and skipped,
    so persistence problems are visible without blocking in-memory status
    tracking. Persisted registers without a completed event become typed
    [Recovery_required] rows; dead worker fibers are never presented as live,
    and unfinished work is never erased. Replayed completed runs are pruned to
    the newest {!max_completed_retained}. *)

val register_running :
  t -> operation:Fusion_types.fusion_operation -> started_at:float
  -> (unit, persistence_error) result
(** Record a run as [Running]. A repeated operation identity replaces its prior entry.
    When the registry was created with a path, the durable [Register] event is
    committed before publishing in-memory state. An append failure returns
    [Error] and the run is not registered. *)

type claim

type claim_error =
  | Claim_unknown_operation of string
  | Claim_terminal_operation of string
  | Claim_already_owned of Claim_id.t
  | Claim_persistence_failed of persistence_error

type start_error =
  | Start_unknown_operation of string
  | Start_terminal_operation of string
  | Start_not_claimed of string
  | Start_claim_mismatch of string
  | Start_already_started of Claim_id.t
  | Start_persistence_failed of persistence_error

val claim_error_to_string : claim_error -> string
val start_error_to_string : start_error -> string
val claim_operation : t -> operation_id:string -> (claim, claim_error) result
val start_claimed : t -> claim -> (Fusion_types.fusion_operation, start_error) result
(** The durable execution handshake. [claim_operation] appends exact ownership
    before exposing an opaque affine claim; [start_claimed] appends start before
    returning the canonical operation. A live claim cannot be superseded.
    Replayed unfinished work is explicitly reclaimable without a timeout. *)

val mark_completed
  :  t
  -> operation_id:string
  -> ?failure:string
  -> ?failure_code:string
  -> ok:bool
  -> unit
  -> (unit, completion_error) result
(** Transition a run to [Completed]. Unknown operation identity is an explicit [Error]. [ok] is the
    judge/sink outcome (false for denied/sink_failed/aborted). [failure]/
    [failure_code]는 [ok=false]일 때의 사유·분류 태그 — 상태 표면(tool/HTTP/SSE)이
    사유 없이 "failed"만 보이는 opaque 실패가 되지 않게 함께 기록한다. A failed
    completion append is retained as [Persistence_failed] in memory and returned
    to the caller; it is never silently presented as a durable receipt. *)

val list_runs : t -> run list
(** All tracked runs, newest [started_at] first. [Running],
    [Recovery_required], and [Completed] with an undurable receipt are never
    pruned; only older durably completed rows are retained by the history
    bound. *)

val get : t -> operation_id:string -> run option
(** The run with [operation_id], if still tracked. *)

val status_label : run_status -> string
(** Stable wire label: [Running -> "running"], [Recovery_required ->
    "recovery_required"], [Completed {ok=true} -> "completed"], [Completed
    {ok=false} -> "failed"]. The one place the status vocabulary is defined,
    shared by the Phase 3 tool, the Phase 4 dashboard route, and the
    [fusion_run_status] SSE event so it never drifts. *)

val run_to_yojson : run -> Yojson.Safe.t
(** Canonical per-run JSON: [{run_id, keeper, preset, topology, started_at, status}] +
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
