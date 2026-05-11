(* RFC-0070 Phase 3a — stub. See keeper_sandbox_plan.mli for contract. *)

type plan_error =
  | Invalid_meta of string
  | Invalid_command of string
  | Unsupported_profile of string

(* Abstract sandbox plan. Phase 3b replaces with a record carrying
   container_name, image_pin, mounts, env_passthrough, ulimits,
   network_mode, timeout_budget — see RFC-0070 §3.1. *)
type t = unit

let of_request ~turn_id:_ ~attempt:_ ~meta_name:_ ~cmd:_ =
  Error (Unsupported_profile "RFC-0070 Phase 3a: of_request not yet implemented")
