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

(* "2026-07-28T03:57:38Z" -> "07-28 03:57"; anything shorter is shown as-is
   rather than guessed at. *)
let short_ts ts =
  if String.length ts >= 16 then
    String.sub ts 5 5 ^ " " ^ String.sub ts 11 5
  else ts

let severity_tone = function
  | "ok" -> Quiet
  | "warn" -> Waiting
  | "bad" -> Refused
  | _ -> Note

(* Which thing the row is about, and what it is.

   The server sends six fields and the pane drew two of them -- the kind and
   the summary -- so a goal with thirteen task rows drew "task  todo" thirteen
   times. The id and the title were in the payload the whole time.

   [lane] is the typed reference ("task:task-1013", "approval:appr-...",
   "keeper:<name>", "goal"). Its id half is the subject where it has one; a
   lane with no id is a goal's own event, and there the kind is what names it,
   so that is what the column keeps rather than the bare word "goal". *)
let subject (event : Tui_decode.goal_timeline_event) =
  match String.index_opt event.gt_lane ':' with
  | Some index ->
      String.sub event.gt_lane (index + 1)
        (String.length event.gt_lane - index - 1)
  | None -> event.gt_kind

(* Wide enough for "task-1013" and a uuid-shaped approval id's readable head.
   The column is padded so the titles start at one place down the block; what
   overruns is cut by [fit_width], which marks the cut. *)
let subject_column = 18

(* Title first, state after: the title names the row and the summary qualifies
   it. A task's summary is its status ("todo"), an approval's is its input
   preview, a keeper's is its event summary -- none of them identify the row on
   their own, which is why the pane read as a list of statuses with nothing
   attached. A summary that only repeats the title adds nothing and is
   dropped. *)
let headline (event : Tui_decode.goal_timeline_event) =
  let title = String.trim event.gt_title in
  let summary = String.trim event.gt_summary in
  if String.equal summary "" || String.equal summary title then title
  else if String.equal title "" then summary
  else title ^ "  \xc2\xb7 " ^ summary

(* The goal's merged event timeline, appended after [body] so it rides the
   same scroll. Loaded lazily on detail entry; every non-ready state says
   what it is instead of rendering as an empty history. *)
let timeline ~width ~goal_id
    (loaded : (string * (Tui_decode.goal_timeline, string) result) option) =
  let header = { tone = Note; text = "TIMELINE" } in
  let rows =
    match loaded with
    | Some (id, result) when String.equal id goal_id -> (
        match result with
        | Ok (Tui_decode.Goal_timeline_ready []) ->
            [ { tone = Quiet; text = "  (no events recorded)" } ]
        | Ok (Tui_decode.Goal_timeline_ready events) ->
            List.concat_map
              (fun (event : Tui_decode.goal_timeline_event) ->
                let tone = severity_tone event.gt_severity in
                wrapped ~width tone
                  (Printf.sprintf "  %s  %s  %s" (short_ts event.gt_ts)
                     (Message_layout.fit_width (subject event) subject_column)
                     (headline event)))
              events
        | Ok (Tui_decode.Goal_timeline_unavailable detail) ->
            wrapped ~width Unreadable ("  timeline unavailable: " ^ detail)
        | Error err ->
            wrapped ~width Unreadable ("  timeline load failed: " ^ err))
    | _ -> [ { tone = Quiet; text = "  loading..." } ]
  in
  ({ tone = Quiet; text = "" } :: header :: rows)
