(** Message Schema: Structured message validation for MASC *)

type validation_mode = Strict | Warn | Permissive

val validation_mode_of_string : string -> validation_mode
val validation_mode_to_string : validation_mode -> string

type structured_message =
  | TaskUpdate of { task_id: string; status: string; payload: Yojson.Safe.t option; }
  | StatusReport of { agent: string; progress: float; details: string; }
  | Request of { target: string; action: string; params: Yojson.Safe.t; }
  | Response of { request_id: string; success: bool; result: Yojson.Safe.t; }
  | Freeform of string

val show_structured_message : structured_message -> string
val equal_structured_message : structured_message -> structured_message -> bool
val to_json : structured_message -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (structured_message, string) result
val validate : ?mode:validation_mode -> string -> (structured_message, string) result
val message_type_string : structured_message -> string
val is_targeted_at : string -> structured_message -> bool
val json_schema : Yojson.Safe.t
val roundtrip : structured_message -> (structured_message, string) result
