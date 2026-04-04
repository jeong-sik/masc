(** Canonical MASC-side Risk_contract composition. *)

val workspace_mutating_tools : string list

val is_workspace_mutating :
  execution_scope:Team_session_types.execution_scope option -> string -> bool

val allowed_mutations_of_tool_names :
  execution_scope:Team_session_types.execution_scope option ->
  string list ->
  string list

val of_delivery_contract :
  execution_scope:Team_session_types.execution_scope option ->
  delivery_contract:Team_session_types.delivery_contract ->
  tool_names:string list ->
  Oas.Risk_contract.t

val of_keeper :
  keeper_name:string ->
  goal:string ->
  scope_kind:string ->
  execution_scope:string ->
  Oas.Risk_contract.t

val of_keeper_meta : Keeper_types.keeper_meta -> Oas.Risk_contract.t
