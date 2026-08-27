(** Read-only projection of every standalone LLM lane.

    This module never starts, stops, retries, reorders, or otherwise acquires a
    lane. It joins immutable lane admission with existing durable observation
    registries so operator surfaces can distinguish idle, running, degraded,
    and lanes with no retained observation without inventing another lifecycle
    authority. *)

type lane_configuration =
  | Configured of
      { admitted_slots : string list
      ; admission_error : string option
      }
  | Unconfigured of string
  | Registry_unavailable of string

val snapshot_json : unit -> Yojson.Safe.t

module For_testing : sig
  val snapshot_json_with
    :  now:float
    -> resolve_lane:(string -> lane_configuration)
    -> exact_runs:Exact_lane_run_registry.run list
    -> verification_runs:Verification_run_registry.run list
    -> goal_verification_runs:Goal_verification_run_registry.run list
    -> Yojson.Safe.t
end
