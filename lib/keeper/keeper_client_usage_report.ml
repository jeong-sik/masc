type count =
  | Running_count of Agent_core.Types.api_usage
  | Count_replaced

type t =
  { official_turn : int
  ; response_id : string
  ; model : string
  ; conversation_id : string
  ; position : Keeper_usage_resolution.cumulative_position
  ; usage_scope : Runtime_usage_scope.t
  ; count : count
  ; vendor_total_tokens : int option
  }
