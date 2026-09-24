(** A goal's detail says what the judge decided.

    The list draws the verdict and its reason under the cursor; the detail
    drew neither, so opening a goal showed less than the row it was opened
    from. Its footer still advertised [j/k:scroll] and the key handler still
    kept a scroll for it -- over a screen with nothing on it to move.

    These tests pin the block that fills it: every verdict produces rows, a
    reason wraps rather than being cut, and an idle ledger says so instead of
    drawing the same blank a decode failure would. *)

module Detail = Masc_tui_planning_detail
module Proof = Masc.Tui_decode

let texts rows = List.map (fun (r : Detail.line) -> r.Detail.text) rows
let tones rows = List.map (fun (r : Detail.line) -> r.Detail.tone) rows

let check_bool = Alcotest.(check bool)
let check_int = Alcotest.(check int)
let check_string = Alcotest.(check string)

let test_every_verdict_draws_something () =
  let cases =
    [ ("proven", Proof.Proof_proven None)
    ; ("proven with evidence", Proof.Proof_proven (Some "42 runs, 0 red"))
    ; ("refused", Proof.Proof_refuted None)
    ; ("refused with reason", Proof.Proof_refuted (Some "no evidence file"))
    ; ("pending", Proof.Proof_pending)
    ; ("unreadable", Proof.Proof_unreadable None)
    ; ("unreadable with detail", Proof.Proof_unreadable (Some "bad json"))
    ; ("stale", Proof.Proof_stale (Some "previous target reached"))
    ; ("idle", Proof.Proof_idle)
    ]
  in
  List.iter
    (fun (name, proof) ->
      let rows = Detail.body ~width:60 proof None in
      check_bool (name ^ " draws at least one row") true (rows <> []))
    cases

let test_idle_is_not_silence () =
  let rows = Detail.body ~width:60 Proof.Proof_idle None in
  check_int "an idle ledger draws one row" 1 (List.length rows);
  check_string "and says the ledger is empty rather than nothing"
    "no verdict on the ledger" (List.hd (texts rows))

let test_a_long_reason_wraps_instead_of_being_cut () =
  let reason = String.concat " " (List.init 40 (fun i -> Printf.sprintf "word%d" i)) in
  let rows = Detail.body ~width:30 (Proof.Proof_refuted (Some reason)) None in
  check_bool "the reason takes more than one row" true (List.length rows > 2);
  List.iter
    (fun text ->
      check_bool ("row fits the width: " ^ text) true (String.length text <= 30 * 4))
    (texts rows);
  let rejoined = String.concat " " (List.tl (texts rows)) in
  check_bool "the last word survives the wrap" true
    (let needle = "word39" in
     let rec found i =
       i + String.length needle <= String.length rejoined
       && (String.sub rejoined i (String.length needle) = needle || found (i + 1))
     in
     found 0)

let test_the_note_reads_after_the_verdict () =
  let rows =
    Detail.body ~width:60 (Proof.Proof_proven (Some "measured")) (Some "watch the flake")
  in
  let texts = texts rows in
  check_string "the verdict heads the block" "proven" (List.hd texts);
  check_bool "the note is labelled" true (List.mem "note" texts);
  check_bool "and its text follows" true (List.mem "watch the flake" texts)

let test_tone_separates_a_refusal_from_a_proof () =
  let proven = tones (Detail.body ~width:60 (Proof.Proof_proven None) None) in
  let refused = tones (Detail.body ~width:60 (Proof.Proof_refuted None) None) in
  check_bool "a proof reads as proven" true (List.hd proven = Detail.Proven);
  check_bool "a refusal reads as refused" true (List.hd refused = Detail.Refused);
  let stale = Detail.body ~width:60 (Proof.Proof_stale (Some "old target reached")) None in
  check_bool "historical proof has no current approval tone" true
    (List.for_all (fun tone -> tone <> Detail.Proven) (tones stale));
  check_bool "historical evidence remains readable" true
    (List.mem "old target reached" (texts stale))

(* A Verifying goal the verifier skips on every scan heads the detail with
   which step failed and the store's reason, in the refusal tone, and the
   reason reaches the terminal escaped. *)
let test_a_stuck_goal_says_which_step_and_why () =
  let rows =
    Detail.unreconciled_lines ~width:60
      { Proof.vu_step = Masc.Goal_verification_agent.Rearm_proof
      ; vu_detail = "criterion already proven\x1b[2J"
      }
  in
  check_string "the headline names the step" "judge stuck re-arming its request"
    (List.hd (texts rows));
  check_bool "the block reads as refused" true
    (List.for_all (fun tone -> tone = Detail.Refused) (tones rows));
  check_bool "the reason follows" true
    (List.exists
       (fun text -> String.length text >= 24 && String.sub text 0 24 = "criterion already proven")
       (texts rows));
  check_bool "no raw escape byte reaches the pane" true
    (List.for_all (fun text -> not (String.contains text '\x1b')) (texts rows));
  check_string "the other step has its own headline"
    "judge stuck replaying its committed proof"
    (Detail.unreconciled_heading Masc.Goal_verification_agent.Reconcile_proof)

(* The judge's reason and the keeper's note are wire text. An ESC in either
   used to reach the terminal as an ESC and could clear or repaint the pane
   (same class as the approval detail, #38478). *)
let test_verdict_and_note_reach_the_pane_escaped () =
  let rows =
    Detail.body ~width:60
      (Proof.Proof_refuted (Some "refused\x1b[2J by the judge"))
      (Some "note\x1b]52;c;cGFzdGU=\x07 here")
  in
  check_bool "no raw ESC or BEL byte reaches the pane" true
    (List.for_all
       (fun text -> not (String.contains text '\x1b' || String.contains text '\x07'))
       (texts rows));
  check_bool "the escaped reason is still readable" true
    (List.exists
       (fun text ->
          let needle = "refused\\x1B[2J" in
          let n = String.length needle in
          String.length text >= n && String.sub text 0 n = needle)
       (texts rows))

(* Escaping the note whole turned its line break into a printed "\x0A" and
   the two lines into one run. Each line is escaped on its own instead. *)
let test_a_note_with_a_newline_draws_two_lines () =
  let rows =
    Detail.body ~width:60 Proof.Proof_idle (Some "first line\nsecond\x1b[2J line")
  in
  let texts = texts rows in
  check_bool "the first line is its own row" true (List.mem "first line" texts);
  check_bool "the second line is its own row, escaped" true
    (List.mem "second\\x1B[2J line" texts);
  check_bool "no line break is printed as an escape" true
    (List.for_all
       (fun text ->
          let needle = "\\x0A" in
          let n = String.length needle in
          let rec found i =
            i + n <= String.length text && (String.sub text i n = needle || found (i + 1))
          in
          not (found 0))
       texts);
  check_bool "no raw control byte reaches the pane" true
    (List.for_all
       (fun text -> String.for_all (fun c -> Char.code c >= 0x20 && c <> '\x7f') text)
       texts)

let test_a_narrow_pane_still_produces_rows () =
  let rows = Detail.body ~width:0 (Proof.Proof_refuted (Some "why")) None in
  check_bool "width 0 does not loop or vanish" true (rows <> [])

let test_a_timestamp_value_never_starts_at_the_colon () =
  (* "reviewed:" is the longest label the pane prints; at one past its width
     the value used to start immediately after the colon. *)
  List.iter
    (fun label ->
      let line = Detail.timestamp_line ~label "2026-08-27 20:36" in
      check_bool (label ^ ": keeps a gap before its value") true
        (let colon = String.index line ':' in
         colon + 1 < String.length line && line.[colon + 1] = ' '))
    [ "created"; "updated"; "reviewed" ];
  check_string "the longest label still leaves one gap"
    "  reviewed: 2026-08-27 20:36"
    (Detail.timestamp_line ~label:"reviewed" "2026-08-27 20:36")

let confirmation_fixture ?(goal_id = "goal-1") ?(revision = "revision-1")
    ?(metric = "passing scenarios") ?(run_id = "run-1") ?(confirmed = false) () =
  let criterion = Goal_store.Criterion
      { revision = "revision-1"; title = "Harness";
        metric = Some "passing scenarios"; target_value = Some "10" } in
  let verdict : Goal_verification.verdict =
    { outcome = Proven; request_id = "request-1"; criterion;
      verification_run_id = run_id;
      authority = Masc_domain.System_llm_agent { agent_run_id = run_id };
      evidence = "10 scenarios passed\nObserved result retained";
      recorded_at = "2026-09-19T08:00:00Z" } in
  let completion =
    if confirmed then Goal_verification.Human_confirmed
      (verdict, { operator_id = "operator"; confirmed_at = "2026-09-19T08:01:00Z" })
    else Goal_verification.Proof_proven verdict in
  let record = { (Goal_verification.default_record ~goal_id) with completion } in
  `Assoc
    [ "goal", `Assoc
        [ "id", `String goal_id
        ; "phase", Goal_phase.to_yojson (if confirmed then Completed else Awaiting_confirmation)
        ; "title", `String "Harness"
        ; "criterion_revision", `String revision
        ; "metric", `String metric
        ; "target_value", `String "10"
        ]
    ; "verification", Goal_verification.record_to_yojson record
    ]

let confirmation_exn json =
  match Detail.decode_confirmation ~goal_id:"goal-1" json with
  | Ok confirmation -> confirmation
  | Error detail -> Alcotest.fail detail

let test_confirmation_retains_the_displayed_proof () =
  let read = confirmation_exn (confirmation_fixture ()) in
  let sent = Detail.confirmation_body read in
  check_bool "POST binds the inspected proof" true
    (sent = `Assoc
       [ "goal_id", `String "goal-1"; "criterion_revision", `String "revision-1";
         "request_id", `String "request-1"; "verification_run_id", `String "run-1" ]);
  let newer = confirmation_exn (confirmation_fixture ~run_id:"run-2" ()) in
  check_bool "a newer verifier run cannot replace the inspected one" false
    (Detail.same_confirmation_binding read newer);
  let confirmed = confirmation_exn (confirmation_fixture ~confirmed:true ()) in
  check_bool "the server confirmed the same binding" true
    (Detail.same_confirmation_binding read confirmed);
  let rendered = texts (Detail.confirmation_lines ~width:80 read) in
  check_bool "operator sees exact run" true (List.mem "Verifier run: run-1" rendered);
  check_bool "evidence keeps its second line" true (List.mem "Observed result retained" rendered)

let test_confirmation_refuses_unrelated_or_changed_proof () =
  List.iter
    (fun json -> check_bool "unrelated or changed proof refused" true
      (Result.is_error (Detail.decode_confirmation ~goal_id:"goal-1" json)))
    [ confirmation_fixture ~goal_id:"goal-2" ()
    ; confirmation_fixture ~revision:"revision-2" ()
    ; confirmation_fixture ~metric:"other criterion" ()
    ; `Assoc ["goal", `Null]
    ];
  let stale = confirmation_fixture () |> function
    | `Assoc fields -> `Assoc (List.map (fun (key, value) ->
        if String.equal key "verification" then
          key, `Assoc ["goal_id", `String "goal-1";
            "completion", `Assoc ["state", `String "stale_criterion"]]
        else key, value) fields)
    | _ -> Alcotest.fail "fixture must be an object" in
  check_bool "historical proof never arms confirmation" true
    (Result.is_error (Detail.decode_confirmation ~goal_id:"goal-1" stale))

let test_confirmation_read_cannot_rearm_after_cancel () =
  let module Read = Masc_tui_fetched in
  match Read.start ~equal:String.equal Read.initial ~key:"goal-1" with
  | Already_loading -> Alcotest.fail "initial read did not start"
  | Started (loading, request) ->
      let cancelled = Read.clear loading in
      let late = Read.complete ~equal:String.equal cancelled request
          (Ok (confirmation_exn (confirmation_fixture ()))) in
      check_bool "late evidence cannot rearm a cancelled confirmation" true
        (Read.view_for ~equal:String.equal late ~key:"goal-1" = Absent)

let timeline_event ~kind ~lane ~title ~summary : Proof.goal_timeline_event =
  { gt_ts = "2026-09-22T14:18:09Z"
  ; gt_kind = kind
  ; gt_lane = lane
  ; gt_title = title
  ; gt_summary = summary
  ; gt_severity = "ok"
  }

let timeline_rows events =
  texts
    (Detail.timeline ~width:100 ~goal_id:"goal-1"
       (Some ("goal-1", Ok (Proof.Goal_timeline_ready events))))

let contains needle text =
  let n = String.length needle and h = String.length text in
  let rec go i = i + n <= h && (String.sub text i n = needle || go (i + 1)) in
  go 0

(* A goal's own creation event carries its kind in the subject column and in
   the summary, so the row said it twice: "goal_created  Goal Event \xc2\xb7
   goal_created". Every goal has one. *)
let test_a_summary_that_repeats_the_subject_is_dropped () =
  let rows =
    timeline_rows
      [ timeline_event ~kind:"goal_created" ~lane:"goal" ~title:"Goal Event"
          ~summary:"goal_created"
      ]
  in
  let row =
    match List.filter (fun text -> contains "goal_created" text) rows with
    | [ row ] -> row
    | rows ->
      Alcotest.failf "expected one row naming the event, got %d"
        (List.length rows)
  in
  let occurrences needle text =
    let n = String.length needle and h = String.length text in
    let rec go i found =
      if i + n > h then found
      else if String.sub text i n = needle then go (i + n) (found + 1)
      else go (i + 1) found
    in
    go 0 0
  in
  check_int "the kind is drawn once, by the subject column" 1
    (occurrences "goal_created" row);
  check_bool "and the title still names the row" true
    (contains "Goal Event" row)

(* A summary that qualifies the row stays: a task's status is not its id. *)
let test_a_summary_that_says_more_than_the_subject_stays () =
  let rows =
    timeline_rows
      [ timeline_event ~kind:"task_state" ~lane:"task:task-1522"
          ~title:"restart replay" ~summary:"todo \xc2\xb7 created by analyst"
      ]
  in
  let row =
    match List.filter (fun text -> contains "task-1522" text) rows with
    | [ row ] -> row
    | rows -> Alcotest.failf "expected one task row, got %d" (List.length rows)
  in
  check_bool "the title names the row" true (contains "restart replay" row);
  check_bool "and the status still qualifies it" true (contains "todo" row)

let () =
  Alcotest.run "tui_planning_detail"
    [ ( "body"
      , [ Alcotest.test_case "a summary that repeats the subject is dropped"
            `Quick test_a_summary_that_repeats_the_subject_is_dropped
        ; Alcotest.test_case "a summary that says more than the subject stays"
            `Quick test_a_summary_that_says_more_than_the_subject_stays
        ; Alcotest.test_case "every verdict draws something" `Quick
            test_every_verdict_draws_something
        ; Alcotest.test_case "idle is not silence" `Quick test_idle_is_not_silence
        ; Alcotest.test_case "a long reason wraps instead of being cut" `Quick
            test_a_long_reason_wraps_instead_of_being_cut
        ; Alcotest.test_case "the note reads after the verdict" `Quick
            test_the_note_reads_after_the_verdict
        ; Alcotest.test_case "tone separates a refusal from a proof" `Quick
            test_tone_separates_a_refusal_from_a_proof
        ; Alcotest.test_case "a stuck goal says which step and why" `Quick
            test_a_stuck_goal_says_which_step_and_why
        ; Alcotest.test_case "verdict and note reach the pane escaped" `Quick
            test_verdict_and_note_reach_the_pane_escaped
        ; Alcotest.test_case "a note with a newline draws two lines" `Quick
            test_a_note_with_a_newline_draws_two_lines
        ; Alcotest.test_case "a narrow pane still produces rows" `Quick
            test_a_narrow_pane_still_produces_rows
        ; Alcotest.test_case "a timestamp value never starts at the colon" `Quick
            test_a_timestamp_value_never_starts_at_the_colon
        ; Alcotest.test_case "confirmation retains the displayed proof" `Quick
            test_confirmation_retains_the_displayed_proof
        ; Alcotest.test_case "confirmation refuses unrelated or changed proof" `Quick
            test_confirmation_refuses_unrelated_or_changed_proof
        ; Alcotest.test_case "cancelled confirmation ignores late read" `Quick
            test_confirmation_read_cannot_rearm_after_cancel
        ] )
    ]
