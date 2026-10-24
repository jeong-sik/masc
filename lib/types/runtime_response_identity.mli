(** A captured provider response, owned by its live execution boundary.
    Runtime aliases and later catalog lookups cannot construct this evidence. *)
type t = private
  { execution_id : string
  ; actor : string
  ; runtime_id : string
  ; response_id : string
  ; provider_id : string
  ; model_id : string
  ; tool_use_id : string
  ; provider_turn : int
  }

val make :
  execution_id:string -> actor:string -> runtime_id:string -> response_id:string ->
  provider_id:string -> model_id:string -> tool_use_id:string -> provider_turn:int ->
  (t, string) result
(** Every identity component must be present and nonempty. [model_id] is the
    model reported by the live provider response. *)

val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result
val same_model_identity : t -> t -> bool
(** Equality of captured provider/reported-model identities. This measures
    identity diversity, not statistical independence of model families. *)

type pair_observation =
  | Same_model_identity
  | Distinct_model_identity
  | Producer_unobserved
  | Evaluator_unobserved
  | Both_unobserved

val observe_pair : producer:t option -> evaluator:t option -> pair_observation

type pair_summary = private
  { same_model_identity_count : int
  ; distinct_model_identity_count : int
  ; producer_unobserved_count : int
  ; evaluator_unobserved_count : int
  ; both_unobserved_count : int
  }

val summarize_pairs : (t option * t option) list -> pair_summary
val pair_summary_to_yojson : pair_summary -> Yojson.Safe.t
(** Observed and unknown coverage, with a nullable rate whose denominator
    contains only complete captured pairs. *)
