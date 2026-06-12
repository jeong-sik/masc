(** Prompt tool-token audit for rendered keeper instructions.

    The audit checks model-facing instruction text for tool-looking names that
    either resolve to no current tool surface or are explicitly retired by a
    domain contract. Runtime use should audit system prompts, not user messages,
    to avoid treating operator prose as prompt drift. *)

type violation =
  { token : string
  ; reason : string
  }

val tool_like_tokens : string -> string list
val violations : string -> violation list
val violation_to_json : violation -> Yojson.Safe.t
