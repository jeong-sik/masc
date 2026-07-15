(** Typed Keeper invocation wire identity and result vocabulary. Durable
    execution and lane admission remain in the Keeper implementation. *)
type capability = Invoke_turn
type target = Keeper of Keeper_id.Keeper_name.t

type input =
  | Delegated_turn of string
  | Direct_delivery of Keeper_direct_invocation.t
[@@deriving yojson, eq]
type request

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
val keeper_turn : keeper_name:string -> prompt:string -> (request, string) result
val direct_turn : keeper_name:string -> Keeper_direct_invocation.t -> (request, string) result
val request_target : request -> target
val request_capability : request -> capability
val request_target_name : request -> string
val request_prompt : request -> string
val request_direct_delivery : request -> Keeper_direct_invocation.t option
val request_equal : request -> request -> bool
val request_to_json : request -> Yojson.Safe.t
val request_of_json : Yojson.Safe.t -> (request, string) result
val run_id : run_ref -> string
val run_ref_target_name : run_ref -> string
val run_ref_to_json : run_ref -> Yojson.Safe.t
val result_contract_to_string : result_contract -> string
val result_contract_of_string : string -> result_contract option
