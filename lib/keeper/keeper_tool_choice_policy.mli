(** Keeper-owned provider tool-choice admission.

    Keeper exposes a broad optional tool surface. A provider-level strict
    [Any] or named [Tool] choice would force a tool call even when the Keeper
    can answer or finish without one, so it is a configuration error. The
    requested value is never rewritten. *)

type rejection =
  | Forced_any
  | Forced_named of string

val rejection_to_string : rejection -> string

val validate_for_keeper :
  Agent_sdk.Types.tool_choice option
  -> (Agent_sdk.Types.tool_choice option, rejection) result
