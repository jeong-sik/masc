(** Compile-time exhaustive {!Keymap.action} and {!Slash.parsed} reducers. *)

open Masc_tui_core
open Masc_tui_keymap

val execute_action :
  now:Clock.Mono.t -> Model.t -> Keymap.action -> Model.t * Cmd.t list

val execute_slash :
  now:Clock.Mono.t -> Model.t -> Slash.parsed -> Model.t * Cmd.t list

val apply_staged_tui_pref_if_needed :
  now:Clock.Mono.t ->
  key:string ->
  Model.t ->
  Config_store.t ->
  (Model.t * Cmd.t list) option

val save_settings_config :
  now:Clock.Mono.t -> Model.t -> Model.t * Cmd.t list

val dry_run_settings_config :
  now:Clock.Mono.t -> Model.t -> Model.t * Cmd.t list

val step_settings_pane_lr :
  now:Clock.Mono.t -> Model.t -> Keymap.move_dir -> Model.t * Cmd.t list

val step_artifact_search :
  now:Clock.Mono.t -> delta:int -> Model.t -> Model.t * Cmd.t list

val open_goal_confirmation_proof_modal :
  Model.t -> goal_id:string -> criterion_revision:string -> Model.t * Cmd.t list

val open_runtime_assign_modal :
  Model.t ->
  ?keeper_default:string ->
  ?runtime_default:string ->
  unit ->
  Model.t * Cmd.t list
