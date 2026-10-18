val fleet_fsm_action_payload :
  keeper_name:string ->
  kind:string ->
  reason:string ->
  snapshot:Yojson.Safe.t ->
  execution:Yojson.Safe.t ->
  [> `Assoc of (string * Yojson.Safe.t) list ]

val fleet_fsm_message_payload :
  keeper_name:string ->
  reason:string ->
  snapshot:Yojson.Safe.t ->
  execution:Yojson.Safe.t ->
  [> `Assoc of (string * Yojson.Safe.t) list ]

val composite_recommended_actions_json :
  keeper_name:string ->
  snapshot:Yojson.Safe.t ->
  execution:Yojson.Safe.t ->
  attention:Server_dashboard_http_composite_claims.composite_runtime_attention ->
  [> `List of Yojson.Safe.t list ]
