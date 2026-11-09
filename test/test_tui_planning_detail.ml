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

let contains needle text =
  let n = String.length needle in
  let rec from i =
    if i + n > String.length text then false
    else if String.sub text i n = needle then true
    else from (i + 1)
  in
  from 0

let check_bool = Alcotest.(check bool)
let check_string = Alcotest.(check string)

let test_tone_separates_a_refusal_from_a_proof () =
  let proven = tones (Detail.body ~ko:false ~width:60 (Proof.Proof_proven None) None) in
  let refused = tones (Detail.body ~ko:false ~width:60 (Proof.Proof_refuted None) None) in
  check_bool "a proof reads as proven" true (List.hd proven = Detail.Proven);
  check_bool "a refusal reads as refused" true (List.hd refused = Detail.Refused);
  let stale = Detail.body ~ko:false ~width:60 (Proof.Proof_stale (Some "old target reached")) None in
  check_bool "historical proof has no current approval tone" true
    (List.for_all (fun tone -> tone <> Detail.Proven) (tones stale));
  check_bool "historical evidence remains readable" true
    (List.mem "old target reached" (texts stale))

(* A Verifying goal the latest verifier scan could not settle heads the detail with
   which step failed and the store's reason, in the refusal tone, and the
   reason reaches the terminal escaped. *)
let test_a_stuck_goal_says_which_step_and_why () =
  let rows =
    Detail.unreconciled_lines ~ko:false ~width:60
      { Proof.vu_step = Goal_reconcile_step.Rearm_proof
      ; vu_detail = "criterion already proven\x1b[2J"
      }
  in
  check_bool "the block reads as refused" true
    (List.for_all (fun tone -> tone = Detail.Refused) (tones rows));
  check_bool "the reason follows" true
    (List.exists
       (fun text -> String.length text >= 24 && String.sub text 0 24 = "criterion already proven")
       (texts rows));
  check_bool "no raw escape byte reaches the pane" true
    (List.for_all (fun text -> not (String.contains text '\x1b')) (texts rows));
  check_string "the other step has its own headline"
    "verifier could not apply the committed proof"
    (Detail.unreconciled_heading ~ko:false Goal_reconcile_step.Reconcile_proof)

(* [c] on a stuck Verifying goal applies a committed proof or retries a
   matching pending request. The stuck hint used to
   drop it and lead with [o], which archives a committed proof. *)
let test_a_stuck_goal_offers_the_retry_first () =
  let index_of needle text =
    let n = String.length needle in
    let rec from i =
      if i + n > String.length text then None
      else if String.sub text i n = needle then Some i
      else from (i + 1)
    in
    from 0
  in
  let stuck_tone, stuck =
    Detail.verifying_next_step ~ko:false ~can_retry:true
      (Some
         { Proof.vu_step = Goal_reconcile_step.Reconcile_proof
         ; vu_detail = "goal store unavailable"
         })
  in
  check_bool "a stuck goal reads as refused" true (stuck_tone = Detail.Refused);
  (match index_of "[c]" stuck, index_of "[o]" stuck with
   | Some retry, Some reopen ->
     check_bool "the retry comes before taking it back" true (retry < reopen)
   | None, _ -> Alcotest.fail ("a stuck goal's next step drops [c]: " ^ stuck)
   | Some _, None -> Alcotest.fail ("a stuck goal's next step drops [o]: " ^ stuck));
  let waiting_tone, waiting = Detail.verifying_next_step ~ko:false ~can_retry:true None in
  check_bool "unresolved verification reads as waiting" true (waiting_tone = Detail.Waiting);
  check_bool "and offers [c] too" true (Option.is_some (index_of "[c]" waiting))

(* The judge's reason and the keeper's note are wire text. An ESC in either
   used to reach the terminal as an ESC and could clear or repaint the pane
   (same class as the approval detail, #38478). *)
let test_verdict_and_note_reach_the_pane_escaped () =
  let rows =
    Detail.body ~ko:false ~width:60
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
    Detail.body ~ko:false ~width:60 Proof.Proof_idle (Some "first line\nsecond\x1b[2J line")
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

(* Splitting on LF alone left the CR of a CRLF line ending on every row, and
   escaping turned it into a printed "\x0D". *)
let test_a_crlf_note_draws_its_lines_without_the_cr () =
  let rows =
    Detail.body ~ko:false ~width:60 Proof.Proof_idle (Some "first line\r\nsecond line\r\n")
  in
  let inner_cr = texts (Detail.body ~ko:false ~width:60 Proof.Proof_idle (Some "a\rb")) in
  let texts = texts rows in
  check_bool "the first line is its own row without its CR" true
    (List.mem "first line" texts);
  check_bool "the second line is its own row without its CR" true
    (List.mem "second line" texts);
  check_bool "no CR is printed as an escape" true
    (List.for_all
       (fun text ->
          let needle = "\\x0D" in
          let n = String.length needle in
          let rec found i =
            i + n <= String.length text && (String.sub text i n = needle || found (i + 1))
          in
          not (found 0))
       texts);
  check_bool "a CR inside a line is still escaped" true
    (List.mem "a\\x0Db" inner_cr)

let test_a_narrow_pane_still_produces_rows () =
  let rows = Detail.body ~ko:false ~width:0 (Proof.Proof_refuted (Some "why")) None in
  check_bool "width 0 does not loop or vanish" true (rows <> [])

let confirmation_fixture ?(goal_id = "goal-1") ?(revision = "revision-1")
    ?(metric = "passing scenarios") ?(run_id = "run-1") ?(confirmed = false) ?phase
    ?(evidence = "10 scenarios passed\nObserved result retained")
    ?(submitted : Yojson.Safe.t list = []) () =
  let phase = match phase with
    | Some phase -> phase
    | None -> if confirmed then Goal_phase.Completed else Goal_phase.Awaiting_confirmation in
  let criterion = Goal_store.Criterion
      { revision = "revision-1"; title = "Harness";
        metric = Some "passing scenarios"; target_value = Some "10" } in
  let verdict : Goal_verification.verdict =
    { outcome = Proven; request_id = "request-1"; criterion;
      verification_run_id = run_id;
      authority = Masc_domain.System_llm_agent { agent_run_id = run_id };
      evidence;
      recorded_at = "2026-09-19T08:00:00Z" } in
  let completion =
    if confirmed then Goal_verification.Human_confirmed
      (verdict, { operator_id = "operator"; confirmed_at = "2026-09-19T08:01:00Z" })
    else Goal_verification.Proof_proven verdict in
  let record = { (Goal_verification.default_record ~goal_id) with completion } in
  (* The server answers with the metadata projection of the submitted
     originals, never their contents, so the fixture rewrites the record's
     full-form list into the projected items a real answer carries. *)
  let verification =
    match Goal_verification.record_to_yojson record with
    | `Assoc fields ->
        `Assoc (List.map (fun (key, value) ->
            if String.equal key "submitted_evidence" then key, `List submitted
            else key, value) fields)
    | other -> other
  in
  `Assoc
    [ "inspection_operator_id", `String "operator-current"
    ; "goal", `Assoc
        [ "id", `String goal_id
        ; "phase", Goal_phase.to_yojson phase
        ; "title", `String "Harness"
        ; "criterion_revision", `String revision
        ; "metric", `String metric
        ; "target_value", `String "10"
        ]
    ; "verification", verification
    ]

(* The metadata projection of every kind, plus one kind this build does not
   know, in wire form. *)
let submitted_originals_json =
  [ `Assoc
      [ "kind", `String "artifact"; "reference", `String "run.log"
      ; "bytes", `Int 12_698; "truncated", `Bool true ]
  ; `Assoc
      [ "kind", `String "artifact_binary"; "reference", `String "screen.png"
      ; "bytes", `Int 1_258_291; "sha256", `String (String.make 64 'a')
      ; "format", `String "png" ]
  ; `Assoc
      [ "kind", `String "collaboration"; "reference", `String "board:p-1"
      ; "bytes", `Int 987; "content_omitted", `Bool true ]
  ; `Assoc [ "kind", `String "note"; "bytes", `Int 240 ]
  ; `Assoc
      [ "kind", `String "artifact_unreadable"; "reference", `String "gone.log"
      ; "reason", `String "ev_read_error" ]
  ; `Assoc [ "kind", `String "hologram"; "anything", `Bool true ]
  ]

let confirmation_base_path, confirmation_root_path =
  let base = Filename.temp_file "masc-goal-base-" "" in
  Fun.protect ~finally:(fun () -> Sys.remove base) (fun () ->
    let root = Filename.temp_file "masc-goal-root-" "" in
    Fun.protect ~finally:(fun () -> Sys.remove root) (fun () ->
      Masc.Tui_decode.Canonical_path.of_path base,
      Masc.Tui_decode.Canonical_path.of_path root))

let confirmation_identity : Masc.Tui_decode.server_identity = {
  sid_version = "test";
  sid_binary_commit = "test";
  sid_binary_commit_age_s = None;
  sid_runtime_instance_id = Some "instance-1";
  sid_base_path = confirmation_base_path;
  sid_masc_root = confirmation_root_path;
  sid_executable_in_worktree = None;
  sid_state_ready = Some true;
  sid_uptime = None;
  sid_sse_clients = None;
  sid_gc = None;
  sid_scheduler = None; sid_operator_action = None;
}

let confirmation_workspace = Detail.confirmation_workspace_of_identity confirmation_identity

let confirmation_owner = ref ()

let confirmation_exn json =
  match Detail.decode_confirmation ~goal_id:"goal-1" ~runtime_instance_id:"instance-1" ~workspace:confirmation_workspace ~credential_headers:[] ~credential_owner:confirmation_owner json with
  | Ok confirmation -> confirmation
  | Error detail -> Alcotest.fail detail

let test_confirmation_retains_the_displayed_proof () =
  let read = confirmation_exn (confirmation_fixture ()) in
  let sent = Detail.confirmation_body read in
  check_bool "POST binds the inspected proof" true
    (sent = `Assoc
       [ "goal_id", `String "goal-1"; "criterion_revision", `String "revision-1";
         "request_id", `String "request-1"; "verification_run_id", `String "run-1"; "expected_operator_id", `String "operator-current";
         "expected_runtime_instance_id", `String "instance-1";
         "expected_workspace", `Assoc
           [ "base_path", `String (Masc.Tui_decode.Canonical_path.to_string confirmation_identity.sid_base_path)
           ; "masc_root", `String (Masc.Tui_decode.Canonical_path.to_string confirmation_identity.sid_masc_root) ] ]);
  let newer = confirmation_exn (confirmation_fixture ~run_id:"run-2" ()) in
  check_bool "a newer verifier run cannot replace the inspected one" false
    (Detail.same_confirmation_binding read newer);
  let changed = confirmation_exn (confirmation_fixture ~evidence:"different evidence" ()) in
  check_bool "changed evidence cannot replace the inspected verdict" false
    (Detail.same_confirmation_binding read changed);
  let read_with_workspace workspace =
    match Detail.decode_confirmation ~goal_id:"goal-1" ~runtime_instance_id:"instance-1"
      ~workspace ~credential_headers:[] ~credential_owner:confirmation_owner (confirmation_fixture ()) with
    | Ok value -> value | Error error -> Alcotest.fail error in
  let foreign = read_with_workspace Detail.{base_path=confirmation_identity.sid_masc_root;
    masc_root=confirmation_identity.sid_base_path} in
  check_bool "identical proof in another workspace is not the same binding" false
    (Detail.same_confirmation_binding read foreign);
  let foreign_base = read_with_workspace Detail.{confirmation_workspace with base_path=foreign.workspace.base_path} in
  check_bool "another workspace base cannot retain the inspected binding" false
    (Detail.same_confirmation_binding read foreign_base);
  let foreign_root = read_with_workspace Detail.{confirmation_workspace with masc_root=foreign.workspace.masc_root} in
  check_bool "another workspace root cannot retain the inspected binding" false
    (Detail.same_confirmation_binding read foreign_root);
  let foreign_owner = match Detail.decode_confirmation ~goal_id:"goal-1" ~runtime_instance_id:"instance-1"
      ~workspace:confirmation_workspace ~credential_headers:[] ~credential_owner:(ref ()) (confirmation_fixture ()) with
    | Ok value -> value | Error error -> Alcotest.fail error in
  check_bool "identical proof under another credential owner is not the same binding" false
    (Detail.same_confirmation_binding read foreign_owner);
  let foreign_instance = match Detail.decode_confirmation ~goal_id:"goal-1" ~runtime_instance_id:"instance-2"
      ~workspace:confirmation_workspace ~credential_headers:[] ~credential_owner:confirmation_owner (confirmation_fixture ()) with
    | Ok value -> value | Error error -> Alcotest.fail error in
  check_bool "identical proof from another server is not the same binding" false
    (Detail.same_confirmation_binding read foreign_instance);
  let receipt = Detail.confirmation_receipt_authority read in
  let current ~instance confirmation =
    Detail.receipt_authority_current ~credential_current:true ~current_instance:(Some instance)
      ~current_confirmation:confirmation ~receipt in
  check_bool "same operator and server own the receipt" true (current ~instance:"instance-1" (Some read));
  check_bool "different server cannot expose receipt detail" false (current ~instance:"instance-2" (Some read));
  check_bool "a failed or in-flight reread cannot expose receipt detail" false (current ~instance:"instance-1" None);
  check_bool "another workspace cannot expose receipt detail" false (current ~instance:"instance-1" (Some foreign));
  check_bool "another workspace base cannot expose receipt detail" false (current ~instance:"instance-1" (Some foreign_base));
  check_bool "another workspace root cannot expose receipt detail" false (current ~instance:"instance-1" (Some foreign_root));
  let other_operator = { read with Detail.inspection_operator_id = "different-operator" } in
  check_bool "the same credential reassigned to another operator cannot expose receipt detail" false
    (current ~instance:"instance-1" (Some other_operator));
  let error_for credential_is_current error =
    Detail.confirmation_read_error_message ~ko:false ~credential_is_current error in
  let refused = Detail.Read_failed (Some confirmation_owner, "private earlier HTTP 403") in
  check_bool "an error body is withheld even for the current credential" false
    (contains "private earlier" (error_for (fun owner -> owner == confirmation_owner) refused));
  check_string "the status stays visible without the response body" "Goal confirmation read failed (HTTP 403)"
    (error_for (fun owner -> owner == confirmation_owner) (Detail.Read_http_error (confirmation_owner, 403)));
  check_bool "a retired credential's error body is not shown" false
    (contains "private earlier" (error_for (fun owner -> owner == foreign_owner.credential_owner) refused));
  check_bool "an unowned boundary error is not shown" false
    (contains "private earlier" (error_for (fun _ -> true) (Detail.Read_failed (None, "private earlier"))));
  (match Masc_tui_fetched.start ~equal:String.equal Masc_tui_fetched.initial ~key:"goal-1" with
   | Already_loading -> Alcotest.fail "error read did not start"
   | Started (loading, request) ->
       let failed = Masc_tui_fetched.complete ~equal:String.equal loading request (Error refused) in
       (match Detail.confirmation_view_for failed ~goal_id:"goal-1" with
        | Failed retained ->
            check_bool "settled failure still hides detail after the credential changes" false
              (contains "private earlier" (error_for (fun owner -> owner == foreign_owner.credential_owner) retained))
        | _ -> Alcotest.fail "failure was not retained"));
  let hidden = Detail.receipt_outcome_text ~ko:false ~current:false (Error "secret proof detail") in
  check_bool "earlier unknown outcome is visible without proof detail" true
    (contains "outcome unconfirmed" hidden && not (contains "secret proof detail" hidden));
  let confirmed = confirmation_exn (confirmation_fixture ~confirmed:true ()) in
  check_bool "the server confirmed the same binding" true
    (Detail.same_confirmation_binding read confirmed);
  check_bool "an unconfirmed proof cannot satisfy readback" false
    (Detail.same_recorded_confirmation read confirmed);
  check_bool "matching confirmation attribution satisfies readback" true
    (Detail.same_recorded_confirmation confirmed confirmed);
  let changed_confirmation = { confirmed with Detail.recorded_confirmation =
    Some Goal_verification.{operator_id = "other"; confirmed_at = "different"} } in
  check_bool "readback cannot change the confirmation attribution" false
    (Detail.same_recorded_confirmation confirmed changed_confirmation);
  let rendered = texts (Detail.confirmation_lines ~width:80 ~ko:false read) in
  (* The binding wraps at narrow widths -- at 80 cells the break lands between
     "run" and "run-1" -- so the exact run is asserted as content of the
     fine-print rows rather than one whole row. *)
  check_bool "operator sees exact run" true
    (List.exists (contains "run-1") rendered);
  check_bool "evidence keeps its second line" true
    (List.mem "  Observed result retained" rendered)

(* The confirmation block includes the candidate-coverage limit before the
   evidence, preserving the existing last-evidence-row presentation check. *)
let test_confirmation_reads_in_layers () =
  let read = confirmation_exn (confirmation_fixture ()) in
  let ko_rows = Detail.confirmation_lines ~width:80 ~ko:true read in
  check_string "korean header names the decision"
    "[ 판정 확인 ]" (List.hd (texts ko_rows));
  (match List.find_opt (fun (row : Detail.line) -> row.Detail.tone = Detail.Waiting) ko_rows with
   | None -> Alcotest.fail "no instruction row"
   | Some row ->
       check_bool "korean instruction leads with the action" true
         (String.length row.Detail.text >= 10
          && String.sub row.Detail.text 0 10 = "이 증명"));
  check_bool "the instruction is the only warn row" true
    (List.length
       (List.filter (fun (row : Detail.line) -> row.Detail.tone = Detail.Waiting) ko_rows)
     = 1);
  check_bool "the promise reads at plain volume" true
    (List.mem (Printf.sprintf "%-10s" "Title:" ^ "Harness") (texts ko_rows));
  check_bool "the binding is fine print" true
    (List.exists
       (fun (row : Detail.line) ->
          row.Detail.tone = Detail.Quiet && row.Detail.text <> ""
          && String.sub row.Detail.text 0 10 = Printf.sprintf "%-10s" "Binding:")
       ko_rows);
  let en_rows = Detail.confirmation_lines ~width:80 ~ko:false read in
  check_bool "english keeps its instruction" true
    (List.exists
       (fun (row : Detail.line) ->
          String.length row.Detail.text >= 18
          && String.sub row.Detail.text 0 18 = "CONFIRM THIS PROOF")
       en_rows);
  let last = List.nth ko_rows (List.length ko_rows - 1) in
  check_bool "the evidence remains the last group" true
    (last.Detail.tone = Detail.Plain
     && last.Detail.text = "  Observed result retained")

(* The submitted originals arrive as metadata -- identity and size, a binary
   original's file digest, no contents. They draw as one labelled list under
   the evidence paragraph, and a kind this build does not know stays on
   screen. *)
let test_confirmation_lists_submitted_originals () =
  let read = confirmation_exn (confirmation_fixture ~submitted:submitted_originals_json ()) in
  let rows = Detail.confirmation_lines ~width:80 ~ko:false read in
  let rendered = texts rows in
  check_bool "every original is on screen" true
    (List.for_all (fun needle -> List.exists (contains needle) rendered)
       [ "artifact run.log · 12.4 KB · truncated"
       ; "binary screen.png · png · 1.2 MB · sha256 aaaaaaaaaaaa"
       ; "collaboration board:p-1 · 987 B"
       ; "note · 240 B"
       ; "unreadable gone.log · ev_read_error"
       ; "unknown kind hologram" ]);
  check_bool "the list starts at the Submitted label, at reading volume" true
    (List.exists (fun (row : Detail.line) ->
         String.length row.Detail.text >= 10
         && String.sub row.Detail.text 0 10 = Printf.sprintf "%-10s" "Submitted:"
         && row.Detail.tone = Detail.Plain) rows);
  let last = List.nth rows (List.length rows - 1) in
  check_bool "the list remains the last group" true
    (last.Detail.tone = Detail.Plain
     && last.Detail.text = "          unknown kind hologram")

(* No originals means no list; the evidence remains the final group. *)
let test_confirmation_without_originals_draws_no_list () =
  let rows = Detail.confirmation_lines ~width:80 ~ko:false
      (confirmation_exn (confirmation_fixture ())) in
  check_bool "no Submitted label without originals" true
    (List.for_all (fun (row : Detail.line) ->
         String.length row.Detail.text < 10
         || String.sub row.Detail.text 0 10 <> Printf.sprintf "%-10s" "Submitted:") rows);
  let last = List.nth rows (List.length rows - 1) in
  check_bool "the evidence paragraph still ends the block" true
    (last.Detail.text = "  Observed result retained")

(* A present-but-broken item fails the whole read: the projection is written
   by the same server that wrote the proof, so half an item is a contract
   break, not a formatting quirk. *)
let test_confirmation_refuses_a_broken_original () =
  let broken =
    [ `Assoc [ "kind", `String "artifact"; "reference", `String "run.log" ] ] in
  check_bool "a present-but-broken item fails the read" true
    (Result.is_error
       (Detail.decode_confirmation ~goal_id:"goal-1" ~runtime_instance_id:"instance-1" ~workspace:confirmation_workspace ~credential_headers:[] ~credential_owner:confirmation_owner
          (confirmation_fixture ~submitted:broken ())))

(* The server records a confirmation before it runs the caller's step and saves
   the phase. If the step refuses, or the phase cannot be saved, the goal stays
   awaiting confirmation with the confirmation recorded. Confirming again is how
   the operator finishes it, so this state has to read as confirmable. *)
let test_a_recorded_confirmation_that_did_not_complete_can_be_confirmed_again () =
  let recorded =
    confirmation_exn
      (confirmation_fixture ~confirmed:true ~phase:Goal_phase.Awaiting_confirmation ())
  in
  check_bool "the goal is still awaiting confirmation" true
    (recorded.phase = Goal_phase.Awaiting_confirmation);
  let rows = texts (Detail.confirmation_lines ~width:100 ~ko:false recorded) in
  check_bool "the first operator and time are visible before resuming" true
    (List.exists (contains "operator · 2026-09-19T08:01:00Z") rows);
  check_bool "the remaining completion is not presented as done" true
    (List.exists (contains "not yet verified") rows);
  check_bool "the same proof is bound" true
    (Detail.confirmation_body recorded
     = `Assoc
         [ "goal_id", `String "goal-1"; "criterion_revision", `String "revision-1";
           "request_id", `String "request-1"; "verification_run_id", `String "run-1"; "expected_operator_id", `String "operator-current";
         "expected_runtime_instance_id", `String "instance-1";
           "expected_workspace", `Assoc
             [ "base_path", `String (Masc.Tui_decode.Canonical_path.to_string confirmation_identity.sid_base_path)
             ; "masc_root", `String (Masc.Tui_decode.Canonical_path.to_string confirmation_identity.sid_masc_root) ] ]);
  let completed = confirmation_exn (confirmation_fixture ~confirmed:true ()) in
  check_bool "the completed answer binds the same proof" true
    (Detail.same_confirmation_binding recorded completed)

let test_confirmation_refuses_unrelated_or_changed_proof () =
  List.iter
    (fun json -> check_bool "unrelated or changed proof refused" true
      (Result.is_error (Detail.decode_confirmation ~goal_id:"goal-1" ~runtime_instance_id:"instance-1" ~workspace:confirmation_workspace ~credential_headers:[] ~credential_owner:confirmation_owner json)))
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
    (Result.is_error (Detail.decode_confirmation ~goal_id:"goal-1" ~runtime_instance_id:"instance-1" ~workspace:confirmation_workspace ~credential_headers:[] ~credential_owner:confirmation_owner stale))

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

let test_confirmation_read_suspension_withdraws_ready_proof () =
  let module Read = Masc_tui_fetched in
  match Read.start ~equal:String.equal Read.initial ~key:"goal-1" with
  | Already_loading -> Alcotest.fail "initial read did not start"
  | Started (loading, request) ->
      let ready = Read.complete ~equal:String.equal loading request
          (Ok (confirmation_exn (confirmation_fixture ()))) in
      (match Read.start ~equal:String.equal ready ~key:"goal-1" with
       | Already_loading -> Alcotest.fail "revalidation did not start"
       | Started (refreshing, _) ->
           check_bool "revalidation immediately hides the former ready proof" true
             (match Detail.confirmation_view_for refreshing ~goal_id:"goal-1" with Loading -> true | _ -> false);
           check_bool "a different Goal stays absent" true
             (match Detail.confirmation_view_for refreshing ~goal_id:"goal-2" with Absent -> true | _ -> false));
      let suspended = Detail.suspend_confirmation_read ready in
      check_bool "the original key survives for recovery" true (Read.current_key suspended = Some "goal-1");
      check_bool "the old proof is no longer ready" true
        (match Read.view_for ~equal:String.equal suspended ~key:"goal-1" with Stale _ -> true | _ -> false);
      (match Read.start ~equal:String.equal suspended ~key:"goal-1" with
       | Already_loading -> Alcotest.fail "recovery did not start"
       | Started (refreshing, _) ->
           check_bool "the replacement remains in flight" true (Read.in_flight refreshing))

let () =
  Alcotest.run "tui_planning_detail"
    [ ( "body"
      , [ Alcotest.test_case "tone separates a refusal from a proof" `Quick
            test_tone_separates_a_refusal_from_a_proof
        ; Alcotest.test_case "a stuck goal says which step and why" `Quick
            test_a_stuck_goal_says_which_step_and_why
        ; Alcotest.test_case "a stuck goal offers the retry first" `Quick
            test_a_stuck_goal_offers_the_retry_first
        ; Alcotest.test_case "verdict and note reach the pane escaped" `Quick
            test_verdict_and_note_reach_the_pane_escaped
        ; Alcotest.test_case "a note with a newline draws two lines" `Quick
            test_a_note_with_a_newline_draws_two_lines
        ; Alcotest.test_case "a CRLF note draws its lines without the CR" `Quick
            test_a_crlf_note_draws_its_lines_without_the_cr
        ; Alcotest.test_case "a narrow pane still produces rows" `Quick
            test_a_narrow_pane_still_produces_rows
        ; Alcotest.test_case "confirmation retains the displayed proof" `Quick
            test_confirmation_retains_the_displayed_proof
        ; Alcotest.test_case "confirmation reads in layers" `Quick
            test_confirmation_reads_in_layers
        ; Alcotest.test_case "confirmation lists submitted originals" `Quick
            test_confirmation_lists_submitted_originals
        ; Alcotest.test_case "confirmation without originals draws no list" `Quick
            test_confirmation_without_originals_draws_no_list
        ; Alcotest.test_case "confirmation refuses a broken original" `Quick
            test_confirmation_refuses_a_broken_original
        ; Alcotest.test_case "a recorded confirmation that did not complete can be confirmed again" `Quick
            test_a_recorded_confirmation_that_did_not_complete_can_be_confirmed_again
        ; Alcotest.test_case "confirmation refuses unrelated or changed proof" `Quick
            test_confirmation_refuses_unrelated_or_changed_proof
        ; Alcotest.test_case "cancelled confirmation ignores late read" `Quick
            test_confirmation_read_cannot_rearm_after_cancel
        ; Alcotest.test_case "suspension withdraws ready confirmation" `Quick
            test_confirmation_read_suspension_withdraws_ready_proof
        ] )
    ]
