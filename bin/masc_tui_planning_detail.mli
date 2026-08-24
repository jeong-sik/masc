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

val body :
  width:int -> Tui_decode.goal_proof -> string option -> line list
(** The verdict, its reason, and the keeper's own note, wrapped to [width].

    An idle ledger with no note still says so: an empty block would read as a
    goal nobody has looked at, which is the same picture a goal whose verdict
    failed to decode would draw. *)
