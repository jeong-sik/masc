(** Canonical keeper state-reporting contract.

    This module owns the model-facing [STATE] instruction, recovery wording,
    and retired state-reporting tool tokens. Prompt files may render prose
    around this contract, but they must not re-declare retired tool surfaces. *)

type surface =
  | State_block

type field =
  | Done
  | Next
  | Goal
  | Decisions
  | OpenQuestions
  | Constraints

val version : string
val surface : surface
val surface_to_string : surface -> string
val all_fields : field list
val field_name : field -> string
val field_summary : string
val template_text : string
val instruction_text : string
val recovery_line : string
val output_guard_text : string
val forbidden_tool_tokens : string list

val forbidden_tool_tokens_in_text : string -> string list
(** Return canonical retired/forbidden state-reporting tool tokens that appear
    as standalone tool-like tokens in [text], de-duplicated in contract order. *)
