module Reading = Masc_tui_types

(* The Board's leftmost column: who put the post there. One place, because the
   column and the help sheet have to draw the same glyph -- and because nothing
   explained these marks anywhere. A reader met "@" and had to guess.

   The column exists for the ratio. On this workspace's 2171 posts, 1561 were
   the system's, 588 an automation's, and 22 a person's. Those 22 are the
   reason for the column, and "@" was the unexplained mark standing in front of
   them. Colour belongs to the caller. *)

let person_glyph = "@" (* a person typed it *)
let automation_glyph = "\xe2\x97\x90" (* ◐ a keeper or a lane *)
let unknown_glyph = "?" (* a kind this build was not taught *)

(* The system's posts are the ground -- two thirds of the board -- and marking
   the majority marks nothing. A post whose kind the wire did not say draws the
   same blank: both mean "no mark to give", and the two are not told apart in
   this column today. *)
let no_mark = " "

type kind =
  | Person
  | Automation
  | Unknown

let kind_of_post : Reading.board_post_kind option -> kind option = function
  | Some Reading.Post_by_person -> Some Person
  | Some Reading.Post_by_automation -> Some Automation
  | Some (Reading.Post_kind_unknown _) -> Some Unknown
  | Some Reading.Post_by_system -> None
  | None -> None

(* The word says who, not what the glyph looks like. *)
let entry = function
  | Person -> (person_glyph, "a person wrote it")
  | Automation -> (automation_glyph, "a keeper or a lane wrote it")
  | Unknown -> (unknown_glyph, "a kind this build was not taught")

let kinds = [ Person; Automation; Unknown ]

let glyph post_kind =
  match kind_of_post post_kind with
  | None -> no_mark
  | Some kind -> fst (entry kind)

let legend = List.map entry kinds
