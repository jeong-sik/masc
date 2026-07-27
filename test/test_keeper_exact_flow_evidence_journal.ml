open Alcotest

module EO = Agent_sdk.Exact_output
module Journal = Masc.Keeper_exact_flow_evidence_journal
module Keeper_fs = Masc.Keeper_fs

let sha256 value = Digestif.SHA256.(to_hex (digest_string value))

let decode_domain encoded =
  match EO.domain_settlement_intent_of_string encoded with
  | Ok intent -> intent
  | Error _ -> fail "current domain settlement fixture did not decode"
;;

let domain_intent disposition =
  let structural =
    [ "format", `String "oas.exact-output.domain-settlement-intent"
    ; "version", `Int 1
    ; "flow_id", `String "flow-journal-test"
    ; "scope", `String "/masc/test/journal"
    ; "reservation_ordinal", `String "1"
    ; "candidate_id", `String "candidate-a"
    ; "candidate_binding_sha256", `String (String.make 64 'a')
    ; "success_ordinal", `String "1"
    ; "execution_evidence_sha256", `String (String.make 64 'b')
    ]
  in
  let settlement_id = `Assoc structural |> Yojson.Safe.to_string |> sha256 in
  let payload =
    structural
    @ [ "settlement_id", `String settlement_id
      ; "disposition", `String disposition
      ]
  in
  let integrity_sha256 = `Assoc payload |> Yojson.Safe.to_string |> sha256 in
  `Assoc (payload @ [ "integrity_sha256", `String integrity_sha256 ])
  |> Yojson.Safe.to_string
  |> decode_domain
;;

let decode_retirement encoded =
  match EO.flow_preference_retirement_intent_of_string encoded with
  | Ok intent -> intent
  | Error _ -> fail "current scope retirement fixture did not decode"
;;

let retirement_intent () =
  let structural =
    [ "format", `String "oas.exact-output.flow-preference-retirement-intent"
    ; "version", `Int 1
    ; "scope", `String "/masc/test/journal"
    ; "reservation_ordinal", `String "1"
    ; "success_high_water", `String "1"
    ]
  in
  let retirement_id = `Assoc structural |> Yojson.Safe.to_string |> sha256 in
  let payload = structural @ [ "retirement_id", `String retirement_id ] in
  let integrity_sha256 = `Assoc payload |> Yojson.Safe.to_string |> sha256 in
  `Assoc (payload @ [ "integrity_sha256", `String integrity_sha256 ])
  |> Yojson.Safe.to_string
  |> decode_retirement
;;

let with_workspace f =
  Eio_main.run
  @@ fun env ->
  Masc_test_deps.init_eio_clock env;
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Masc_test_deps.setup_test_workspace () in
  Fun.protect
    ~finally:(fun () ->
      Masc_test_deps.cleanup_test_workspace base_path;
      Fs_compat.clear_fs ())
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       f base_path)
;;

let recover_with_writer ~durable_write base_path =
  match
    Journal.For_testing.recover
      ~durable_write
      ~base_path
      ~keeper_name:"journal-test"
      ~keeper_generation:"lane-journal-test"
      ~surface:"compaction"
      ~concurrent_scope_budget:1
  with
  | Ok recovered -> recovered
  | Error error -> fail (Journal.load_error_to_string error)
;;

let fake_write_error =
  { Keeper_fs.renamed = false
  ; stage = Keeper_fs.Payload_write
  ; failure = Keeper_fs.Operation_failed "injected journal write failure"
  }
;;

let test_commit_error_is_typed_and_does_not_advance_journal () =
  with_workspace
  @@ fun base_path ->
  let writes = ref 0 in
  let durable_write ~on_durable_commit ~ownership_root:_ ~path:_ ~bytes:_ =
    incr writes;
    if !writes = 1
    then (
      on_durable_commit ();
      Ok Keeper_fs.Committed)
    else Error fake_write_error
  in
  let journal, _, _ = recover_with_writer ~durable_write base_path in
  (match Journal.commit_domain_settlement journal (domain_intent "domain_valid") with
   | Error (Journal.Evidence_write_failed _) -> ()
   | Ok () | Error (Journal.Evidence_conflict _) ->
     fail "journal write failure lost its typed commit outcome");
  check int "failed commit retained no evidence" 0 (Journal.evidence_count journal)
;;

let test_cancellation_preserves_backtrace_after_durable_observer () =
  with_workspace
  @@ fun base_path ->
  let writes = ref 0 in
  let durable_write ~on_durable_commit ~ownership_root:_ ~path:_ ~bytes:_ =
    incr writes;
    on_durable_commit ();
    if !writes = 1
    then Ok Keeper_fs.Committed
    else (
      let cancelled =
        Eio.Cancel.Cancelled (Failure "injected exact-flow journal cancellation")
      in
      Printexc.raise_with_backtrace cancelled (Printexc.get_callstack 32))
  in
  let journal, _, _ = recover_with_writer ~durable_write base_path in
  let cancellation_backtrace =
    try
      ignore
        (Journal.commit_domain_settlement journal (domain_intent "domain_valid"));
      None
    with
    | Eio.Cancel.Cancelled (Failure detail)
      when String.equal detail "injected exact-flow journal cancellation" ->
      Some (Printexc.get_raw_backtrace () |> Printexc.raw_backtrace_to_string)
    | exn -> raise exn
  in
  let backtrace_preserved =
    match cancellation_backtrace with
    | Some backtrace -> not (String.equal backtrace "")
    | None -> false
  in
  check bool "cancellation escaped with a backtrace" true backtrace_preserved;
  check int "durable observer retained committed evidence" 1
    (Journal.evidence_count journal)
;;

let test_restart_replays_complete_current_evidence () =
  with_workspace
  @@ fun base_path ->
  let recover () =
    Journal.recover
      ~base_path
      ~keeper_name:"journal-test"
      ~keeper_generation:"lane-journal-test"
      ~surface:"compaction"
      ~concurrent_scope_budget:1
  in
  let journal =
    match recover () with
    | Ok (journal, _, Journal.Fresh_start) -> journal
    | Ok (_, _, Journal.Recovered _) -> fail "missing journal was not a fresh start"
    | Error error -> fail (Journal.load_error_to_string error)
  in
  (match Journal.commit_domain_settlement journal (domain_intent "domain_valid") with
   | Ok () -> ()
   | Error error -> fail (Journal.commit_error_to_string error));
  match recover () with
  | Ok (recovered, _, Journal.Recovered { evidence_count = 1 }) ->
    check int "restart loaded one complete intent" 1
      (Journal.evidence_count recovered)
  | Ok _ -> fail "restart did not report the complete recovered evidence set"
  | Error error -> fail (Journal.load_error_to_string error)
;;

let test_duplicate_same_intent_is_idempotent () =
  with_workspace
  @@ fun base_path ->
  let writes = ref 0 in
  let durable_write ~on_durable_commit ~ownership_root:_ ~path:_ ~bytes:_ =
    incr writes;
    on_durable_commit ();
    Ok Keeper_fs.Committed
  in
  let journal, _, _ = recover_with_writer ~durable_write base_path in
  let intent = domain_intent "domain_valid" in
  List.iter
    (fun () ->
       match Journal.commit_domain_settlement journal intent with
       | Ok () -> ()
       | Error error -> fail (Journal.commit_error_to_string error))
    [ (); () ];
  check int "initialization plus one logical append" 2 !writes;
  check int "duplicate did not create a second entry" 1
    (Journal.evidence_count journal)
;;

let test_same_id_conflict_fails_closed () =
  with_workspace
  @@ fun base_path ->
  let writes = ref 0 in
  let durable_write ~on_durable_commit ~ownership_root:_ ~path:_ ~bytes:_ =
    incr writes;
    on_durable_commit ();
    Ok Keeper_fs.Committed
  in
  let journal, _, _ = recover_with_writer ~durable_write base_path in
  (match Journal.commit_domain_settlement journal (domain_intent "domain_valid") with
   | Ok () -> ()
   | Error error -> fail (Journal.commit_error_to_string error));
  (match
     Journal.commit_domain_settlement journal (domain_intent "domain_rejected")
   with
   | Error
       (Journal.Evidence_conflict
          { kind = Journal.Domain_settlement; _ }) -> ()
   | Ok () | Error _ -> fail "opposite disposition did not fail closed");
  check int "conflict performed no durable write" 2 !writes;
  check int "conflict retained original evidence only" 1
    (Journal.evidence_count journal)
;;

let test_retirement_commit_is_durable_before_effect () =
  with_workspace
  @@ fun base_path ->
  let writes = ref 0 in
  let events = ref [] in
  let durable_write ~on_durable_commit ~ownership_root:_ ~path:_ ~bytes:_ =
    incr writes;
    if !writes > 1 then events := !events @ [ "write" ];
    on_durable_commit ();
    if !writes > 1 then events := !events @ [ "durable" ];
    Ok Keeper_fs.Committed
  in
  let journal, _, _ = recover_with_writer ~durable_write base_path in
  (match Journal.commit_scope_retirement journal (retirement_intent ()) with
   | Ok () -> events := !events @ [ "oas_effect" ]
   | Error error -> fail (Journal.commit_error_to_string error));
  check (list string) "retirement ordering"
    [ "write"; "durable"; "oas_effect" ] !events
;;

let test_invalid_current_journal_is_typed_and_not_defaulted () =
  with_workspace
  @@ fun base_path ->
  let journal, _, _ =
    match
      Journal.recover
        ~base_path
        ~keeper_name:"journal-test"
        ~keeper_generation:"lane-journal-test"
        ~surface:"compaction"
        ~concurrent_scope_budget:1
    with
    | Ok recovered -> recovered
    | Error error -> fail (Journal.load_error_to_string error)
  in
  (match Fs_compat.save_file_atomic (Journal.path journal) "{}" with
   | Ok () -> ()
   | Error detail -> fail detail);
  match
    Journal.recover
      ~base_path
      ~keeper_name:"journal-test"
      ~keeper_generation:"lane-journal-test"
      ~surface:"compaction"
      ~concurrent_scope_budget:1
  with
  | Error (Journal.Journal_decode_failed _) -> ()
  | Ok _ | Error _ -> fail "invalid current journal was default-filled or erased"
;;

let () =
  run
    "keeper exact-flow evidence journal"
    [ ( "current-schema durability"
      , [ test_case "commit error is typed" `Quick
            test_commit_error_is_typed_and_does_not_advance_journal
        ; test_case "cancellation preserves backtrace" `Quick
            test_cancellation_preserves_backtrace_after_durable_observer
        ; test_case "restart replays complete evidence" `Quick
            test_restart_replays_complete_current_evidence
        ; test_case "same-intent replay is idempotent" `Quick
            test_duplicate_same_intent_is_idempotent
        ; test_case "same-id conflict fails closed" `Quick
            test_same_id_conflict_fails_closed
        ; test_case "retirement is durable before effect" `Quick
            test_retirement_commit_is_durable_before_effect
        ; test_case "invalid current journal is typed" `Quick
            test_invalid_current_journal_is_typed_and_not_defaulted
        ] )
    ]
;;
