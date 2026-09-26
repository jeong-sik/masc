type cumulative_position = Fresh | Resumed

type basis =
  | Per_request
  | Turn_total
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

(** The cost the runtime reported with [sample], as the plain float that
    running totals and cost-ledger rows hold. A sample with no reported cost
    adds 0.0: the totals sum reported costs, and a ledger row with usage but
    a zero cost names the missing report in its [cost_usd_source]. *)
val reported_cost_usd : sample -> float

val cursor_to_json : cursor -> Yojson.Safe.t
val cursor_of_json : Yojson.Safe.t -> (cursor, string) result
val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
val status_to_string : status -> string
val position_to_string : cumulative_position -> string

val resolve :
  cursor:cursor option ->
  basis:basis ->
  observation:sample option ->
  observed_at:float ->
  t * cursor option
