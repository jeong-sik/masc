(** Words for the Keepers fleet header. *)

val status_text : Masc.Keeper_fleet_grade.t -> string
(** The grade's wire name. *)

val status_is_ok : Masc.Keeper_fleet_grade.t -> bool
(** Whether the fleet header draws in the healthy colour: only [ok] does. *)

val blocker_text : Masc.Fleet_stream.fleet -> string option
(** The first reason the fleet scan names, in the words the counts line below
    uses for the same Keepers. The line below carries the numbers, so this
    names the reason only. [None] when the scan names no blocker. *)

val failing_text : Masc.Fleet_stream.fleet -> string option
(** [failing N] with the classes that hold a failing Keeper, each class only
    when it holds one. [None] when nothing is failing. *)

val failure_text : Masc_tui_fleet_stream.failure -> string
(** Why there is no fleet reading to draw, on one line. *)

val unavailable_text :
  now:float -> degradation:Masc.Fleet_stream.degradation ->
  disconnected_since:float option -> string
(** A failed first scan and, if present, the separate connection loss. *)

val unreachable_text : now:float -> since:float -> string
(** No reading was ever told and the stream is down: [not observed · stream
    lost <age> ago]. The age is left out when [now] is behind [since]. *)

val trouble_text : now:float -> Masc_tui_fleet_stream.trouble -> string
(** What is wrong with the reading drawn beside it: [stale · scans failing for
    <age> (<reason>)] while the server's scans fail, [stale · stream lost <age>
    ago] while the connection is down. The age is counted from [now], and
    left out when [now] is behind the time it counts from. *)

val owner_scan_text : Masc.Fleet_stream.fleet -> string option
(** [task owner without fiber N], and how many sources the scan could not read
    when any were unread -- their tasks are missing from [N]. [None] when the
    count is zero and the scan read everything. *)
