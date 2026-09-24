(** Words for the Keepers fleet header. *)

val blocker_text : Masc.Tui_decode.fleet_safety -> string option
(** The first reason the fleet scan names, in the words the counts line below
    uses for the same Keepers. The line below carries the numbers, so this
    names the reason only. [None] when the server names no blocker. A blocker
    this build does not know is drawn as the server spelled it. *)

val failing_text : Masc.Tui_decode.fleet_safety -> string option
(** [failing N] with the classes that hold a failing Keeper, each class only
    when it holds one. [None] when nothing is failing. *)

val not_measured_text : status:string -> string
(** [not measured yet (<status>)], drawn where a reading would be while the
    health snapshot is rebuilt, so an unmeasured fleet is not drawn as an idle
    one. *)

val freshness_text :
  now:float -> Masc.Tui_decode.fleet_reading_freshness -> string option
(** [None] for a reading the latest refresh measured. For the last good
    reading a stale snapshot still serves, [stale · measured <age> ago
    (<reason>)], the age counted from [now] and the reason as the server
    spelled it; without the age when [now] is behind the server's clock. For
    a snapshot status this build does not know, [health snapshot <word>]. *)

val owner_scan_text : Masc.Tui_decode.fleet_safety -> string option
(** [task owner without fiber N], and how many sources the scan could not read
    when any were unread -- their tasks are missing from [N]. [None] when the
    count is zero and the scan read everything. *)
