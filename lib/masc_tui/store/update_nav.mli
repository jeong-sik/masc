(** Navigation, dive stack, filter queries, palette filtering, inline modal
    submission, voice PTT, [/btw] side-query, and Channel 1 fast-path approval
    helpers shared by {!Update_actions} and {!Update_input}. *)

open Masc_tui_core
open Masc_tui_keymap
open Masc_tui_protocol

val drop_last_utf8 : string -> string
val clamp_index : int -> int -> int

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
val apply_move : Model.t -> Keymap.move_dir -> Model.t * Cmd.t list
