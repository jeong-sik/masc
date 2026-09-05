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

type usage_projection = Raw_observation | Resolved_delta

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
val source_to_string : source -> string
val compare_inference_identity : inference_identity -> inference_identity -> int
val inference_identity : t -> inference_identity option

val to_json :
  ?extra_fields:(string * Yojson.Safe.t) list -> t -> Yojson.Safe.t
(** Serialize the current row. Required contract fields always win over
    caller-supplied [extra_fields]. *)

val of_json : Yojson.Safe.t -> (t, decode_error) result
(** Decode only the current row contract. *)

val store_of_masc_root : string -> Dated_jsonl.t
val store_of_base_path : base_path:string -> Dated_jsonl.t
