(** Words for the Keepers fleet header. *)

val blocker_text : Masc.Tui_decode.fleet_safety -> string option
(** The first reason the fleet scan names, in the words the counts line below
    uses for the same Keepers. The line below carries the numbers, so this
    names the reason only. [None] when the server names no blocker. A blocker
    this build does not know is drawn as the server spelled it. *)

val failing_text : Masc.Tui_decode.fleet_safety -> string option
(** [failing N] with the classes that hold a failing Keeper, each class only
    when it holds one. [None] when nothing is failing. *)
