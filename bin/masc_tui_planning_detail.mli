(** What a goal's detail has to say under its header.

    The list already draws the judge's verdict and its reason on the line
    under the cursor -- the reason being, as that code says, the only thing
    that says what to do next. The detail drew neither, so opening a goal
    showed less than the row it was opened from, and the two fields the
    surface decodes for it went nowhere.

    This is the block that fills the gap, and the rows it produces are what
    the detail's scroll moves through. *)

type tone =
  | Proven
  | Refused
  | Waiting
  | Unreadable
  | Note
  | Quiet

type line =
  { tone : tone
  ; text : string
  }

module Tui_decode = Masc.Tui_decode

val timestamp_line : label:string -> string -> string
(** One timeline row of the detail pane. The field is one wider than the
    longest label ("reviewed:"), so a value never starts immediately after
    its colon. *)

val body :
  width:int -> Tui_decode.goal_proof -> string option -> line list
(** The verdict, its reason, and the keeper's own note, wrapped to [width].

    An idle ledger with no note still says so: an empty block would read as a
    goal nobody has looked at, which is the same picture a goal whose verdict
    failed to decode would draw. *)

val short_ts : string -> string
(** "2026-07-28T03:57:38Z" -> "07-28 03:57"; anything shorter is shown as-is
    rather than guessed at. Shared with the task-history rows. *)

val timeline :
  width:int ->
  goal_id:string ->
  (string * (Tui_decode.goal_timeline, string) result) option ->
  line list
(** The goal's merged event timeline, appended after [body] so it rides the
    same scroll. Loaded lazily on detail entry; every non-ready state (still
    loading, store unavailable, load failed, stale answer for another goal)
    says what it is instead of rendering as an empty history. *)
