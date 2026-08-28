module Message_layout = Masc_tui_message_layout
module Tui_decode = Masc.Tui_decode

(* The field is one wider than the longest label ("reviewed:") so every value
   keeps one gap after its colon. *)
let timestamp_line ~label value =
  Printf.sprintf "  %-10s%s" (label ^ ":") value

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

let wrapped ~width tone text =
  Message_layout.wrap_words ~max_cells:width text
  |> List.map (fun text -> { tone; text })

(* A verdict is a headline and, when the judge left one, the measurement it
   rests on. They are separate rows because the reason wraps and the headline
   should stay findable at the top of the block. *)
let verdict ~width tone headline reason =
  { tone; text = headline }
  :: (match reason with
      | None -> []
      | Some reason -> wrapped ~width tone reason)

let note ~width = function
  | None -> []
  | Some note -> { tone = Note; text = "note" } :: wrapped ~width Note note

let body ~width proof last_review_note =
  let width = max 1 width in
  match (proof : Tui_decode.goal_proof) with
  | Tui_decode.Proof_proven reason ->
      verdict ~width Proven "proven" reason @ note ~width last_review_note
  | Tui_decode.Proof_refuted reason ->
      verdict ~width Refused "refused" reason @ note ~width last_review_note
  | Tui_decode.Proof_pending ->
      { tone = Waiting; text = "waiting for the completion judge" }
      :: note ~width last_review_note
  | Tui_decode.Proof_unreadable detail ->
      verdict ~width Unreadable "verification ledger unreadable" detail
      @ note ~width last_review_note
  | Tui_decode.Proof_idle ->
      (match note ~width last_review_note with
       | [] -> [ { tone = Quiet; text = "no verdict on the ledger" } ]
       | rows -> { tone = Quiet; text = "no verdict on the ledger" } :: rows)
