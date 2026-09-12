module Reading = Masc.Tui_decode

(* The JUDGE column's marks. One place, because the column and the legend under
   it have to draw the same glyph: they were two literals before, and the
   legend was missing one of the six states outright.

   Colour belongs to the caller. A mark says which state a goal is in; which
   theme paints it is the surface's business. *)

let waiting_glyph = "\xe2\x80\xa6" (* … the judge has been asked, not answered *)
let proven_glyph = "\xe2\x9c\x93" (* ✓ approved *)
let refused_glyph = "\xe2\x9c\x97" (* ✗ refused *)
let superseded_glyph = "~" (* the criterion moved under a proof that stands *)
let unreadable_glyph = "!" (* the ledger did not decode *)

(* Idle draws a blank. Nothing has been asked of the judge, and a glyph for
   that would mark every goal that has never been reviewed. *)
let idle_glyph = " "

type kind =
  | Waiting
  | Proven
  | Refused
  | Superseded
  | Unreadable

(* [None] is the blank: a state with no mark needs no word. *)
let kind_of_proof : Reading.goal_proof -> kind option = function
  | Reading.Proof_idle -> None
  | Reading.Proof_pending -> Some Waiting
  | Reading.Proof_proven _ -> Some Proven
  | Reading.Proof_refuted _ -> Some Refused
  | Reading.Proof_stale _ -> Some Superseded
  | Reading.Proof_unreadable _ -> Some Unreadable

(* The word is what to do about the mark, not a restatement of it. *)
let entry = function
  | Waiting -> (waiting_glyph, "waiting")
  | Proven -> (proven_glyph, "proven")
  | Refused -> (refused_glyph, "refused, back in executing")
  | Superseded -> (superseded_glyph, "criterion changed")
  | Unreadable -> (unreadable_glyph, "unreadable")

(* The order a goal travels, so the legend reads the same whichever subset of
   it a screen needs. *)
let kinds = [ Waiting; Proven; Refused; Superseded; Unreadable ]

let glyph proof =
  match kind_of_proof proof with
  | None -> idle_glyph
  | Some kind -> fst (entry kind)

let legend = List.map entry kinds

let legend_for proofs =
  let present = List.filter_map kind_of_proof proofs in
  List.filter_map
    (fun kind -> if List.mem kind present then Some (entry kind) else None)
    kinds

let legend_rows ~max_cells ~max_rows proofs =
  let label = "  JUDGE  " in
  let label_cells = Masc_tui_message_layout.display_width label in
  if max_cells <= label_cells || max_rows <= 0 then []
  else
    let text =
      legend_for proofs
      |> List.map (fun (mark, word) -> mark ^ " " ^ word)
      |> String.concat "  "
    in
    let rows =
      Masc_tui_message_layout.wrap_words
        ~max_cells:(max_cells - label_cells) text
    in
    if List.length rows > max_rows then []
    else
      List.mapi
        (fun index row ->
          (if index = 0 then label else String.make label_cells ' ') ^ row)
        rows
