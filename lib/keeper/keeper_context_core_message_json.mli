val role_to_string : Agent_sdk.Types.role -> string
val role_of_string_opt : string -> Agent_sdk.Types.role option
val role_of_string : string -> Agent_sdk.Types.role

val content_blocks_to_json :
  Agent_sdk.Types.content_block list -> Yojson.Safe.t

val content_blocks_of_json :
  Yojson.Safe.t -> Agent_sdk.Types.content_block list option

val legacy_content_text_of_json : Yojson.Safe.t -> string
val string_field_opt : string -> string option -> (string * Yojson.Safe.t) list
val metadata_of_json : Yojson.Safe.t -> (string * Yojson.Safe.t) list
val message_to_json : Agent_sdk.Types.message -> Yojson.Safe.t
val message_of_json : Yojson.Safe.t -> Agent_sdk.Types.message
val text_of_history_jsonl_json : Yojson.Safe.t -> string
