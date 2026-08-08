(** Dune-private implementation and stable JSON vocabulary for output-token
    receipts.  {!Types} re-exports the public surface. *)

type envelope =
  | Openai_chat_max_tokens
  | Openai_responses_max_output_tokens
  | Anthropic_messages_max_tokens
  | Gemini_generation_config_max_output_tokens
  | Ollama_options_num_predict
[@@deriving show, eq]

type policy =
  | Omitted
  | Explicit
  | Explicit_clamped
  | Required_catalog_fallback
  | Required_capability_override_fallback
[@@deriving show, eq]

type ceiling_source =
  | Catalog_model
  | Declared_capability_override
  | Provider_default
[@@deriving show, eq]

val envelope_to_yojson : envelope -> Yojson.Safe.t
val envelope_of_yojson : Yojson.Safe.t -> (envelope, string) result
val policy_to_yojson : policy -> Yojson.Safe.t
val policy_of_yojson : Yojson.Safe.t -> (policy, string) result
val ceiling_source_to_yojson : ceiling_source -> Yojson.Safe.t
val ceiling_source_of_yojson : Yojson.Safe.t -> (ceiling_source, string) result

type ceiling =
  { value : int
  ; source : ceiling_source
  }
[@@deriving show, eq]

val ceiling : value:int -> source:ceiling_source -> ceiling

type receipt
type required_error = Required_output_token_ceiling_missing [@@deriving show, eq]

val optional_receipt
  :  envelope:envelope
  -> requested:int option
  -> ceiling:ceiling option
  -> receipt

val required_receipt : receipt -> (receipt, required_error) result
val receipt_envelope : receipt -> envelope
val receipt_requested : receipt -> int option
val receipt_effective : receipt -> int option
val receipt_policy : receipt -> policy
val receipt_ceiling : receipt -> int option
val receipt_ceiling_source : receipt -> ceiling_source option
val receipt_to_yojson : receipt -> Yojson.Safe.t
val receipt_of_yojson : Yojson.Safe.t -> (receipt, string) result
val equal_receipt : receipt -> receipt -> bool
val pp_receipt : Format.formatter -> receipt -> unit
val show_receipt : receipt -> string
