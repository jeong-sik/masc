(** Words for the Keepers fleet header. *)

val blocker_text : Masc.Tui_decode.fleet_safety -> string option
(** The first reason the fleet scan names, in the words the counts line below
    uses for the same Keepers. The line below carries the numbers, so this
    names the reason only. [None] when the server names no blocker. A blocker
    this build does not know is drawn as the server spelled it. *)

val failing_text : Masc.Tui_decode.fleet_safety -> string option
(** [failing N] with the classes that hold a failing Keeper, each class only
    when it holds one. [None] when nothing is failing. *)

val not_measured_text : Masc.Tui_decode.fleet_not_measured -> string
(** [not measured (<status>)], then [refresh timed out] when it did, then the
    server's reason when it gave one. Drawn where a reading would be, so an
    unmeasured fleet is not drawn as an idle one. *)

val owner_scan_text : Masc.Tui_decode.fleet_safety -> string option
(** [task owner without fiber N], and how many sources the scan could not read
    when any were unread -- their tasks are missing from [N]. [None] when the
    count is zero and the scan read everything. *)
