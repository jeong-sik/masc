(** Read-only projection of every standalone LLM lane.

    This module never starts, stops, retries, reorders, or otherwise acquires a
    lane. It joins immutable lane admission with existing durable observation
    registries so operator surfaces can distinguish idle, running, degraded,
    and lanes with no retained observation without inventing another lifecycle
    authority. *)

type lane_configuration =
  | Configured of
      { admitted_slots : string list
      ; cli_slots : string list
            (** Official-client runtime ids the lane walks as one-shot
                fallbacks after catalog exhaustion (declaration order). *)
      ; dropped_slots : string list
            (** Slot ids the lane DECLARED that publication could not admit —
                absent from the frozen catalog (a typo, a removed model, or a
                credential-unbound target the resolver excluded). The one
                boot-time WARN was the only signal before this field, so an
                operator could not tell "configured single" from "configured
                double, one silently dropped" (lane audit W4). *)
      ; admission_error : string option
      }
  | Unconfigured of string
  | Registry_unavailable of string

val snapshot_json : unit -> Yojson.Safe.t

type detail_lookup =
  | Detail_found of Yojson.Safe.t
  | Detail_not_found
  | Detail_ambiguous

val recent_run_page_json
  :  limit:int
  -> before:(float * string) option
  -> lane:string option
  -> (Yojson.Safe.t, string) result
(** A cursor page over the same durable registries as {!snapshot_json}.
    Filtering happens before pagination, so a quiet lane is not hidden behind
    a busier lane's bounded page. [None] preserves the mixed admin listing. *)

val run_detail_json : run_id:string -> detail_lookup
(** Exact payload/result evidence for one retained run. Verifier results keep
    their task/Goal subject, verdict reason, evaluator runtime, and durable
    tool observations. Duplicate ids across registries fail explicitly. *)

module For_testing : sig
  val snapshot_json_with
    :  now:float
    -> resolve_lane:(string -> lane_configuration)
    -> exact_runs_total:int
    -> exact_runs:Exact_lane_run_registry.run list
    -> verification_runs:Verification_run_registry.run list
    -> goal_verification_runs:Goal_verification_run_registry.run list
    -> Yojson.Safe.t

  val recent_run_page_json_with
    :  limit:int
    -> before:(float * string) option
    -> lane:string option
    -> exact_runs:Exact_lane_run_registry.run list
    -> verification_runs:Verification_run_registry.run list
    -> goal_verification_runs:Goal_verification_run_registry.run list
    -> (Yojson.Safe.t, string) result

  val run_detail_json_with
    :  run_id:string
    -> exact_runs:Exact_lane_run_registry.run list
    -> verification_runs:Verification_run_registry.run list
    -> goal_verification_runs:Goal_verification_run_registry.run list
    -> detail_lookup
end
