(** Form naming and action-line notices for [$EDITOR] round-trips. *)

type connector_change =
  | Channel_bind
  | Channel_unbind
  | Channel_binding_edit

type editor_form =
  | Board_draft
  | Code_draft
  | Gate_rejection
  | Connector_form of connector_change
  | Harness_overrule
  | Verification_rejection
  | Task_cancellation
  | Runtime_config_text
  | Skill_creation
  | Original_request_lookup
  | Skill_source of string
  | Prompt_text of string
  | Keeper_settings of string
  | Keeper_creation
  | Repository_addition
  | Schedule_form of Masc_tui_types.schedule_change

val form_name : ko:bool -> editor_form -> string
val report_abort : Masc_tui_types.state -> form:editor_form -> Masc_tui_editor.abort -> unit
val report_unset : Masc_tui_types.state -> form:editor_form -> unit
val editor_jump_unset : Masc_tui_types.state -> string
