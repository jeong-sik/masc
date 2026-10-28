module Message_layout = Masc_tui_message_layout
module Tui_decode = Masc.Tui_decode
module Terminal_text = Masc_tui_ansi.Terminal_text

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
  (* The plain foreground: the rows the operator actually reads to decide --
     the goal's promise and the evidence. Louder than the dim provenance,
     quieter than the warn instruction, so a confirmation block keeps three
     readable volumes instead of one flat shout. *)
  | Plain

type line =
  { tone : tone
  ; text : string
  }

(* Every row this module wraps is wire text: a judge's reason, a keeper's
   note, a timeline event, a store error. It is split on LF first and each
   line escaped on its own, so a control byte reaches the pane as its escape
   while a line break stays a new row instead of a printed "\x0A". A CRLF
   line ending loses its CR here too, or every row would end in "\x0D". *)
let without_line_end_cr line =
  let length = String.length line in
  if length > 0 && Char.equal line.[length - 1] '\r'
  then String.sub line 0 (length - 1)
  else line

let wrapped ~width tone text =
  String.split_on_char '\n' text
  |> List.concat_map (fun line ->
       Message_layout.wrap_words ~max_cells:width
         (Masc.Tui_terminal_text.sanitize_terminal_text (without_line_end_cr line)))
  |> List.map (fun row -> { tone; text = row })

(* The confirmation read answers with the metadata projection of each
   submitted original, not the originals: identity, size and integrity reach
   the operator while contents stay on the server. Each kind is parsed into
   its own shape, and a kind this build does not know keeps its name on
   screen instead of disappearing -- a newer server can add one without
   stranding an older reader mid-confirmation. *)
type submitted_original =
  | Original_collaboration of { reference : string; sha256 : string; bytes : int }
  | Original_note of { bytes : int }
  | Original_artifact of { reference : string; bytes : int; truncated : bool }
  | Original_binary of { reference : string; bytes : int; sha256 : string; format : string }
  | Original_unreadable of { reference : string option; reason : string }
  | Original_unknown of string

type confirmation = {
  goal_id : string;
  phase : Goal_phase.t;
  verdict : Goal_verification.verdict;
  submitted : submitted_original list;
}

(* Every field of a metadata item that is present is also well-formed: a
   present-but-broken item fails the read, because the projection is written
   by the same server that wrote the proof. *)
let decode_submitted_original (item : Yojson.Safe.t) : (submitted_original, string) result =
  let ( let* ) = Result.bind in
  let field name = function
    | `Assoc fields ->
        (match List.assoc_opt name fields with
         | Some value -> Ok value
         | None -> Error ("submitted evidence: missing " ^ name))
    | _ -> Error "submitted evidence: expected an object"
  in
  let string name = function
    | `String value -> Ok value
    | _ -> Error ("submitted evidence: " ^ name ^ " is not a string")
  in
  let int name = function
    | `Int value -> Ok value
    | _ -> Error ("submitted evidence: " ^ name ^ " is not an integer")
  in
  let bool name = function
    | `Bool value -> Ok value
    | _ -> Error ("submitted evidence: " ^ name ^ " is not a boolean")
  in
  let* kind = let* value = field "kind" item in string "kind" value in
  match kind with
  | "collaboration" ->
      let* reference = (let* value = field "reference" item in string "reference" value) in
      let* sha256 = (let* value = field "sha256" item in string "sha256" value) in
      let* bytes = (let* value = field "bytes" item in int "bytes" value) in
      Ok (Original_collaboration { reference; sha256; bytes })
  | "note" ->
      let* bytes = (let* value = field "bytes" item in int "bytes" value) in
      Ok (Original_note { bytes })
  | "artifact" ->
      let* reference = (let* value = field "reference" item in string "reference" value) in
      let* bytes = (let* value = field "bytes" item in int "bytes" value) in
      let* truncated = (let* value = field "truncated" item in bool "truncated" value) in
      Ok (Original_artifact { reference; bytes; truncated })
  | "artifact_binary" ->
      let* reference = (let* value = field "reference" item in string "reference" value) in
      let* bytes = (let* value = field "bytes" item in int "bytes" value) in
      let* sha256 = (let* value = field "sha256" item in string "sha256" value) in
      let* format = (let* value = field "format" item in string "format" value) in
      Ok (Original_binary { reference; bytes; sha256; format })
  | "artifact_unreadable" ->
      let* reason = let* value = field "reason" item in string "reason" value in
      let reference =
        match item with
        | `Assoc fields ->
            (match List.assoc_opt "reference" fields with
             | Some (`String reference) -> Some reference
             | _ -> None)
        | _ -> None
      in
      Ok (Original_unreadable { reference; reason })
  | other -> Ok (Original_unknown other)

type confirmation_state =
  | Inspecting of (string, confirmation) Masc_tui_fetched.t
  (* Keep the read generation while the write is in flight. Navigation can
     cancel inspection, but cannot cancel a confirmation already sent. *)
  | Submitting of string * (string, confirmation) Masc_tui_fetched.t

let decode_confirmation ~goal_id json =
  let open Result.Syntax in
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
  let* phase = Goal_phase.of_fields goal in
  let* completion = field "completion" verification in
  let* completion = Goal_verification.completion_state_of_yojson completion in
  let* verdict =
    match phase, completion with
    | Goal_phase.Awaiting_confirmation, Goal_verification.Proof_proven verdict
    (* The server records a confirmation before it runs the caller's step and
       saves the phase. When that step refuses, or the phase cannot be saved,
       the goal stays here with the confirmation recorded, and confirming again
       is how the operator finishes it. *)
    | Goal_phase.Awaiting_confirmation, Goal_verification.Human_confirmed (verdict, _)
    | Goal_phase.Completed, Goal_verification.Human_confirmed (verdict, _) -> Ok verdict
    | (Goal_phase.Awaiting_confirmation, (Goal_verification.Completion_idle | (Goal_verification.Proof_pending _ | Goal_verification.Proof_refuted _)))
    | (Goal_phase.Completed, (Goal_verification.Completion_idle | (Goal_verification.Proof_pending _ | (Goal_verification.Proof_proven _ | Goal_verification.Proof_refuted _))))
    | ((Goal_phase.Executing | (Goal_phase.Verifying | (Goal_phase.Dropped | (Goal_phase.Paused _ | Goal_phase.Blocked _)))), _) -> Error "goal confirmation: no current proven completion to confirm"
  in
  let* revision = field "criterion_revision" goal in
  let* title = field "title" goal in
  let* metric = field "metric" goal in
  let* target = field "target_value" goal in
  let* criterion = Goal_store.criterion_of_yojson
      (`Assoc ["revision", revision; "title", title; "metric", metric; "target_value", target]) in
  if Goal_store.criterion_equal criterion verdict.criterion then
    let submitted =
      (* An answer from before the list existed carries no key; the originals
         then simply do not draw. *)
      match verification with
      | `Assoc fields ->
          (match List.assoc_opt "submitted_evidence" fields with
           | None -> Ok []
           | Some (`List items) ->
               let rec all acc = function
                 | [] -> Ok (List.rev acc)
                 | item :: rest ->
                     (match decode_submitted_original item with
                      | Ok original -> all (original :: acc) rest
                      | Error detail -> Error detail)
               in
               all [] items
           | Some _ -> Error "submitted evidence: expected a list")
      | _ -> Error "goal confirmation: expected object"
    in
    let ( let* ) = Result.bind in
    let* submitted = submitted in
    Ok { goal_id; phase; verdict; submitted }
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

(* The confirmation block is one decision the operator reads in layers: what
   to do, what the goal promised, which proof binding is on the table, and
   the evidence itself. It used to be one flat warn-coloured list, so the
   instruction, the ids and the evidence all spoke at the same volume and the
   pane gave the eye nowhere to land. Each layer now keeps its own tone --
   warn for the instruction, plain for what is read, dim for the binding fine
   print -- and the evidence stays the last group, so a presented frame still
   proves the operator scrolled through the whole proof. *)
(* The originals are provenance the operator may open, so they read at the
   same plain volume as the evidence, as one labelled list under it. The list
   ends the block when present, which keeps the presented-frame receipt
   meaning "the end of the block". Shown sha length is a presentation choice
   (board question pending); the full value stays one action away. *)
let sha256_cells = 12

let humanized_bytes bytes =
  let kb = 1024 and mb = 1024 * 1024 in
  if bytes >= mb then Printf.sprintf "%.1f MB" (float_of_int bytes /. float_of_int mb)
  else if bytes >= kb then Printf.sprintf "%.1f KB" (float_of_int bytes /. float_of_int kb)
  else Printf.sprintf "%d B" bytes

let sha256_prefix sha256 =
  String.sub sha256 0 (min (String.length sha256) sha256_cells)

let submitted_original_text (original : submitted_original) =
  match original with
  | Original_collaboration { reference; sha256; bytes } ->
      Printf.sprintf "collaboration %s · %s · sha256 %s"
        reference (humanized_bytes bytes) (sha256_prefix sha256)
  | Original_note { bytes } ->
      Printf.sprintf "note · %s" (humanized_bytes bytes)
  | Original_artifact { reference; bytes; truncated } ->
      Printf.sprintf "artifact %s · %s%s" reference (humanized_bytes bytes)
        (if truncated then " · truncated" else "")
  | Original_binary { reference; bytes; sha256; format } ->
      Printf.sprintf "binary %s · %s · %s · sha256 %s"
        reference format (humanized_bytes bytes) (sha256_prefix sha256)
  | Original_unreadable { reference; reason } ->
      (match reference with
       | Some reference -> "unreadable " ^ reference
       | None -> "unreadable")
      ^ " · " ^ reason
  | Original_unknown kind -> "unknown kind " ^ kind

let confirmation_lines ~width ~ko { goal_id; verdict; submitted; _ } =
  let Goal_store.Criterion criterion = verdict.Goal_verification.criterion in
  let line_of tone text = { tone; text } in
  let sanitize text =
    Masc.Tui_terminal_text.sanitize_terminal_text (without_line_end_cr text)
  in
  (* Rows under a label align every continuation to the value column; the
     column is one wider than the longest label ("Evidence:"), as the
     timeline's field is. *)
  let labelled ~tone label text =
    let cells = 10 in
    let prefix = Printf.sprintf "%-10s" (label ^ ":") in
    String.split_on_char '\n' text
    |> List.concat_map (fun text ->
         Message_layout.wrap_words ~max_cells:(max 1 (width - cells))
           (sanitize text))
    |> List.mapi (fun index text ->
         line_of tone ((if index = 0 then prefix else String.make cells ' ') ^ text))
  in
  let paragraph ~indent tone text =
    String.split_on_char '\n' text
    |> List.concat_map (fun text ->
         Message_layout.wrap_words ~max_cells:(max 1 (width - indent))
           (sanitize text))
    |> List.map (fun text -> line_of tone (String.make indent ' ' ^ text))
  in
  let header =
    line_of Note (if ko then "[ 판정 확인 ]" else "[ Confirm the proof ]")
  in
  let instruction =
    paragraph ~indent:0 Waiting
      (if ko
       then "이 증명을 확인합니다 — 증거를 끝까지 읽은 뒤 [a], 그만두려면 Esc"
       else "CONFIRM THIS PROOF — read through evidence, then [a]; Esc cancels")
  in
  let promise =
    labelled ~tone:Plain "Title" criterion.title
    @ labelled ~tone:Plain "Target"
        (Option.value criterion.metric ~default:"not declared"
         ^ " = " ^ Option.value criterion.target_value ~default:"not declared")
  in
  let binding =
    labelled ~tone:Quiet "Binding"
      (Printf.sprintf "goal %s · criterion %s · request %s · verifier run %s"
         goal_id criterion.revision verdict.request_id
         verdict.verification_run_id)
  in
  let evidence =
    line_of Plain "Evidence:" :: paragraph ~indent:2 Plain verdict.evidence
  in
  let submitted =
    match submitted with
    | [] -> []
    | originals ->
        let cells = 10 in
        List.concat_map
          (fun original ->
             Message_layout.wrap_words ~max_cells:(max 1 (width - cells))
               (submitted_original_text original))
          originals
        |> List.mapi (fun index text ->
               line_of Plain
                 ((if index = 0 then Printf.sprintf "%-10s" "Submitted:" else String.make cells ' ')
                  ^ text))
  in
  let blank = [ line_of Quiet "" ] in
  header
  :: (instruction @ blank @ promise @ blank @ binding @ blank @ evidence
      @ (match submitted with [] -> [] | _ -> blank @ submitted))

(* A verdict is a headline and, when the judge left one, the measurement it
   rests on. They are separate rows because the reason wraps and the headline
   should stay findable at the top of the block. *)
let verdict ~width tone headline reason =
  { tone; text = headline }
  :: (match reason with
      | None -> []
      | Some reason -> wrapped ~width tone reason)

(* The latest verifier scan could not settle this goal, so the judge's last
   word is not what holds it: no judge model runs in these steps, only
   original, goal store and ledger access. The heading says which step failed;
   the store's reason wraps under it like a verdict's. *)
let unreconciled_heading = function
  | Goal_reconcile_step.Reconcile_proof -> "verifier could not apply the committed proof"
  | Goal_reconcile_step.Rearm_proof -> "verifier could not re-arm the request"
  | Goal_reconcile_step.Read_original -> "verifier could not read the retained request"

(* [c] on a Verifying goal sends [request_complete] again, the explicit retry
   of RFC-0387 §5: under the goal lock it applies a committed proof or
   re-arms a missing request -- the two steps a scan can fail -- and answers
   with the reason when it still cannot. [o] reopens the goal, which archives
   a committed proof, so it is offered as taking the goal back, never as the
   way to unstick it. *)
let verifying_next_step = function
  | Some (_ : Tui_decode.verifier_unreconciled) ->
    ( Refused
    , "the verifier could not settle it - [c] retries and shows why; [o] takes it back, [x] drops it" )
  | None ->
    ( Waiting
    , "with the completion judge - [c] re-arms the request; [o] takes it back, [x] drops it" )

let unreconciled_lines ~width (blocked : Tui_decode.verifier_unreconciled) =
  verdict ~width:(max 1 width) Refused (unreconciled_heading blocked.vu_step)
    (Some blocked.vu_detail)

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

(* Shared with Task history; Goal activity uses the full source timestamp. *)
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

(* Title first, state after: the title names the row and the summary qualifies
   it. A task's summary is its status ("todo"), an approval's is its input
   preview, a keeper's is its event summary -- none of them identify the row on
   their own, which is why the pane read as a list of statuses with nothing
   attached. A summary that only repeats the title adds nothing and is
   dropped, and so is one that repeats the subject column beside it: a goal's
   own creation event carries its kind in both, and the row read
   "goal_created  Goal Event \xc2\xb7 goal_created". *)
let headline ~subject (event : Tui_decode.goal_timeline_event) =
  let title = String.trim event.gt_title in
  let summary = String.trim event.gt_summary in
  let summary = if String.equal summary subject then "" else summary in
  if String.equal summary "" || String.equal summary title then title
  else if String.equal title "" then summary
  else title ^ "  \xc2\xb7 " ^ summary

(* The goal's merged event timeline, appended after [body] so it rides the
   same scroll. Loaded lazily on detail entry; every non-ready state says
   what it is instead of rendering as an empty history. *)
let timeline_unavailability_detail = function
  | Tui_decode.Goal_source_failure (Goal_store_unavailable view) ->
      "Cause: " ^ Tui_decode.goal_store_unavailable_view_to_string view
  | Tui_decode.Goal_source_failure (Goal_task_links_unavailable detail) ->
      "Linked tasks unavailable · Cause: " ^ detail
  | Tui_decode.Approval_queue_failure detail ->
      "Approval queue unavailable · Cause: " ^ detail

let timeline ~width ~goal_id
    (loaded : (string, Tui_decode.goal_timeline_event list) Masc_tui_fetched.t) =
  let header =
    { tone = Note; text = "RELATED ACTIVITY · latest state per linked item" }
  in
  let observed = function
        | [] ->
            [ { tone = Quiet; text = "  (no events recorded)" } ]
        | events ->
            List.concat_map
              (fun (event : Tui_decode.goal_timeline_event) ->
                let tone = severity_tone event.gt_severity in
                let subject = subject event in
                wrapped ~width tone
                  (Printf.sprintf "  %s  %s  %s" event.gt_ts subject
                     (headline ~subject event)))
              events
  in
  let view = Masc_tui_fetched.view_for ~equal:String.equal loaded ~key:goal_id in
  let rows =
    match view with
    | Masc_tui_fetched.Ready value -> observed value
    | Masc_tui_fetched.Stale (value, detail) ->
        wrapped ~width Unreadable
          ("  refresh failed; previous observation: " ^ Terminal_text.single_line detail)
        @ observed value
    | Masc_tui_fetched.Failed detail -> wrapped ~width Unreadable
        ("  timeline load failed: " ^ Terminal_text.single_line detail)
    | Masc_tui_fetched.Absent -> [ { tone = Quiet; text = "  timeline not requested" } ]
    | Masc_tui_fetched.Loading -> [ { tone = Quiet; text = "  loading..." } ]
  in
  let pending =
    if not (Masc_tui_fetched.in_flight loaded) then []
    else match view with
      | Masc_tui_fetched.Ready _ | Masc_tui_fetched.Stale _ ->
          [ { tone = Quiet; text = "  refreshing; previous observation" } ]
      | Masc_tui_fetched.Failed _ -> [ { tone = Quiet; text = "  retrying; previous failure remains" } ]
      | Masc_tui_fetched.Absent | Masc_tui_fetched.Loading -> [] in
  ({ tone = Quiet; text = "" } :: header :: (pending @ rows))
