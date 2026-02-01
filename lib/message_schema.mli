(** Message Schema: Structured message validation for MASC

    Provides compile-time message type safety via OCaml variants,
    with configurable runtime validation for backward compatibility. *)

(** Validation mode for incoming messages *)
type validation_mode =
  | Strict     (** Reject non-conforming messages *)
  | Warn       (** Accept but caller should log warning *)
  | Permissive (** Accept all, wrap unknown as Freeform *)

val validation_mode_of_string : string -> validation_mode
val validation_mode_to_string : validation_mode -> string

(** Structured message types *)
type structured_message =
  | TaskUpdate of {
      task_id: string;
      status: string;
      payload: Yojson.Safe.t option;
    }
  | StatusReport of {
      agent: string;
      progress: float;
      details: string;
    }
  | Request of {
      target: string;
      action: string;
      params: Yojson.Safe.t;
    }
  | Response of {
      request_id: string;
      success: bool;
      result: Yojson.Safe.t;
    }
  | Freeform of string

val show_structured_message : structured_message -> string
val equal_structured_message : structured_message -> structured_message -> bool

(** Serialize to JSON *)
val to_json : structured_message -> Yojson.Safe.t

(** Deserialize from JSON *)
val of_json : Yojson.Safe.t -> (structured_message, string) result

(** Validate raw message string with mode *)
val validate : ?mode:validation_mode -> string -> (structured_message, string) result

(** Get message type name for logging *)
val message_type_string : structured_message -> string

(** Check if message targets specific agent *)
val is_targeted_at : string -> structured_message -> bool

(** JSON Schema for MCP tool documentation *)
val json_schema : Yojson.Safe.t

(** Roundtrip test helper *)
val roundtrip : structured_message -> (structured_message, string) result
