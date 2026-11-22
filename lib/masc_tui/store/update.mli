(** Pure deterministic TEA reducer for MASC TUI v2.

    Every incoming event flows through {!step}, guarded by {!Epoch.is_current}
    for asynchronous replies, preserving strict 3-channel health/attention/
    incident separation, zero idle polling, loop-free [409 workspace_mismatch]
    recovery, and automatic bounded {!Subscriptions.plan} synchronization. *)

open Masc_tui_core
open Masc_tui_keymap

val step : now:Clock.Mono.t -> Model.t -> Msg.t -> Model.t * Cmd.t list

val execute_action :
  now:Clock.Mono.t -> Model.t -> Keymap.action -> Model.t * Cmd.t list

val execute_slash :
  now:Clock.Mono.t -> Model.t -> Slash.parsed -> Model.t * Cmd.t list

val fetches_for_current_view : ?force:bool -> Model.t -> Cmd.t list
