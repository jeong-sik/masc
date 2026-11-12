(** Words for the Keepers fleet header, in the screen language: [~ko] picks
    Korean. The comments below quote the English wording. *)

val status_text : ko:bool -> Masc.Keeper_fleet_grade.t -> string
(** The grade in the screen language. The English word is the grade's wire
    name. *)

val status_is_ok : Masc.Keeper_fleet_grade.t -> bool
(** Whether the fleet header draws in the healthy colour: only [ok] does. *)

val blocker_text : ko:bool -> Masc.Fleet_stream.fleet -> string option
(** The first reason the fleet scan names, in the words the counts line below
    uses for the same Keepers. The line below carries the numbers, so this
    names the reason only. [None] when the scan names no blocker. *)

val interval_text : Masc.Fleet_stream.Proactive_interval.t -> string
(** The interval in the largest unit that divides it exactly: [1h] for 3600
    seconds, [5m] for 300. Any other value is
    {!Masc_tui_message_layout.span_text}: [1m30s], [45s]. Never rounded, since
    it names a setting. *)

val proactive_text : ko:bool -> Masc.Fleet_stream.fleet -> string
(** [proactive every <interval>]: how far apart each Keeper's periodic turns
    start, one value for the fleet, as {!interval_text}. *)

val failing_text : ko:bool -> Masc.Fleet_stream.fleet -> string option
(** [failing N] with the classes that hold a failing Keeper, each class only
    when it holds one. [None] when nothing is failing. *)

val failure_text : ko:bool -> Masc_tui_fleet_stream.failure -> string
(** Why there is no fleet reading to draw, on one line. *)

val unavailable_text :
  ko:bool -> now:float -> degradation:Masc.Fleet_stream.degradation ->
  disconnected_since:float option -> string
(** A failed first scan and, if present, the separate connection loss. *)

val unreachable_text : ko:bool -> now:float -> since:float -> string
(** No reading was ever told and the stream is down: [not observed · stream
    lost <age> ago]. The age is left out when [now] is behind [since]. *)

val trouble_text : ko:bool -> now:float -> Masc_tui_fleet_stream.trouble -> string
(** What is wrong with the reading drawn beside it: [stale · scans failing for
    <age> (<reason>)] while the server's scans fail, [stale · stream lost <age>
    ago] while the connection is down. The age is counted from [now], and
    left out when [now] is behind the time it counts from. *)

val owner_scan_text : ko:bool -> Masc.Fleet_stream.fleet -> string option
(** [task owner without fiber N], and how many sources the scan could not read
    when any were unread -- their tasks are missing from [N]. [None] when the
    count is zero and the scan read everything. *)
