(** Facts observed while one Keeper turn walks its runtime candidates.
    This is receipt evidence, never candidate-selection or retry authority.
    It preserves source order, including repeated runtime ids. *)
type failure =
  { attempt : int
    (** The driver's zero-based candidate ordinal, not a provider call count. *)
  ; runtime_id : string
  ; dispatch : Runtime_attempt_dispatch.t
  ; failure : Keeper_request_failure.t
  ; api_candidate_fault : Llm_provider.Candidate_fault.t option
    (** [Some Unattributed] is an API refusal whose ownership was not
        classified. [None] means this API projection is inapplicable.
        Neither means that every other candidate must fail. [failure]'s
        residual Core arm retains category and human detail, not a lossless
        reconstruction of the original agent-core error. *)
  }

type terminal =
  | Terminal_not_observed
  | Candidate_terminal of
      { runtime_id : string
      ; attempt : int
      ; failure : Keeper_request_failure.t
        (** The actual lane-terminal callback's error. Effect fencing may
            transform it, so it need not equal an attempt's earlier error. *)
      }

type t = { failures : failure list; terminal : terminal }

val empty : t
val observe_failure :
  runtime_id:string -> attempt:int -> dispatch:Runtime_attempt_dispatch.t ->
  Agent_core.Error.t -> failure
val observe_terminal : runtime_id:string -> attempt:int -> Agent_core.Error.t -> terminal
val to_yojson : t -> Yojson.Safe.t
val to_observation_yojson : t -> Yojson.Safe.t
(** Read-only presentation of the same facts, with summaries computed by
    {!Keeper_request_failure.summary} on each failure and candidate terminal.
    The canonical storage codec above has no derived summary fields. *)
val of_yojson : Yojson.Safe.t -> (t, string) result
(** Strict wire decoder: unknown/extra/duplicate fields and enum values are
    errors. An absent receipt field is not an observed empty failure list. *)
