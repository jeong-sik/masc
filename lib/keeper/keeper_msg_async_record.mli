(** Pure current request records, strict identity decoding and client projection. *)
open Keeper_msg_async_types

val record_schema_version : int
val status_to_string : request_status -> string
val is_terminal_status : request_status -> bool
val access_rejection_to_json : access_rejection -> Yojson.Safe.t
val canonical_terminal_error_to_string : canonical_terminal_error -> string
val durable_terminal_entry : durable_terminal_proof -> entry
val submit_error_to_json : submit_error -> Yojson.Safe.t
val submit_outcome_to_json : submit_outcome -> Yojson.Safe.t
val cancel_result_to_json : request_id:string -> cancel_result -> Yojson.Safe.t
val entry_record_to_json : entry -> Yojson.Safe.t
val same_entry_record : entry -> entry -> bool
val normalize_request_context : (string * Yojson.Safe.t) list option -> ((string * Yojson.Safe.t) list option, string) result
val same_request_identity : entry -> entry -> bool
val entry_of_record_json : base_path:string -> request_id:string -> Yojson.Safe.t -> (entry, string) result
val entry_to_json : now:float -> entry -> Yojson.Safe.t
