(** Navigation, dive stack, filter queries, palette filtering, inline modal
    submission, voice PTT, [/btw] side-query, and Channel 1 fast-path approval
    helpers shared by {!Update_actions} and {!Update_input}. *)

open Masc_tui_core
open Masc_tui_keymap
open Masc_tui_protocol

val drop_last_utf8 : string -> string
val clamp_index : int -> int -> int
val fuzzy_score : query:string -> string -> int option

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

type palette_action =
  | Pal_keymap_action of Keymap.action
  | Pal_switch_workspace of Nav.workspace
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
val palette_len : Model.t -> int

val switch_workspace : Model.t -> Nav.workspace -> Model.t * Cmd.t list
val open_overlay : Model.t -> Nav.overlay -> Model.t * Cmd.t list
val open_global_settings :
  ?search_query:string -> Model.t -> Model.t * Cmd.t list
val select_settings_tab : Model.t -> Nav.settings_tab -> Model.t * Cmd.t list
val open_inline_modal : Model.t -> Nav.inline_action_kind -> Model.t * Cmd.t list
val open_palette : Model.t -> Model.palette_mode -> Model.t * Cmd.t list
val push_dive : Model.t -> Nav.dive -> Model.t * Cmd.t list
val sync_config_for_keeper_view : Model.t -> Model.t
val cycle_sub_tab : Model.t -> Keymap.cycle_dir -> Model.t * Cmd.t list
val dive_selected : Model.t -> Model.t * Cmd.t list

val current_filter_query : Model.t -> string
val set_active_filter_query : string -> Model.t -> Model.t

val palette_filtered_commands : Model.t -> Keymap.palette_command list
val palette_filtered_keepers : Model.t -> Wire_fleet.keeper_summary list
val palette_filtered_models : Model.t -> Wire_runtime.runtime_option list

val resolve_target_keeper : Model.t -> string option
val build_chat_submit_cmd :
  Model.t -> Drafts.pending_message -> is_btw:bool -> Cmd.t

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
val clamp_for_pane : Model.t -> Model.t
val apply_move : Model.t -> Keymap.move_dir -> Model.t * Cmd.t list
