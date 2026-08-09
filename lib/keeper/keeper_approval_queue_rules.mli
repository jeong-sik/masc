val list_rules :
  base_path:string ->
  unit ->
  ( Keeper_approval_queue_rules_types.approval_rule list
  , Keeper_approval_queue_rules_types.rule_store_error )
  result

val list_rules_dashboard_json :
  base_path:string ->
  unit ->
  (Yojson.Safe.t, Keeper_approval_queue_rules_types.rule_store_error) result

val upsert_rule :
  base_path:string ->
  keeper_name:string ->
  tool_name:string ->
  input:Yojson.Safe.t ->
  created_by:string ->
  source_approval_id:string ->
  expires_at:float option ->
  unit ->
  ( Keeper_approval_queue_rules_types.approval_rule * bool
  , Keeper_approval_queue_rules_types.rule_store_error )
  result

val delete_rule :
  base_path:string ->
  id:string ->
  unit ->
  ( Keeper_approval_queue_rules_types.approval_rule
  , Keeper_approval_queue_rules_types.rule_store_error )
  result

val find_matching_rule :
  base_path:string ->
  keeper_name:string ->
  tool_name:string ->
  input:Yojson.Safe.t ->
  ?now:float ->
  unit ->
  ( Keeper_approval_queue_rules_types.rule_lookup
  , Keeper_approval_queue_rules_types.rule_store_error )
  result

module For_testing : sig
  val store_path : base_path:string -> string
end
