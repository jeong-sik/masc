module Reading = Masc.Tui_decode

(* The JUDGE column's marks. One place, because the column and the legend under
   it have to draw the same glyph: they were two literals before, and the
   legend was missing one of the six states outright.

   Colour belongs to the caller. A mark says which state a goal is in; which
   theme paints it is the surface's business. *)

(* Idle draws a blank. Nothing has been asked of the judge, and a glyph for
   that would mark every goal that has never been reviewed. *)
let idle_glyph = " "

type kind =
  | Waiting
  | Proven
  | Refused
  | Superseded
  | Unreadable

(* Each verdict is a status mark of RFC tui-one-screen-grammar 7.2: asked and
   not answered waits (○), approved is settled (●), refused is 반려 (✕), a
   criterion that moved under a standing proof is 오래됨 (▲). A ledger that did
   not decode is a value read and failed, whose mark is the failed one (6.4). *)
let status = function
  | Waiting -> Masc_tui_value.Mark.Waiting
  | Proven -> Masc_tui_value.Mark.Settled
  | Refused -> Masc_tui_value.Mark.Failed
  | Superseded -> Masc_tui_value.Mark.Caution
  | Unreadable -> Masc_tui_value.Mark.Failed

let mark kind = Masc_tui_value.Mark.glyph (status kind)

(* [None] is the blank: a state with no mark needs no word. *)
let kind_of_proof : Reading.goal_proof -> kind option = function
  | Reading.Proof_idle -> None
  | Reading.Proof_pending -> Some Waiting
  | Reading.Proof_proven _ -> Some Proven
  | Reading.Proof_refuted _ -> Some Refused
  | Reading.Proof_stale _ -> Some Superseded
  | Reading.Proof_unreadable _ -> Some Unreadable

(* The word is what to do about the mark, not a restatement of it. *)
let entry kind =
  ( mark kind
  , match kind with
    | Waiting -> "waiting"
    | Proven -> "proven"
    | Refused -> "refused, back in executing"
    | Superseded -> "criterion changed"
    | Unreadable -> "unreadable" )

let entry_korean kind =
  ( mark kind
  , match kind with
    | Waiting -> "판정 대기"
    | Proven -> "검증 통과"
    | Refused -> "거절 · 진행으로 복귀"
    | Superseded -> "기준 변경"
    | Unreadable -> "판정 기록 읽기 실패" )

(* The order a goal travels, so the legend reads the same whichever subset of
   it a screen needs. *)
let kinds = [ Waiting; Proven; Refused; Superseded; Unreadable ]

let glyph proof =
  match kind_of_proof proof with
  | None -> idle_glyph
  | Some kind -> mark kind

let tone proof = Option.map status (kind_of_proof proof)

let legend_for ~ko = List.map (if ko then entry_korean else entry) kinds

let legend = legend_for ~ko:false

let legend_rows ~ko ~max_cells ~max_rows proofs =
  let label = if ko then "  판정  " else "  JUDGE  " in
  let label_cells = Masc_tui_message_layout.display_width label in
  if max_cells <= label_cells || max_rows <= 0 then []
  else
    let text =
      (let present = List.filter_map kind_of_proof proofs in
       List.filter_map (fun kind ->
         if List.mem kind present then Some ((if ko then entry_korean else entry) kind) else None) kinds)
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
