(** Goal confirmation retains the inspected proof, submitted metadata and
    workspace authority. Wire text cannot inject terminal controls, and private
    receipts cannot escape their credential boundary. *)

module Detail = Masc_tui_planning_detail
module Proof = Masc.Tui_decode

let texts rows = List.map (fun (r : Detail.line) -> r.Detail.text) rows

let contains needle text =
  let n = String.length needle in
  let rec from i =
    if i + n > String.length text then false
    else if String.sub text i n = needle then true
    else from (i + 1)
  in
  from 0

let check_bool = Alcotest.(check bool)
(* Verifier reasons and notes are untrusted wire text, including control bytes
   within ordinary LF/CRLF multiline content. *)
let test_wire_text_cannot_inject_terminal_controls () =
  let body =
    Detail.body ~ko:false ~width:60
      (Proof.Proof_refuted (Some "refused\x1b[2J by the judge"))
      (Some "first line\nsecond\x1b]52;c;cGFzdGU=\x07 here\r\ninner\rcontrol")
  in
  let unreconciled =
    Detail.unreconciled_lines ~ko:false ~width:60
      { Proof.vu_step = Goal_reconcile_step.Rearm_proof
      ; vu_detail = "criterion already proven\x1b[2J"
      }
  in
  check_bool "both untrusted-text boundaries produce checked output" true
    (body <> [] && unreconciled <> []);
  check_bool "no raw terminal control byte escapes either wire boundary" true
    (List.for_all
       (fun text -> String.for_all (fun c -> Char.code c >= 0x20 && c <> '\x7f') text)
       (texts (body @ unreconciled)))

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

let test_confirmation_retains_the_inspected_proof () =
  let read = confirmation_exn (confirmation_fixture ()) in
  Alcotest.(check string) "the complete inspected evidence is retained"
    "10 scenarios passed\nObserved result retained" read.verdict.evidence;
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
  check_bool "a former receipt never exposes private proof detail" false
    (contains "secret proof detail" hidden);
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
    (Detail.same_recorded_confirmation confirmed changed_confirmation)

(* The read retains metadata identity, size, digest and unknown kinds without
   requiring any particular presentation. *)
let test_confirmation_decodes_submitted_metadata () =
  let read = confirmation_exn (confirmation_fixture ~submitted:submitted_originals_json ()) in
  let expected : Detail.submitted_original list =
    [ Original_artifact { reference = "run.log"; bytes = 12_698; truncated = true }
    ; Original_binary { reference = "screen.png"; bytes = 1_258_291;
                        sha256 = String.make 64 'a'; format = "png" }
    ; Original_collaboration { reference = "board:p-1"; bytes = 987 }
    ; Original_note { bytes = 240 }
    ; Original_unreadable { reference = Some "gone.log"; reason = "ev_read_error" }
    ; Original_unknown "hologram"
    ]
  in
  check_bool "all submitted metadata variants survive the read" true
    (List.length read.submitted = List.length expected
     && List.for_all (fun original -> List.mem original read.submitted) expected);
  let empty = confirmation_exn (confirmation_fixture ()) in
  check_bool "no submissions remain an empty typed metadata list" true (empty.submitted = [])

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
  check_bool "recorded attribution survives an incomplete phase transition" true
    (recorded.recorded_confirmation =
       Some Goal_verification.{operator_id = "operator"; confirmed_at = "2026-09-19T08:01:00Z"});
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
    [ ( "confirmation boundaries"
      , [ Alcotest.test_case "wire text cannot inject terminal controls" `Quick
            test_wire_text_cannot_inject_terminal_controls
        ; Alcotest.test_case "confirmation retains the inspected proof" `Quick
            test_confirmation_retains_the_inspected_proof
        ; Alcotest.test_case "confirmation decodes submitted metadata" `Quick
            test_confirmation_decodes_submitted_metadata
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
