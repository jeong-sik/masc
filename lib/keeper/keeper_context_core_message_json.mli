val role_to_string : Agent_sdk.Types.role -> string
val role_of_string_opt : string -> Agent_sdk.Types.role option

val content_blocks_to_json :
  Agent_sdk.Types.content_block list -> Yojson.Safe.t

val content_blocks_of_json :
  Yojson.Safe.t -> Agent_sdk.Types.content_block list option

val string_field_opt : string -> string option -> (string * Yojson.Safe.t) list
val metadata_of_json : Yojson.Safe.t -> (string * Yojson.Safe.t) list
val message_to_json : Agent_sdk.Types.message -> Yojson.Safe.t

(** Decode a persisted keeper message. Only canonical [content_blocks] are
    accepted; flat legacy [content] rows raise [Invalid_argument]. *)
val message_of_json : Yojson.Safe.t -> Agent_sdk.Types.message

val text_of_history_jsonl_json : Yojson.Safe.t -> string
