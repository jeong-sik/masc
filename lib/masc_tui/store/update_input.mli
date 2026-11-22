(** Raw terminal key, paste, and mouse input router delegating matched bindings
    to {!Update_actions}.

    Preserves hidden drafts whenever {!Nav.Micro_viewport} is active. *)

open Masc_tui_core
open Masc_tui_keymap

val apply_key_event :
  now:Clock.Mono.t -> Model.t -> Keymap.Input.key_event -> Model.t * Cmd.t list

val apply_paste :
  now:Clock.Mono.t -> Model.t -> string -> Model.t * Cmd.t list

val apply_mouse :
  now:Clock.Mono.t ->
  Model.t ->
  Keymap.Input.mouse_event ->
  Model.t * Cmd.t list
