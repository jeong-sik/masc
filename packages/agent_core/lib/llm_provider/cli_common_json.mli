(** Thin wrappers over [Yojson.Safe.Util] that return safe defaults
    instead of raising on missing or mistyped fields.

    Shared across non-interactive CLI transports (Claude Code, Gemini CLI,
    Codex CLI) so that loosely-typed CLI output is parsed consistently. *)

(** [member_str key json] returns the string at [key], or [""] when the
    field is missing or not a string. *)
val member_str : string -> Yojson.Safe.t -> string

(** [member_int key json] returns the int at [key], or [0] when the
    field is missing or not an int. *)
val member_int : string -> Yojson.Safe.t -> int

(** [member_bool key json] returns the bool at [key], or [false] when
    the field is missing or not a bool. *)
val member_bool : string -> Yojson.Safe.t -> bool
