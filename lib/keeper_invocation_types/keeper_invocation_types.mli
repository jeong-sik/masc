(** Typed Keeper invocation wire identity and result vocabulary. Durable
    execution and lane admission remain in the Keeper implementation. *)
type capability = Invoke_turn
type target = Keeper of Keeper_id.Keeper_name.t

type run_ref = { run_id : string; target : target; capability : capability }

type result_contract =
  | Awaiting_execution
  | Publication_uncertain
  | Running
  | Yielded
  | Cancellation_requested
  | Cancelled
  | Completed
  | Failed

val target_name : target -> string
val target_to_json : target -> Yojson.Safe.t
val run_id : run_ref -> string
val run_ref_target_name : run_ref -> string
val run_ref_to_json : run_ref -> Yojson.Safe.t
val result_contract_to_string : result_contract -> string
val result_contract_of_string : string -> result_contract option
