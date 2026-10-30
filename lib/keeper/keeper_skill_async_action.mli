(** Facts causally joined to an already durable inline async result. *)
type sdk_result =
  | Handler_returned of { bytes : int; sha256 : string }
  | Handler_errored of
      { bytes : int; sha256 : string; recoverable : bool
      ; error_class : Agent_core.Types.tool_error_class option }
type occurrence =
  | Sdk_result of { invocation : Agent_core.Tool_contract.Invocation.t; result : sdk_result }
  | Native_started of { official_turn : int; identity : Runtime_native_tools.action_identity }
type t = private
  { delivery_sha256 : string
  ; physical_turn_ref : Ids.Turn_ref.t
  ; runtime_id : string
  ; tool_name : string
  ; occurrence : occurrence
  ; observed_at : string }
val make : delivery_sha256:string -> physical_turn_ref:Ids.Turn_ref.t ->
  runtime_id:string -> tool_name:string -> occurrence:occurrence -> observed_at:string -> (t, string) result
val sdk_result : Agent_core.Types.tool_result -> sdk_result
val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
val identity : t -> string
(** Identity of one delivery link to a physical occurrence. *)
val occurrence_identity : t -> string
(** Physical action occurrence identity, excluding name, result and observation time.
    A changed result for that occurrence is a conflict, not another execution. *)
val same_fact : t -> t -> bool
val same_occurrence_fact : t -> t -> bool
val validate_delivery : Keeper_skill_async_delivery.t -> t -> (unit, string) result
(** Only an inline result at the same physical turn/runtime can be causal
    authority. Native-start facts retain the official counter independently
    and never manufacture completion or exit status. *)
