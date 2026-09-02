type cumulative_position = Fresh | Resumed

type basis =
  | Per_request
  | Conversation_counter of
      { runtime_id : string
      ; conversation_id : string
      ; position : cumulative_position
      }
  | Unavailable

type sample =
  { input_tokens : int
  ; output_tokens : int
  ; cache_creation_input_tokens : int
  ; cache_read_input_tokens : int
  ; cost_usd : float option
  }

type cursor =
  { runtime_id : string
  ; conversation_id : string
  ; cumulative : sample
  }

type status =
  | Exact
  | Usage_missing
  | Scope_unavailable
  | Invalid_observation
  | Exact_cost_unavailable
  | Baseline_missing
  | Counter_regressed

type t =
  { observation : sample option
  ; basis : basis
  ; delta : sample option
  ; status : status
  ; observed_at : float
  }

val sample_of_api_usage : Agent_core.Types.api_usage -> sample
val api_usage_of_sample : sample -> Agent_core.Types.api_usage
val basis_to_json : basis -> Yojson.Safe.t
val basis_of_json : Yojson.Safe.t -> (basis, string) result
val cursor_to_json : cursor -> Yojson.Safe.t
val cursor_of_json : Yojson.Safe.t -> (cursor, string) result
val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
val status_to_string : status -> string

val resolve :
  cursor:cursor option ->
  basis:basis ->
  observation:sample option ->
  observed_at:float ->
  t * cursor option
