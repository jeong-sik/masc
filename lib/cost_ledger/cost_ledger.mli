(** Current cost-ledger row and store contract.

    This module owns the single current wire decoder used by the manual CLI
    and inference metrics. It does not read or translate alternate stores or
    field names. *)

(** Runtime-owned identity for one inference. [agent_core_turn_ordinal] is the exact
    zero-based ordinal carried by AGENT_CORE [AfterTurn], not a value reconstructed
    from a completed-turn count. *)
type inference_identity =
  { trace_id : string
  ; keeper_turn_id : int
  ; agent_core_turn_ordinal : int
  }

type source =
  | Manual_cli
  | Auto_trajectory of inference_identity

(** What a row's counts are.

    [Raw_observation scope] is a count exactly as a runtime reported it, and
    [scope] says what that count covers: one provider request, one
    official-client turn, or the conversation so far. Raw rows of different
    scopes do not add up to a spend; a conversation-cumulative row repeats
    every earlier turn. A raw row without a scope does not decode.

    [Resolved_delta] is one Keeper turn's spend, resolved from those
    observations: the spend its decision record describes.

    [Resolved_attempt_delta reading] is the spend of one reading of one
    attempt that no decision record describes: an attempt of a failed turn,
    or one a later attempt replaced. It is a spend like [Resolved_delta] and
    adds to it. *)
type attempt_reading =
  { lane_attempt_index : int
  ; reading_index : int
        (** The reading's position in its attempt. An official client can
            number two client turns of one attempt alike, so the ordinal
            alone does not name a reading. *)
  }

type usage_projection =
  | Raw_observation of Runtime_usage_scope.t
  | Resolved_delta
  | Resolved_attempt_delta of attempt_reading

type usage =
  | Usage_missing
  | Usage_reported of
      { input_tokens : int
      ; output_tokens : int
      ; cost_usd : float
      }

type t =
  { agent : string
  ; task_id : string option
  ; model : string
  ; usage : usage
  ; usage_projection : usage_projection
  ; timestamp : string
  ; ts_unix : float
  ; source : source
  }

type decode_error

val decode_error_to_string : decode_error -> string
(** What a row counts, for pairing it with a decision record and refusing
    two rows that claim the same thing. A turn's resolved spend pairs with
    its decision by the turn and its ordinal; an attempt reading has no
    decision and is named by its attempt and position as well. *)
type inference_key =
  | Turn_inference of inference_identity
  | Attempt_inference of
      { turn : inference_identity
      ; attempt : attempt_reading
      }

val compare_inference_key : inference_key -> inference_key -> int
val inference_key : t -> inference_key option

val to_json :
  ?extra_fields:(string * Yojson.Safe.t) list -> t -> Yojson.Safe.t
(** Serialize the current row. Required contract fields always win over
    caller-supplied [extra_fields]. *)

val of_json : Yojson.Safe.t -> (t, decode_error) result
(** Decode only the current row contract. *)

val store_of_masc_root : string -> Dated_jsonl.t
val store_of_base_path : base_path:string -> Dated_jsonl.t
