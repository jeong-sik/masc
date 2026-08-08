(** Private HTTP wire-codec projection used by Complete sync and stream paths.

    The Dune library marks this module private, so external OAS consumers keep
    using [Provider_config] and [Complete] without a codec-selection API. *)

type t = private
  | Anthropic_messages
  | Openai_chat
  | Openai_responses
  | Ollama_chat
  | Gemini_generate_content
  | Glm_chat

type json_schema_wire =
  | Raw_schema
  | Openai_named_schema

(** Project one validated provider config to its serializer/parser contract.

    [Kimi] always selects Anthropic Messages, including through a custom proxy
    path. Kimi's OpenAI-compatible endpoint must be declared as
    [Provider_config.OpenAI_compat]. Model and provider-name strings never
    select the codec. *)
val of_config : Provider_config.t -> t

(** Version-stable identifier for canonical request fingerprints. *)
val fingerprint_tag : t -> string

(** Serializer-owned schema shape for this wire codec. *)
val json_schema_wire : t -> json_schema_wire

(** Whether this wire codec has a concrete JSON-mode serializer. *)
val supports_json_mode : t -> bool
