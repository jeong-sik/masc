module K = Masc.Keeper_runtime_trust_snapshot
module O = Masc.Keeper_status_detail_observability
module P = Masc.Otel_metric_store

let rec remove_tree path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let rec mkdir_p dir =
  if dir = "" || dir = "." || dir = "/"
  then ()
  else if Sys.file_exists dir
  then ()
  else (
    mkdir_p (Filename.dirname dir);
    Unix.mkdir dir 0o755)
;;

let temp_dir () =
  let dir = Filename.temp_file "runtime_trust_decision_drop_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir
;;

let write_file path content =
  mkdir_p (Filename.dirname path);
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> output_string oc content)
;;

let with_env name value f =
  let old = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () ->
      match old with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f
;;

let make_meta name : Masc.Keeper_meta_contract.keeper_meta =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
          [ "name", `String name
          ; "trace_id", `String ("trace-" ^ name)
          ; "goal", `String "test goal"
          ])
  with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("meta fixture failed: " ^ err)
;;

let drop_value reason =
  P.metric_value_or_zero
    P.metric_persistence_read_drops
    ~labels:[ "surface", "keeper_runtime_trust_decision_log"; "reason", reason ]
    ()
;;

let test_snapshot_counts_malformed_decision_rows () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> remove_tree base_dir)
    (fun () ->
       with_env "MASC_BASE_PATH" base_dir
       @@ fun () ->
       let config = Masc.Workspace.default_config base_dir in
       let keeper_name = "runtime-trust-decision-drop" in
       let meta = make_meta keeper_name in
       let path = Masc.Keeper_types_support.keeper_decision_log_path config keeper_name in
       let entry_error = Safe_ops.persistence_read_drop_reason_entry_load_error in
       let invalid_payload = Safe_ops.persistence_read_drop_reason_invalid_payload in
       let before_entry_error = drop_value entry_error in
       let before_invalid_payload = drop_value invalid_payload in
       write_file
         path
         (String.concat
            "\n"
            [ Yojson.Safe.to_string
                (`Assoc
                    [ "turn_id", `Int 11
                    ; "turn_verdict", `String "run"
                    ; "telemetry", `Assoc [ "selected_model", `String "test-model" ]
                    ])
            ; Yojson.Safe.to_string (`List [])
            ; "{not-json"
            ]
          ^ "\n");
       let snapshot = K.snapshot_json ~config ~meta in
       let open Yojson.Safe.Util in
       Alcotest.(check int)
         "falls back to older valid decision"
         11
         (snapshot |> member "latest_decision" |> member "turn_id" |> to_int);
       Alcotest.(check string)
         "selected model survives fallback"
         "test-model"
         (snapshot |> member "selected_model" |> to_string);
       Alcotest.(check (float 0.001))
         "malformed json increments entry error"
         1.0
       (drop_value entry_error -. before_entry_error);
       Alcotest.(check (float 0.001))
         "non-object row increments invalid payload"
         1.0
         (drop_value invalid_payload -. before_invalid_payload))
;;

let test_snapshot_uses_receipt_runtime_model_when_decision_absent () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> remove_tree base_dir)
    (fun () ->
       with_env "MASC_BASE_PATH" base_dir
       @@ fun () ->
       let config = Masc.Workspace.default_config base_dir in
       let keeper_name = "runtime-trust-receipt-model" in
       let meta = make_meta keeper_name in
       let receipt_store =
         Masc.Keeper_types_support.keeper_execution_receipt_store config keeper_name
       in
       Dated_jsonl.append
         receipt_store
         (`Assoc
             [ "turn_count", `Int 7
             ; "ended_at", `String "2026-06-01T00:00:00Z"
             ; ( "runtime"
               , `Assoc
                   [ "name", `String "runtime-test"
                   ; "selected_model", `String "receipt-model"
                   ; "attempt_count", `Int 1
                   ; "fallback_applied", `Bool false
                   ; "outcome", `String "completed"
                   ] )
             ]);
       let snapshot = K.snapshot_json ~config ~meta in
       let open Yojson.Safe.Util in
       Alcotest.(check string)
         "selected model falls back to receipt"
         "receipt-model"
         (snapshot |> member "selected_model" |> to_string);
       Alcotest.(check string)
         "active model falls back to receipt"
         "receipt-model"
         (snapshot |> member "active_model" |> to_string);
       Alcotest.(check string)
         "execution provider selected model follows receipt"
         "receipt-model"
         (snapshot |> member "execution" |> member "provider_selected_model" |> to_string))
;;

let test_budget_not_dispatched_receipt_marks_attention () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> remove_tree base_dir)
    (fun () ->
       with_env "MASC_BASE_PATH" base_dir
       @@ fun () ->
       let config = Masc.Workspace.default_config base_dir in
       let keeper_name = "runtime-trust-budget-not-dispatched" in
       let meta = make_meta keeper_name in
       let receipt_store =
         Masc.Keeper_types_support.keeper_execution_receipt_store config keeper_name
       in
       Dated_jsonl.append
         receipt_store
         (`Assoc
             [ "ended_at", `String "2026-06-01T00:00:00Z"
             ; "operator_disposition", `String "pass"
             ; "operator_disposition_reason", `String "healthy"
             ; "terminal_reason_code", `String "turn_budget_exhausted:8/8"
             ; "completion_contract_result", `String "not_dispatched"
             ]);
       let snapshot = K.snapshot_json ~config ~meta in
       let open Yojson.Safe.Util in
       Alcotest.(check string)
         "display disposition"
         "Blocked"
         (snapshot |> member "disposition" |> to_string);
       Alcotest.(check string)
         "display reason"
         "not_dispatched"
         (snapshot |> member "disposition_reason" |> to_string);
       Alcotest.(check bool)
         "needs attention"
         true
         (snapshot |> member "needs_attention" |> to_bool);
       Alcotest.(check string)
         "operator disposition remains receipt truth"
         "pass"
         (snapshot |> member "operator_disposition" |> to_string);
       Alcotest.(check string)
         "operator disposition reason remains receipt truth"
         "healthy"
         (snapshot |> member "operator_disposition_reason" |> to_string))
;;

let test_model_observability_uses_runtime_trust_selected_model () =
  let runtime_trust =
    `Assoc
      [ "selected_model", `String "receipt-model"
      ; ( "execution"
        , `Assoc [ "provider_selected_model", `String "execution-model" ] )
      ]
  in
  let json =
    O.model_observability_json
      ~current_runtime_id:"runtime-test"
      ~runtime_blocker_fields:[]
      ~runtime_trust
      None
  in
  let open Yojson.Safe.Util in
  Alcotest.(check bool)
    "runtime-trust model counts as recent observation"
    true
    (json |> member "recent_turn_observation" |> to_bool);
  Alcotest.(check string)
    "selected model falls through to model_observability"
    "receipt-model"
    (json |> member "selected_model" |> to_string);
  Alcotest.(check bool)
    "runtime contract marks selected model proof verified"
    true
    (json |> member "runtime_contract" |> member "verified" |> to_bool);
  Alcotest.(check string)
    "runtime contract source records trust field"
    "runtime_trust.selected_model"
    (json |> member "runtime_contract" |> member "source" |> to_string);
  Alcotest.(check string)
    "runtime contract exposes observed selected model"
    "receipt-model"
    (json |> member "runtime_contract" |> member "actual_model_id" |> to_string)
;;

let test_model_observability_uses_runtime_trust_execution_selected_model () =
  let runtime_trust =
    `Assoc
      [ ( "execution"
        , `Assoc [ "provider_selected_model", `String "execution-model" ] )
      ]
  in
  let json =
    O.model_observability_json
      ~current_runtime_id:"runtime-test"
      ~runtime_blocker_fields:[]
      ~runtime_trust
      None
  in
  let open Yojson.Safe.Util in
  Alcotest.(check bool)
    "runtime-trust execution model counts as recent observation"
    true
    (json |> member "recent_turn_observation" |> to_bool);
  Alcotest.(check string)
    "execution selected model falls through to model_observability"
    "execution-model"
    (json |> member "selected_model" |> to_string);
  Alcotest.(check bool)
    "runtime contract marks execution selected model proof verified"
    true
    (json |> member "runtime_contract" |> member "verified" |> to_bool);
  Alcotest.(check string)
    "runtime contract source records execution trust field"
    "runtime_trust.execution.provider_selected_model"
    (json |> member "runtime_contract" |> member "source" |> to_string);
  Alcotest.(check string)
    "runtime contract exposes observed execution selected model"
    "execution-model"
    (json |> member "runtime_contract" |> member "actual_model_id" |> to_string)
;;

let () =
  Alcotest.run
    "keeper_runtime_trust_snapshot"
    [ ( "decision_log_read_drops"
      , [ Alcotest.test_case
            "malformed decision rows increment drop metrics"
            `Quick
            test_snapshot_counts_malformed_decision_rows
        ] )
    ; ( "receipt_runtime_model"
      , [ Alcotest.test_case
            "receipt runtime model feeds trust snapshot when decision is absent"
            `Quick
            test_snapshot_uses_receipt_runtime_model_when_decision_absent
        ; Alcotest.test_case
            "status model observability reuses runtime-trust selected model"
            `Quick
            test_model_observability_uses_runtime_trust_selected_model
        ; Alcotest.test_case
            "budget not-dispatched receipt marks runtime-trust attention"
            `Quick
            test_budget_not_dispatched_receipt_marks_attention
        ; Alcotest.test_case
            "status model observability reuses runtime-trust execution selected model"
            `Quick
            test_model_observability_uses_runtime_trust_execution_selected_model
        ] )
    ]
;;
