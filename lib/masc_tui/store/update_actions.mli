(** Compile-time exhaustive {!Keymap.action} and {!Slash.parsed} reducers. *)

open Masc_tui_core
open Masc_tui_keymap

val execute_action :
  now:Clock.Mono.t -> Model.t -> Keymap.action -> Model.t * Cmd.t list

val execute_slash :
  now:Clock.Mono.t -> Model.t -> Slash.parsed -> Model.t * Cmd.t list
