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

type confirmation = {
  goal_id : string;
  phase : Goal_phase.t;
  verdict : Goal_verification.verdict;
}

let decode_confirmation ~goal_id json =
  let ( let* ) = Result.bind in
  let field name = function
    | `Assoc fields ->
        (match List.assoc_opt name fields with
         | Some value -> Ok value
         | None -> Error ("goal confirmation: missing " ^ name))
    | _ -> Error "goal confirmation: expected object"
  in
  let* goal = field "goal" json in
  let* id = field "id" goal in
  let* verification = field "verification" json in
  let* proof_goal = field "goal_id" verification in
  let* () =
    if id = `String goal_id && proof_goal = `String goal_id then Ok ()
    else Error "goal confirmation: goal identity mismatch"
  in
  let* phase_json = field "phase" goal in
  let* phase = Goal_phase.of_yojson phase_json in
  let* completion = field "completion" verification in
  let* completion = Goal_verification.completion_state_of_yojson completion in
  let* verdict =
    match phase, completion with
    | Goal_phase.Awaiting_confirmation, Goal_verification.Proof_proven verdict
    | Goal_phase.Completed, Goal_verification.Human_confirmed (verdict, _) -> Ok verdict
    | _ -> Error "goal confirmation: no current proven completion to confirm"
  in
  let* revision = field "criterion_revision" goal in
  let* title = field "title" goal in
  let* metric = field "metric" goal in
  let* target = field "target_value" goal in
  let* criterion = Goal_store.criterion_of_yojson
      (`Assoc ["revision", revision; "title", title; "metric", metric; "target_value", target]) in
  if Goal_store.criterion_equal criterion verdict.criterion then Ok { goal_id; phase; verdict }
  else Error "goal confirmation: criterion mismatch"

let confirmation_body { goal_id; verdict; _ } =
  let Goal_store.Criterion criterion = verdict.Goal_verification.criterion in
  `Assoc
    [ "goal_id", `String goal_id
    ; "criterion_revision", `String criterion.revision
    ; "request_id", `String verdict.request_id
    ; "verification_run_id", `String verdict.verification_run_id
    ]

let same_confirmation_binding left right =
  String.equal left.goal_id right.goal_id
  && Goal_store.criterion_equal left.verdict.criterion right.verdict.criterion
  && String.equal left.verdict.request_id right.verdict.request_id
  && String.equal left.verdict.verification_run_id right.verdict.verification_run_id

let confirmation_lines ~width { goal_id; verdict; _ } =
  let Goal_store.Criterion criterion = verdict.Goal_verification.criterion in
  [ "CONFIRM THIS PROOF — [a] confirms; Esc cancels"
  ; "Goal: " ^ goal_id
  ; "Title: " ^ criterion.title
  ; "Target: " ^ Option.value criterion.metric ~default:"not declared"
    ^ " = " ^ Option.value criterion.target_value ~default:"not declared"
  ; "Criterion: " ^ criterion.revision
  ; "Request: " ^ verdict.request_id
  ; "Verifier run: " ^ verdict.verification_run_id
  ; "Evidence: " ^ verdict.evidence
  ]
  |> List.concat_map (fun text ->
       Message_layout.wrap_body ~max_cells:width
         ~sanitize:Tui_decode.sanitize_terminal_text text
       |> List.map (fun text -> { tone = Waiting; text }))

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
  | Tui_decode.Proof_stale evidence ->
      verdict ~width Note "criterion changed; previous proof is historical" evidence
      @ note ~width last_review_note
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
  let header =
    { tone = Note; text = "RELATED ACTIVITY · latest state per linked item" }
  in
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
