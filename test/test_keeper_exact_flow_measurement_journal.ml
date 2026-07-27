module Exact_output = Agent_sdk.Exact_output
module Journal = Masc.Keeper_exact_flow_evidence_journal

let sha256 value = Digestif.SHA256.(to_hex (digest_string value))

let receipt_fields ~phase ~dispatch ~outcome =
  [ "format", `String "oas.exact-output.measurement-receipt"
  ; "version", `Int 1
  ; "operation_id", `String "measurement-operation-1"
  ; "flow_id", `String "measurement-flow-1"
  ; "visit_ordinal", `Int 1
  ; "candidate_id", `String "measurement-candidate-1"
  ; "candidate_binding_sha256", `String (String.make 64 '1')
  ; "catalog_generation_fingerprint", `String (String.make 64 '2')
  ; "catalog_evidence_sha256", `String (String.make 64 '3')
  ; "request_body_sha256", `String (String.make 64 '4')
  ; "phase", `String phase
  ; "dispatch", `String dispatch
  ; "outcome", outcome
  ]
;;

let decode_receipt ~phase ~dispatch ~outcome =
  let fields = receipt_fields ~phase ~dispatch ~outcome in
  let integrity_sha256 = `Assoc fields |> Yojson.Safe.to_string |> sha256 in
  let encoded =
    `Assoc (fields @ [ "integrity_sha256", `String integrity_sha256 ])
    |> Yojson.Safe.to_string
  in
  match Exact_output.measurement_receipt_snapshot_of_string encoded with
  | Ok receipt -> receipt
  | Error error ->
    Alcotest.failf
      "current measurement receipt fixture did not decode: %s"
      (Exact_output.measurement_receipt_snapshot_decode_error_to_string error)
;;

let dispatch_intent () =
  decode_receipt
    ~phase:"fence_committed"
    ~dispatch:"dispatch_unknown"
    ~outcome:`Null
;;

let terminal () =
  decode_receipt
    ~phase:"terminal"
    ~dispatch:"dispatch_started"
    ~outcome:(`String "succeeded")
;;

let rec remove_tree path =
  if Sys.is_directory path
  then (
    Sys.readdir path
    |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path)
  else Sys.remove path
;;

let with_temp_dir test =
  let path = Filename.temp_file "masc-measurement-journal-" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> remove_tree path) (fun () -> test path)
;;

let read_file path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel (in_channel_length channel))
;;

let tree_snapshot root =
  let rec collect relative path =
    if Sys.is_directory path
    then
      Sys.readdir path
      |> Array.to_list
      |> List.sort String.compare
      |> List.concat_map (fun name ->
        let child_relative =
          if String.equal relative "" then name else Filename.concat relative name
        in
        collect child_relative (Filename.concat path name))
    else [ relative, read_file path ]
  in
  collect "" root
;;

let require_ok label = function
  | Ok _ -> ()
  | Error _ -> Alcotest.failf "%s unexpectedly failed" label
;;

let require_transition_rejected label = function
  | Error (Journal.Measurement_transition_rejected _) -> ()
  | Error _ -> Alcotest.failf "%s returned the wrong typed journal error" label
  | Ok _ -> Alcotest.failf "%s unexpectedly committed" label
;;

let test_dispatch_then_terminal_survives_reopen () =
  with_temp_dir (fun base_path ->
    let dispatch = dispatch_intent () in
    let terminal = terminal () in
    Journal.commit_measurement_dispatch_intent ~base_path dispatch
    |> require_ok "dispatch intent";
    let after_dispatch = tree_snapshot base_path in
    Journal.commit_measurement_terminal ~base_path terminal |> require_ok "terminal";
    let after_terminal = tree_snapshot base_path in
    Alcotest.(check bool)
      "terminal commit observes and advances the durable dispatch boundary"
      true
      (after_dispatch <> after_terminal);
    Journal.commit_measurement_terminal ~base_path terminal
    |> require_ok "terminal replay after reopen";
    Alcotest.(check bool)
      "reopened journal preserves the terminal boundary"
      true
      (after_terminal = tree_snapshot base_path))
;;

let test_identical_replay_appends_nothing () =
  with_temp_dir (fun base_path ->
    let dispatch = dispatch_intent () in
    Journal.commit_measurement_dispatch_intent ~base_path dispatch
    |> require_ok "first dispatch intent";
    let before_replay = tree_snapshot base_path in
    Journal.commit_measurement_dispatch_intent ~base_path dispatch
    |> require_ok "idempotent dispatch replay";
    Alcotest.(check bool)
      "idempotent replay does not append durable bytes"
      true
      (before_replay = tree_snapshot base_path))
;;

let test_terminal_before_intent_is_typed_conflict () =
  let terminal = terminal () in
  (match
     Exact_output.classify_measurement_receipt_transition
       ~previous:None
       ~incoming:terminal
   with
   | Exact_output.Measurement_transition_conflict
       (Exact_output.Measurement_invalid_commit_phase Exact_output.Measurement_terminal) ->
     ()
   | _ -> Alcotest.fail "OAS did not classify terminal-before-intent as a typed conflict");
  with_temp_dir (fun base_path ->
    Journal.commit_measurement_terminal ~base_path terminal
    |> require_transition_rejected "terminal-before-intent")
;;

let test_phase_regression_is_typed_conflict () =
  let dispatch = dispatch_intent () in
  let terminal = terminal () in
  (match
     Exact_output.classify_measurement_receipt_transition
       ~previous:(Some terminal)
       ~incoming:dispatch
   with
   | Exact_output.Measurement_transition_conflict
       (Exact_output.Measurement_phase_regression
          { previous_phase = Exact_output.Measurement_terminal
          ; incoming_phase = Exact_output.Measurement_fence_committed
          }) -> ()
   | _ -> Alcotest.fail "OAS did not classify the phase regression as a typed conflict");
  with_temp_dir (fun base_path ->
    Journal.commit_measurement_dispatch_intent ~base_path dispatch
    |> require_ok "dispatch before terminal";
    Journal.commit_measurement_terminal ~base_path terminal
    |> require_ok "terminal before regression";
    Journal.commit_measurement_dispatch_intent ~base_path dispatch
    |> require_transition_rejected "phase regression")
;;

let () =
  Alcotest.run
    "keeper exact-flow measurement journal"
    [ ( "measurement journal"
      , [ Alcotest.test_case
            "dispatch then terminal survives reopen"
            `Quick
            test_dispatch_then_terminal_survives_reopen
        ; Alcotest.test_case
            "identical replay appends nothing"
            `Quick
            test_identical_replay_appends_nothing
        ; Alcotest.test_case
            "terminal before intent is typed conflict"
            `Quick
            test_terminal_before_intent_is_typed_conflict
        ; Alcotest.test_case
            "phase regression is typed conflict"
            `Quick
            test_phase_regression_is_typed_conflict
        ] )
    ]
;;
