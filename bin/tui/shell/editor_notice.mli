(** Action-line and kept-back request notices for $EDITOR round-trips and
    workspace-guarded operations. *)

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
val select_keeper_first : ko:bool -> string

val report_kept_back
  :  Masc_tui_types.state
  -> request:Masc_tui_words.Kept_request.t
  -> (ko:bool -> string)
  -> Masc_tui_words.kept
  -> unit

val report_withdrawn
  :  Masc_tui_types.state
  -> request:Masc_tui_words.Kept_request.t
  -> Masc_tui_types.workspace_refusal
  -> unit

val said_read_result
  :  Masc_tui_types.state
  -> request:Masc_tui_words.Kept_request.t
  -> ('a, Masc_tui_types.request_failure) result
  -> ('a, string) result

val workspace_response_refusal_text
  :  Masc_tui_types.state
  -> request:Masc_tui_words.Kept_request.t
  -> Masc_tui_types.workspace_refusal
  -> string

val request_failure_after_read
  :  Masc_tui_types.state
  -> request:Masc_tui_words.Kept_request.t
  -> Masc_tui_types.request_failure
  -> Masc_tui_types.request_failure

val kept_back_until_reconnect
  :  ko:bool
  -> request:Masc_tui_words.Kept_request.t
  -> string

val editor_jump_unset : Masc_tui_types.state -> string
