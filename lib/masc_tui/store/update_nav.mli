(** Navigation, dive stack, filter queries, palette filtering, inline modal
    submission, voice PTT, [/btw] side-query, and Channel 1 fast-path approval
    helpers shared by {!Update_actions} and {!Update_input}. *)

open Masc_tui_core
open Masc_tui_keymap
open Masc_tui_protocol

val drop_last_utf8 : string -> string
val clamp_index : int -> int -> int
val fuzzy_score : query:string -> string -> int option

val insert_at_cursor : text:string -> cursor:int -> insert:string -> string * int
val backspace_at_cursor : text:string -> cursor:int -> string * int
val delete_at_cursor : text:string -> cursor:int -> string * int
val move_cursor_utf8 :
  [ `Left | `Right | `Home | `End ] -> text:string -> cursor:int -> int
val kill_to_start : text:string -> cursor:int -> string * int
val kill_word_back : text:string -> cursor:int -> string * int
val btw_max_scroll : Model.t -> int

(** {1 Shared Composer Slash & Mention Popup SSOT} *)

type popup_candidate_kind =
  | Popup_slash_cmd of Slash.spec
  | Popup_slash_arg of {
      spec : Slash.spec;
      arg : string;
      full_text : string;
    }
  | Popup_mention of Wire_fleet.keeper_summary

type popup_candidate = {
  kind : popup_candidate_kind;
  trigger : string;
  label : string;
  detail : string option;
}

type composer_popup =
  | Composer_popup_none
  | Composer_popup_slash of {
      query : string;
      items : popup_candidate list;
      selected : int;
    }
  | Composer_popup_mention of {
      query : string;
      items : popup_candidate list;
      selected : int;
    }

val slash_spec_takes_arg : Slash.spec -> bool
val slash_spec_requires_arg : Slash.spec -> bool

type queue_run_next = {
  keeper : string;
  request_id : string;
  body : string;
  interrupt_token : string option;
}

val queue_run_next_target : Model.t -> queue_run_next option
(** The visible first queued request owned by this TUI session, with the
    exact currently observed turn that its action can interrupt. *)
val resolve_composer_popup : Model.t -> composer_popup
val apply_popup_completion : popup_candidate -> Model.t -> Model.t

(** {1 Unified Universal Palette SSOT} *)

type palette_section =
  | Pal_sec_commands
  | Pal_sec_workspaces
  | Pal_sec_keepers
  | Pal_sec_companies
  | Pal_sec_goals_tasks
  | Pal_sec_board_wiki
  | Pal_sec_sandboxes
  | Pal_sec_settings
  | Pal_sec_slash

type keeper_lifecycle_op =
  | Op_wake_or_online
  | Op_pause
  | Op_resume
  | Op_shutdown

type palette_action =
  | Pal_keymap_action of Keymap.action
  | Pal_keeper_lifecycle of {
      keeper : string;
      op : keeper_lifecycle_op;
    }
  | Pal_menu_target of Nav.menu_target
  | Pal_dive_keeper of string
  | Pal_select_company of string
  | Pal_dive_goal of string
  | Pal_dive_task of string
  | Pal_dive_thread of string
  | Pal_dive_wiki of string
  | Pal_dive_sandbox of string
  | Pal_open_infra_sandboxes of string
  | Pal_open_setting of {
      full_key : string;
      tab : Nav.settings_tab;
    }
  | Pal_slash_spec of Slash.spec

type palette_entry = {
  section : palette_section;
  badge : string;
  title : string;
  meta : string;
  tone : Theme.status_token option;
  action : palette_action;
}

val palette_entries : Model.t -> palette_entry list
val palette_entries_with_overflow :
  Model.t -> palette_entry list * (palette_section * int) list
val discord_sources_in_history : keeper:string -> Model.t -> Model.discord_source list
val palette_discord_sources : Model.t -> Model.discord_source list
val discord_reply_attempt : Model.t -> Nav.inline_action_kind -> Discord_reply_store.attempt option
val discord_reply_fields : Discord_reply_store.attempt option -> Model.inline_modal_state -> Model.modal_form_field list
val palette_len : Model.t -> int

val switch_workspace : Model.t -> Nav.workspace -> Model.t * Cmd.t list
val jump_to_workspace :
  ?pane_index:int ->
  ?zoomed:bool ->
  ?return_from:Model.t ->
  Model.t ->
  Nav.workspace ->
  Model.t * Cmd.t list
(** [jump_to_workspace m ws] pushes a return frame and opens [ws]. The frame
    is captured from [return_from] (default [m]); pass the model as it was
    before retargeting a destination tab so [Esc] restores the departure tab. *)
val jump_to_keeper :
  ?tab:Nav.keeper_tab ->
  ?trace_section:Keeper_context_store.trace_section ->
  ?zoomed:bool ->
  ?pane_index:int ->
  ?preserve_return:bool ->
  Model.t ->
  string ->
  Model.t * Cmd.t list
val jump_to_knowledge_thread :
  ?zoomed:bool -> ?return_from:Model.t -> Model.t -> string -> Model.t * Cmd.t list
val jump_to_knowledge_wiki :
  ?zoomed:bool -> ?return_from:Model.t -> Model.t -> string -> Model.t * Cmd.t list
val jump_to_goal :
  ?zoomed:bool -> ?return_from:Model.t -> Model.t -> string -> Model.t * Cmd.t list
val jump_to_task :
  ?zoomed:bool -> ?return_from:Model.t -> Model.t -> string -> Model.t * Cmd.t list
val knowledge_detail_max_scroll : Model.t -> int
val pop_workspace_return : Model.t -> (Model.t * Cmd.t list) option
val navigate_menu_target :
  ?keep_sidebar_focus:bool -> Model.t -> Nav.menu_target -> Model.t * Cmd.t list
val enter_sidebar_focus : Model.t -> Model.t
val exit_sidebar_focus : Model.t -> Model.t
val clear_btw_if_leaving : Model.t -> Drafts.t -> Drafts.t
val move_sidebar : Model.t -> Keymap.move_dir -> Model.t * Cmd.t list
val activate_sidebar_cursor : Model.t -> Model.t * Cmd.t list
val open_overlay : Model.t -> Nav.overlay -> Model.t * Cmd.t list
val open_global_settings :
  ?search_query:string -> Model.t -> Model.t * Cmd.t list
val select_settings_tab : Model.t -> Nav.settings_tab -> Model.t * Cmd.t list
val open_inline_modal : Model.t -> Nav.inline_action_kind -> Model.t * Cmd.t list
val open_harness_overrule_for_context :
  verdict:string -> now:Clock.Mono.t -> Model.t -> Model.t * Cmd.t list
val open_schedule_form_populated : Model.t -> Model.t * Cmd.t list
val check_verification_verdict_precondition :
  Model.t -> Wire_work.verification_request -> (unit, Say.t) result
val approve_verification_request :
  now:Clock.Mono.t ->
  Model.t ->
  Wire_work.verification_request ->
  Model.t * Cmd.t list
val reject_verification_request :
  now:Clock.Mono.t ->
  Model.t ->
  Wire_work.verification_request ->
  Model.t * Cmd.t list
val request_goal_complete_guarded :
  now:Clock.Mono.t -> Model.t -> Wire_work.goal -> Model.t * Cmd.t list
val task_dive_scroll_bounds : Model.t -> Wire_work.task -> int * int
val open_ask_modal :
  ?preselect_choice_1based:int ->
  Model.t ->
  Wire_work.ask_row ->
  Model.t * Cmd.t list
val submit_ask_modal : now:Clock.Mono.t -> Model.t -> Model.t * Cmd.t list
val skip_all_ask_questions :
  now:Clock.Mono.t -> Wire_work.ask_row -> Model.t -> Model.t * Cmd.t list
val open_palette : Model.t -> Model.palette_mode -> Model.t * Cmd.t list
val open_inspector : Model.t -> Nav.inspector -> Model.t * Cmd.t list
val close_inspector : ?preserve_overlay:bool -> Model.t -> Model.t * Cmd.t list
val sync_config_for_keeper_view : Model.t -> Model.t
val cycle_sub_tab : Model.t -> Keymap.cycle_dir -> Model.t * Cmd.t list
val keeper_enter_action :
  name:string -> tab:Nav.keeper_tab -> Model.t -> Model.t * Cmd.t list
val dive_selected : Model.t -> Model.t * Cmd.t list

val open_memory_diagram :
  now:Clock.Mono.t ->
  kind:Knowledge_store.memory_diagram_kind ->
  Model.t ->
  Model.t * Cmd.t list

val cycle_memory_diagram_mode :
  now:Clock.Mono.t -> Model.t -> Model.t * Cmd.t list

val refresh_open_memory_diagram :
  now:Clock.Mono.t -> Model.t -> Model.t * Cmd.t list

type enter_hint =
  | Enter_hint_hidden  (** Enter does nothing here. *)
  | Enter_hint_dos_screen
  | Enter_hint_dive  (** Enter dives, toggles, or fetches ([dive_selected]). *)
  | Enter_hint_memory_reading  (** Enter opens the selected memory record. *)
  | Enter_hint_edit_field  (** Keeper config: Enter edits the selected field. *)
  | Enter_hint_confirm_field
      (** Keeper config: Enter confirms the field being edited. *)

val enter_hint : Model.t -> enter_hint
(** What the footer's Enter hint says. It reads the plan [dive_selected] runs,
    and the Keeper config condition that takes Enter before the keymap, so the
    footer offers Enter only where the key acts and names what it does. *)

val current_filter_query : Model.t -> string
val set_active_filter_query : string -> Model.t -> Model.t * Cmd.t list
(** Set the filter of what is on screen. When the filter moves the Repos
    cursor to another repository, the commands ask for its activity. *)

val palette_filtered_commands : Model.t -> Keymap.palette_command list
val palette_filtered_keepers : Model.t -> Wire_fleet.keeper_summary list
val palette_filtered_models : Model.t -> Wire_runtime.runtime_option list

val resolve_target_keeper : Model.t -> string option

type steer_refusal =
  | Steer_turn_not_own
      (** No request this TUI submitted is streaming for the Keeper, so the
          busy turn belongs to someone else (another Keeper's delegated
          request, an autonomous or scheduled turn). *)
  | Steer_no_control_token
      (** The Keeper's chat control token has not reached this TUI yet. *)

type steer_resolution =
  | Steer_own of { control_token : string; operation_id : string }
      (** [operation_id] is this TUI's own streaming request. *)
  | Steer_refused of steer_refusal

val resolve_steer : keeper:string -> Model.t -> steer_resolution
(** What a steer submission may cut on [keeper]: only the operation of a
    request this TUI submitted and still streams. *)


val expected_workspace_of : Model.t -> Wire_work.expected_workspace option
(** The workspace [/health] reported, as a write's [expected_workspace]
    precondition; [None] until a full health read named it. *)

val build_chat_submit_cmd :
  Model.t ->
  Drafts.pending_message ->
  mode:Wire_fleet.submit_mode ->
  is_btw:bool ->
  Cmd.t

val start_btw_query :
  now:Clock.Mono.t -> prompt:string -> Model.t -> Model.t * Cmd.t list

val submit_ask_choice :
  now:Clock.Mono.t ->
  Wire_work.ask_row ->
  choice_1based:int ->
  Model.t ->
  Model.t * Cmd.t list

val fast_approve_top : now:Clock.Mono.t -> Model.t -> Model.t * Cmd.t list
val fast_deny_top : now:Clock.Mono.t -> Model.t -> Model.t * Cmd.t list
val teleport_blocked : now:Clock.Mono.t -> Model.t -> Model.t * Cmd.t list
val toggle_voice : now:Clock.Mono.t -> Model.t -> Model.t * Cmd.t list
val submit_inline_modal : now:Clock.Mono.t -> Model.t -> Model.t * Cmd.t list

val post_keeper_operator_note :
  keeper:string -> text:string -> modal_submission_id:int option ->
  Model.t -> Model.t * Cmd.t list

val clamp_for_pane : Model.t -> Model.t
val scroll_goal_dive_measure : delta:int -> goal_id:string -> Model.t -> Model.t
val incidents_detail_max_scroll : Model.t -> int
val pin_memory_diff_range : Model.t -> Model.t * Cmd.t list
val hidden_verif_toast_msg : Model.t -> Say.t
val apply_move : Model.t -> Keymap.move_dir -> Model.t * Cmd.t list

(** {1 Wave 3 Shared SSOT Projections & Scroll Line Builders} *)

type keeper_identity_entry =
  | Identity_oauth of {
      provider : string;
      label : string;
      attached : bool;
      enabled : bool option;
    }
  | Identity_github

val acting_keepers : Model.t -> string list
val keeper_facts_categories :
  Wire_knowledge.keeper_memory_facts ->
  (string * Wire_knowledge.keeper_ordinary_fact list) list
val code_fuzzy_matches : query:string -> Model.t -> string list
val keeper_identity_entries : Model.t -> name:string -> keeper_identity_entry list

type line_tone =
  | Line_plain
  | Line_selected
  | Line_section
  | Line_ok
  | Line_warn
  | Line_error
  | Line_accent

type styled_line = {
  tone : line_tone;
  text : string;
}

val fusion_detail_lines :
  width:int -> Model.t -> run_id:string -> styled_line list
val harness_verdict_detail_lines : width:int -> Model.t -> styled_line list
val addon_catalog_preview_lines :
  width:int -> Wire_runtime.addon_package_preview -> string list
val knowledge_memory_subview_lines :
  width:int -> Knowledge_store.t -> styled_line list
val keeper_memory_subview_lines :
  width:int -> name:string -> Knowledge_store.t -> styled_line list
val keeper_logs_lines :
  width:int -> name:string -> Keeper_context_store.keeper_state -> string list
val keeper_identity_lines :
  width:int -> name:string -> Model.t -> string list
val verification_dive_tab_lines :
  width:int -> Model.t -> Wire_work.verification_request -> styled_line list
val code_right_pane_line_count : Model.t -> int
val extract_embedded_json : string -> (string option * Yojson.Safe.t) option
