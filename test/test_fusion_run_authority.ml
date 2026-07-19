open Alcotest
open Fusion_types
module A = Fusion_run_authority
let fresh_base () =
  let path = Filename.temp_file "fusion-authority-" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  path
;;
let usage input_tokens output_tokens : Fusion_types.usage =
  { input_tokens; output_tokens }
;;

let synthesis resolved_answer : Fusion_types.judge_synthesis =
  { consensus = [ { text = "typed consensus"; supporting_models = [ "panel-a" ] } ]
  ; contradictions = []
  ; partial_coverage = []
  ; unique_insights = [ { insight_text = "typed insight"; from_model = "panel-a" } ]
  ; blind_spots = [ "unobserved edge" ]
  ; resolved_answer
  ; decision = Answer resolved_answer
  }
;;

let successful_evidence () : Fusion_types.deliberation_evidence =
  let judge = synthesis "durable answer" in
  { question = "Which design preserves the authority boundary?"
  ; panel =
      [ Answered { model = "panel-a"; answer = "typed answer"; usage = usage 7 3 }
      ; Failed { failed_model = "panel-b"; reason = Provider_error "transport" }
      ]
  ; judge = Ok judge
  ; judges =
      [ Synthesized { role = First "judge-a"; synthesis = judge; usage = usage 11 5 }
      ; Judge_failed
          { failed_role = First "judge-b"
          ; failure = Timeout
          ; usage = usage 13 0
          ; elapsed_s = Some 0.5
          }
      ]
  ; judge_usage = usage 24 5
  }
;;

let failed_evidence () : Fusion_types.deliberation_evidence =
  let failure = Panels_unavailable (No_panel_answers { total = 1 }) in
  { question = "Can a typed judge failure survive restart?"
  ; panel = [ Failed { failed_model = "panel-a"; reason = Timeout } ]
  ; judge = Error failure
  ; judges =
      [ Judge_failed
          { failed_role = Single
          ; failure
          ; usage = usage 2 0
          ; elapsed_s = Some 0.25
          }
      ]
  ; judge_usage = usage 2 0
  }
;;

let deliberated evidence = A.Computation_committed evidence
let run_file directory keeper run_id =
  let key = Printf.sprintf "%d:%s%d:%s" (String.length keeper) keeper (String.length run_id) run_id in
  let digest = Digestif.SHA256.(digest_string key |> to_hex) in
  Filename.concat directory (digest ^ ".jsonl")
;;
let register ?(topology = Refine) store ~keeper ~run_id ~preset ~started_at =
  let request : Fusion_types.fusion_request =
    { run_id; keeper; prompt = (successful_evidence ()).question; preset
    ; web_tools = true; depth = Fusion_depth.Top; trigger = Operator_requested }
  in
  A.register store ~topology ~request ~started_at
;;
let test_exact_lifecycle_and_validation () =
  let base_path = fresh_base () in
  let store = A.create ~directory:(Filename.concat base_path "runs") in
  (match register store ~keeper:"" ~run_id:"r" ~preset:"p" ~started_at:1. with
   | Error A.Empty_keeper -> ()
   | _ -> fail "empty keeper identity was accepted");
  (match register store ~keeper:"k" ~run_id:"" ~preset:"p" ~started_at:1. with
   | Error A.Empty_run_id -> ()
   | _ -> fail "empty run identity was accepted");
  (match register store ~keeper:"k" ~run_id:"r" ~preset:"p" ~started_at:Float.nan with
   | Error (A.Invalid_started_at _) -> ()
   | _ -> fail "non-finite start time was accepted");
  (match register store ~keeper:"k" ~run_id:"r" ~preset:"p" ~started_at:1. with
   | Ok A.Registered -> ()
   | _ -> fail "first registration must be durable");
  let restarted = A.create ~directory:(Filename.concat base_path "runs") in
  (match register ~topology:Simple restarted ~keeper:"k" ~run_id:"r" ~preset:"p" ~started_at:2. with
   | Error (A.Registration_conflict _) -> ()
   | _ -> fail "changed replay envelope did not conflict");
  let winner = deliberated (successful_evidence ()) in
  (match A.commit_phase store ~keeper:"k" ~run_id:"r" winner with
   | Ok A.First_committed -> ()
   | _ -> fail "first terminal must commit");
  (match register store ~keeper:"k" ~run_id:"r" ~preset:"p" ~started_at:3. with
   | Ok (A.Already_registered (A.Computation_committed_run (_, evidence))) ->
     check bool
       "settled retry returns winner"
       true
       (A.equal_phase winner (A.Computation_committed evidence))
   | _ -> fail "settled registration retry could start another run");
  (match A.commit_phase restarted ~keeper:"k" ~run_id:"r" winner with
   | Ok A.Already_same -> ()
   | _ -> fail "restart must retain the winner");
  (match A.commit_phase store ~keeper:"k" ~run_id:"r" (deliberated (failed_evidence ())) with
   | Error (A.Evidence_question_mismatch _) -> () | _ -> fail "foreign question was accepted");
  (match
     A.commit_phase store ~keeper:"k" ~run_id:"r"
       (deliberated { (failed_evidence ()) with question = (successful_evidence ()).question })
   with
   | Ok (A.Conflict terminal) ->
     check bool "conflict returns exact winner" true (A.equal_phase winner terminal)
   | _ -> fail "different terminal must conflict");
  (match A.commit_phase store ~keeper:"k" ~run_id:"other"
           (A.Stopped_without_computation (A.Cancelled "")) with
   | Error A.Empty_cancellation_detail -> ()
   | _ -> fail "empty cancellation detail was accepted");
  (match A.commit_phase store ~keeper:"k" ~run_id:"other"
           (A.Stopped_without_computation (A.Aborted "")) with
   | Error A.Empty_abort_detail -> ()
   | _ -> fail "empty abort detail was accepted");
  (match
     register store ~keeper:"k" ~run_id:"typed-failure" ~preset:"p" ~started_at:2.
   with
   | Ok A.Registered -> ()
   | _ -> fail "typed-failure registration failed");
  let typed_failure =
    deliberated { (failed_evidence ()) with question = (successful_evidence ()).question }
  in
  (match A.commit_phase store ~keeper:"k" ~run_id:"typed-failure" typed_failure with
   | Ok A.First_committed -> ()
   | _ -> fail "typed failure terminal did not commit");
  (match
     register restarted ~keeper:"k" ~run_id:"typed-failure" ~preset:"p" ~started_at:4.
   with
   | Ok (A.Already_registered (A.Computation_committed_run (_, evidence))) ->
     check bool
       "typed failure survives restart"
       true
       (A.equal_phase typed_failure (A.Computation_committed evidence))
   | _ -> fail "typed failure terminal was not reloaded exactly");
  match A.commit_phase store ~keeper:"k" ~run_id:"missing"
          (A.Stopped_without_computation (A.Cancelled "shutdown")) with
  | Error (A.Invalid_transition { state = A.Empty_state; _ }) -> ()
  | _ -> fail "terminal without durable registration must be rejected"
;;
let test_corruption_is_per_run_and_semantic () =
  let base_path = fresh_base () in
  let directory = Filename.concat base_path "runs" in
  let store = A.create ~directory in
  let register run_id =
    match register store ~keeper:"k" ~run_id ~preset:"p" ~started_at:1. with
    | Ok A.Registered -> ()
    | _ -> fail (run_id ^ " registration failed")
  in
  register "bad";
  let bad_path = run_file directory "k" "bad" in
  let registered = Fs_compat.load_file bad_path in
  Fs_compat.save_file bad_path (String.sub registered 0 (String.length registered - 1));
  (match A.commit_phase store ~keeper:"k" ~run_id:"bad" (deliberated (successful_evidence ())) with
   | Error A.Partial_tail -> ()
   | _ -> fail "partial tail must fail explicitly");
  register "peer";
  (match
     A.commit_phase store ~keeper:"k" ~run_id:"peer"
       (deliberated (successful_evidence ()))
   with
   | Ok A.First_committed -> ()
   | _ -> fail "corrupt peer must not block an unrelated run");
  let versioned =
    match Yojson.Safe.from_string registered with
    | `Assoc fields -> `Assoc (("schema_version", `Int 1) :: List.remove_assoc "schema_version" fields)
    | _ -> fail "registered record was not an object"
  in
  Fs_compat.save_file bad_path (Yojson.Safe.to_string versioned ^ "\n");
  (match
     A.commit_phase store ~keeper:"k" ~run_id:"bad"
       (deliberated (successful_evidence ()))
   with
   | Error (A.Unsupported_schema_version { found = 1; _ }) -> ()
   | _ -> fail "unsupported schema version must fail explicitly");
  register "order";
  (match
     A.commit_phase store ~keeper:"k" ~run_id:"order"
       (deliberated (successful_evidence ()))
   with
   | Ok A.First_committed -> ()
   | _ -> fail "ordered terminal did not commit");
  let order_path = run_file directory "k" "order" in
  (match String.split_on_char '\n' (Fs_compat.load_file order_path) with
   | [ registration; terminal; "" ] ->
     Fs_compat.save_file order_path (terminal ^ "\n");
     (match
        A.commit_phase store ~keeper:"k" ~run_id:"order"
          (deliberated (successful_evidence ()))
      with
      | Error (A.Invalid_transition { state = A.Empty_state; _ }) -> ()
      | _ -> fail "orphan terminal must fail explicitly");
     Fs_compat.save_file order_path (terminal ^ "\n" ^ registration ^ "\n");
     (match
        A.commit_phase store ~keeper:"k" ~run_id:"order"
          (deliberated (successful_evidence ()))
      with
      | Error (A.Invalid_transition { state = A.Empty_state; _ }) -> ()
      | _ -> fail "reversed records must fail explicitly")
   | _ -> fail "expected exact register/terminal JSONL pair");
  let foreign_path = run_file directory "k" "foreign" in
  Fs_compat.save_file foreign_path
    (Fs_compat.load_file (run_file directory "k" "peer"));
  match
    A.commit_phase store ~keeper:"k" ~run_id:"foreign"
      (deliberated (successful_evidence ()))
  with
  | Error (A.Identity_mismatch _) -> ()
  | _ -> fail "hashed path must still verify persisted identity"
;;
let identity_of_recovered = function
  | A.Registered_run registration
  | A.Computation_committed_run (registration, _)
  | A.Stopped_without_computation_run (registration, _) ->
    { A.keeper = registration.replay.request.keeper
    ; run_id = registration.replay.request.run_id }
;;

let test_restart_scan_preserves_valid_peers_and_corruption () =
  let base_path = fresh_base () in
  let directory = Filename.concat base_path "runs" in
  let store = A.create ~directory in
  let register run_id started_at =
    match register store ~keeper:"keeper-a" ~run_id ~preset:"p" ~started_at with
    | Ok A.Registered -> ()
    | _ -> fail (run_id ^ " registration failed")
  in
  register "running" 1.;
  register "settled" 2.;
  register "corrupt" 3.;
  (match A.commit_phase store ~keeper:"keeper-a" ~run_id:"corrupt"
           (A.Stopped_without_computation (A.Denied Fusion_types.Disabled)) with
   | Ok A.First_committed -> ()
   | _ -> fail "typed uncommitted stop did not commit");
  let winner = deliberated (successful_evidence ()) in
  (match
     A.commit_phase store ~keeper:"keeper-a" ~run_id:"settled"
       winner
   with
   | Ok A.First_committed -> ()
   | _ -> fail "settled terminal did not commit");
  let corrupt_path = run_file directory "keeper-a" "corrupt" in
  let registered = Fs_compat.load_file corrupt_path in
  Fs_compat.save_file corrupt_path
    (String.sub registered 0 (String.length registered - 1));
  let entries =
    match A.scan (A.create ~directory) with
    | Ok (A.Store_scanned entries) -> entries
    | Ok A.Store_missing -> fail "existing authority store was reported missing"
    | Error _ -> fail "authority directory scan failed"
  in
  check int "all observed entries retained" 3 (List.length entries);
  let valid_runs, corruptions =
    List.fold_left
      (fun (valid, corrupt) (entry : A.scan_entry) ->
         match entry.outcome with
         | Ok recovered -> recovered :: valid, corrupt
         | Error (A.Entry_record_failed A.Partial_tail) -> valid, entry.entry_name :: corrupt
         | Error _ -> fail "scan returned an unexpected per-entry failure")
      ([], [])
      entries
  in
  let valid_run_ids =
    valid_runs
    |> List.map (fun recovered -> (identity_of_recovered recovered).run_id)
    |> List.sort String.compare
  in
  check (list string) "valid peers survive corrupt entry" [ "running"; "settled" ] valid_run_ids;
  check int "corruption remains explicit" 1 (List.length corruptions);
  check bool "settled terminal survives scan" true
    (List.exists
       (function
         | A.Computation_committed_run (registration, evidence) ->
           String.equal registration.replay.request.run_id "settled"
           && A.equal_phase winner (A.Computation_committed evidence)
         | A.Registered_run _ | A.Stopped_without_computation_run _ -> false)
       valid_runs)
;;
let () =
  run "fusion_run_authority"
    [ ( "authority"
      , [ test_case "exact lifecycle and validation" `Quick
            test_exact_lifecycle_and_validation
        ; test_case "per-run corruption and semantic validation" `Quick
            test_corruption_is_per_run_and_semantic
        ; test_case "restart scan preserves valid peers and corruption" `Quick
            test_restart_scan_preserves_valid_peers_and_corruption
        ] )
    ]
;;
