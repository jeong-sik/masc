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

let runtime_toml =
  {|
version = 1

[runtime]
default = "test_provider.test_model"

[providers.test_provider]
display-name = "Test Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[models.test_model]
api-name = "test-model"
max-context = 8192
tools-support = true
streaming = true

[test_provider.test_model]
max-concurrent = 1
|}
;;

let init_runtime_default_for_tests () =
  let path = Filename.temp_file "runtime_trust_snapshot_runtime_" ".toml" in
  write_file path runtime_toml;
  match Runtime.init_default ~config_path:path with
  | Ok () -> ()
  | Error e -> Alcotest.failf "Runtime.init_default failed: %s" e
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
          ])
  with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("meta fixture failed: " ^ err)
;;

let test_active_model_missing_attempt_is_unknown () =
  let meta = make_meta "status-runtime-missing-attempt" in
  let unknown_model_label =
    Boundary_redaction.to_string Boundary_redaction.unknown_model_label
  in
  Alcotest.(check string)
    "missing runtime attempt is explicit unknown"
    unknown_model_label
    (Masc.Keeper_status_runtime.active_model_of_meta meta);
  Alcotest.(check string)
    "missing runtime attempt label is explicit unknown"
    unknown_model_label
    (Masc.Keeper_status_runtime.active_model_label_of_meta meta)
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

let test_observation_not_dispatched_receipt_remains_non_blocking () =
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
       let keeper_name = "runtime-trust-observation-not-dispatched" in
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
               (* Typed execution-limit observations project to receipt
                  success. They do not create a Keeper blocker or terminal
                  lifecycle decision. *)
             ; "terminal_reason_code", `String "success"
             ; "completion_contract_result", `String "not_dispatched"
             ]);
       let snapshot = K.snapshot_json ~config ~meta in
       let open Yojson.Safe.Util in
       Alcotest.(check string)
         "display disposition"
         "Pass"
         (snapshot |> member "disposition" |> to_string);
       Alcotest.(check string)
         "display reason"
         "healthy"
         (snapshot |> member "disposition_reason" |> to_string);
       Alcotest.(check bool)
         "needs attention"
         false
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

let test_unknown_completion_contract_result_stays_visible () =
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
       let keeper_name = "runtime-trust-unknown-contract" in
       let meta = make_meta keeper_name in
       let receipt_store =
         Masc.Keeper_types_support.keeper_execution_receipt_store config keeper_name
       in
       Dated_jsonl.append
         receipt_store
         (`Assoc
             [ "ended_at", `String "2026-06-01T00:00:00Z"
             ; "completion_contract_result", `String "future_state"
             ]);
       let snapshot = K.snapshot_json ~config ~meta in
       let open Yojson.Safe.Util in
       Alcotest.(check string)
         "raw completion contract result remains on execution summary"
         "future_state"
         (snapshot |> member "execution" |> member "completion_contract_result"
          |> to_string);
       Alcotest.(check string)
         "unknown result is visible instead of collapsed to not observed"
         "unknown_completion_contract_result:future_state"
         (snapshot |> member "execution" |> member "completion_observation_summary"
         |> to_string))
;;

let test_completion_observation_rejects_drifted_label_before_parser () =
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
       let keeper_name = "runtime-trust-typed-contract-label" in
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
             ; "terminal_reason_code", `String "success"
             ; "completion_contract_result", `String " Future_State "
             ]);
       let snapshot = K.snapshot_json ~config ~meta in
       let open Yojson.Safe.Util in
       Alcotest.(check string)
         "raw drifted result remains visible"
         " Future_State "
         (snapshot |> member "execution" |> member "completion_contract_result"
          |> to_string);
       Alcotest.(check string)
         "does not normalize drifted label before the exact parser"
         "unknown_completion_contract_result: Future_State "
         (snapshot
          |> member "execution"
          |> member "completion_observation_summary"
          |> to_string))
;;

let test_unknown_completion_observation_label_is_explicit () =
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
       let keeper_name = "runtime-trust-legacy-satisfied-contract-label" in
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
             ; "terminal_reason_code", `String "success"
             ; "completion_contract_result", `String "future_state_v2"
             ]);
       let snapshot = K.snapshot_json ~config ~meta in
       let open Yojson.Safe.Util in
       Alcotest.(check string)
         "unknown observation label stays explicit"
         "unknown_completion_contract_result:future_state_v2"
         (snapshot
          |> member "execution"
          |> member "completion_observation_summary"
          |> to_string))
;;

let test_no_visible_output_no_work_receipt_does_not_mark_attention () =
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
       init_runtime_default_for_tests ();
       let keeper_name = "runtime-trust-no-visible-output-no-work" in
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
             ; "terminal_reason_code", `String "success"
             ; "completion_contract_result", `String "no_visible_output"
             ; "current_task_id", `Null
             ; "goal_ids", `List []
             ]);
       let snapshot = K.snapshot_json ~config ~meta in
       let open Yojson.Safe.Util in
       Alcotest.(check string)
         "display disposition"
         "Pass"
         (snapshot |> member "disposition" |> to_string);
       Alcotest.(check string)
         "display reason"
         "healthy"
         (snapshot |> member "disposition_reason" |> to_string);
       Alcotest.(check bool)
         "needs attention"
         false
         (snapshot |> member "needs_attention" |> to_bool);
       Alcotest.(check bool)
         "attention reason omitted"
         true
         (match snapshot |> member "attention_reason" with
          | `Null -> true
          | _ -> false))
;;

let test_no_visible_output_active_receipt_does_not_mark_attention () =
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
       init_runtime_default_for_tests ();
       let keeper_name = "runtime-trust-no-visible-output-active-task" in
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
             ; "terminal_reason_code", `String "success"
             ; "completion_contract_result", `String "no_visible_output"
             ; "current_task_id", `String "task-1844"
             ; "goal_ids", `List [ `String "goal-pm-flow" ]
             ]);
       let snapshot = K.snapshot_json ~config ~meta in
       let open Yojson.Safe.Util in
       Alcotest.(check string)
         "display disposition"
         "Pass"
         (snapshot |> member "disposition" |> to_string);
       Alcotest.(check string)
         "display reason"
         "healthy"
         (snapshot |> member "disposition_reason" |> to_string);
       Alcotest.(check bool)
         "needs attention"
         false
         (snapshot |> member "needs_attention" |> to_bool);
       Alcotest.(check bool)
         "attention reason omitted"
         true
         (match snapshot |> member "attention_reason" with
          | `Null -> true
          | _ -> false))
;;

let test_runtime_blocker_supersedes_completion_observation () =
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
       init_runtime_default_for_tests ();
       let keeper_name = "runtime-trust-provider-exhausted" in
       let blocker_detail = "No configured provider runtime remained available."
       in
       let blocker =
         Masc.Keeper_meta_contract.blocker_info_of_class
           ~detail:blocker_detail
           (Masc.Keeper_meta_contract.Runtime_exhausted
              Masc.Keeper_meta_contract.No_providers_available)
       in
       let meta =
         make_meta keeper_name
         |> Masc.Keeper_meta_contract.map_runtime (fun rt ->
           { rt with
             last_blocker = Some blocker
           ; usage = { rt.usage with last_turn_ts = Time_compat.now () }
           })
       in
       let receipt_store =
         Masc.Keeper_types_support.keeper_execution_receipt_store config keeper_name
       in
       Dated_jsonl.append
         receipt_store
         (`Assoc
             [ "ended_at", `String "2026-06-01T00:00:00Z"
             ; "operator_disposition", `String "pass"
             ; "operator_disposition_reason", `String "healthy"
             ; "terminal_reason_code", `String "success"
             ; "completion_contract_result", `String "no_visible_output"
             ]);
       let snapshot = K.snapshot_json ~config ~meta in
       let open Yojson.Safe.Util in
       Alcotest.(check string)
         "runtime blocker class"
         "runtime_exhausted"
         (snapshot
          |> member "runtime_blockers"
          |> member "runtime_blocker_class"
          |> to_string);
       Alcotest.(check string)
         "runtime blocker remains the display reason"
         "runtime_exhausted"
         (snapshot |> member "disposition_reason" |> to_string);
       Alcotest.(check string)
         "attention follows runtime blocker"
         "runtime_attempts_exhausted"
         (snapshot |> member "attention_reason" |> to_string);
       Alcotest.(check bool)
         "runtime blocker summary remains typed runtime evidence"
         true
         (String.equal
            blocker_detail
               (snapshot
                |> member "runtime_blockers"
                |> member "runtime_blocker_summary"
                |> to_string)))
;;

let test_runtime_exhausted_blocker_uses_typed_parser () =
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
       let keeper_name = "runtime-trust-runtime-exhausted" in
       let blocker =
         Masc.Keeper_meta_contract.blocker_info_of_class
           (Masc.Keeper_meta_contract.Runtime_exhausted
              (Masc.Keeper_meta_contract.Other_detail "runtime_exhausted"))
       in
       let meta =
         make_meta keeper_name
         |> Masc.Keeper_meta_contract.map_runtime (fun rt ->
           { rt with last_blocker = Some blocker })
       in
       let snapshot = K.snapshot_json ~config ~meta in
       let open Yojson.Safe.Util in
       Alcotest.(check string)
         "runtime exhausted blocker display reason"
         "runtime_exhausted"
         (snapshot |> member "disposition_reason" |> to_string);
       Alcotest.(check string)
         "runtime exhausted blocker class"
         "runtime_exhausted"
         (snapshot
          |> member "runtime_blockers"
          |> member "runtime_blocker_class"
          |> to_string))
;;

let test_unknown_completion_observation_is_explicit () =
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
       let keeper_name = "runtime-trust-unknown-contract-label" in
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
             ; "terminal_reason_code", `String "success"
             ; "completion_contract_result", `String "future-state"
             ]);
       let snapshot = K.snapshot_json ~config ~meta in
       let open Yojson.Safe.Util in
       Alcotest.(check string)
         "raw result remains visible"
         "future-state"
         (snapshot |> member "execution" |> member "completion_contract_result" |> to_string);
       Alcotest.(check string)
         "unknown result uses explicit sentinel"
         "unknown_completion_contract_result:future-state"
         (snapshot
          |> member "execution"
          |> member "completion_observation_summary"
          |> to_string))
;;

let test_operator_disposition_display_uses_typed_parser () =
  let check_case ~operator_disposition ~operator_disposition_reason
      ~expected_disposition ~expected_reason =
    let disposition, reason =
      Masc.Keeper_operator_disposition_display.of_wire ~operator_disposition
        ~operator_disposition_reason
    in
    Alcotest.(check string)
      (operator_disposition ^ " disposition")
      expected_disposition disposition;
    Alcotest.(check string)
      (operator_disposition ^ " reason")
      expected_reason reason
  in
  check_case ~operator_disposition:"pass_next_model" ~operator_disposition_reason:""
    ~expected_disposition:"Pass" ~expected_reason:"runtime_fallback";
  check_case ~operator_disposition:"fail_open_next_runtime"
    ~operator_disposition_reason:"manual_review" ~expected_disposition:"Pass"
    ~expected_reason:"manual_review";
  check_case ~operator_disposition:"blocked_runtime" ~operator_disposition_reason:""
    ~expected_disposition:"Alert" ~expected_reason:"unmapped_operator_disposition";
  check_case ~operator_disposition:"<missing operator_disposition field>"
    ~operator_disposition_reason:"" ~expected_disposition:"Alert"
    ~expected_reason:"unmapped_operator_disposition"
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
    "runtime-trust model alone is not a scoped runtime observation"
    false
    (json |> member "recent_turn_observation" |> to_bool);
  Alcotest.(check string)
    "selected model falls through to model_observability"
    "receipt-model"
    (json |> member "selected_model" |> to_string);
  Alcotest.(check bool)
    "runtime contract does not verify weak selected-model hint"
    false
    (json |> member "runtime_contract" |> member "verified" |> to_bool);
  Alcotest.(check string)
    "runtime contract source records trust field"
    "runtime_trust.selected_model"
    (json |> member "runtime_contract" |> member "source" |> to_string);
  Alcotest.(check bool)
    "runtime contract does not expose selected model as actual model"
    true
    (json |> member "runtime_contract" |> member "actual_model_id" = `Null)
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
    "runtime-trust execution model alone is not a scoped runtime observation"
    false
    (json |> member "recent_turn_observation" |> to_bool);
  Alcotest.(check string)
    "execution selected model falls through to model_observability"
    "execution-model"
    (json |> member "selected_model" |> to_string);
  Alcotest.(check bool)
    "runtime contract does not verify weak execution selected-model hint"
    false
    (json |> member "runtime_contract" |> member "verified" |> to_bool);
  Alcotest.(check string)
    "runtime contract source records execution trust field"
    "runtime_trust.execution.provider_selected_model"
    (json |> member "runtime_contract" |> member "source" |> to_string);
  Alcotest.(check bool)
    "runtime contract does not expose execution hint as actual model"
    true
    (json |> member "runtime_contract" |> member "actual_model_id" = `Null)
;;

let test_model_observability_missing_runtime_id_is_unscoped () =
  let latest_metrics =
    Some
      (`Assoc
        [ ( "runtime"
          , `Assoc
              [ "attempts", `List [ `Assoc [ "status", `String "ok" ] ]
              ; "selected_index", `Int 0
              ] )
        ])
  in
  let json =
    O.model_observability_json
      ~current_runtime_id:"runtime-test"
      ~runtime_blocker_fields:[]
      ~runtime_trust:(`Assoc [])
      latest_metrics
  in
  let open Yojson.Safe.Util in
  Alcotest.(check bool)
    "missing runtime_id is not current-runtime observation"
    false
    (json |> member "recent_turn_observation" |> to_bool);
  Alcotest.(check string)
    "runtime observation scope is explicit"
    "missing_runtime_id"
    (json |> member "runtime_observation_scope" |> to_string);
  Alcotest.(check bool)
    "missing runtime_id does not verify runtime contract"
    false
    (json |> member "runtime_contract" |> member "verified" |> to_bool)
;;

let test_model_observability_runtime_match_does_not_promote_model_hint () =
  let latest_metrics =
    Some
      (`Assoc
        [ ( "runtime"
          , `Assoc
              [ "runtime_id", `String "runtime-test"
              ; "attempts", `List [ `Assoc [ "status", `String "ok" ] ]
              ; "selected_index", `Int 0
              ] )
        ])
  in
  let runtime_trust = `Assoc [ "selected_model", `String "receipt-model" ] in
  let json =
    O.model_observability_json
      ~current_runtime_id:"runtime-test"
      ~runtime_blocker_fields:[]
      ~runtime_trust
      latest_metrics
  in
  let open Yojson.Safe.Util in
  Alcotest.(check bool)
    "matched runtime row is a scoped runtime observation"
    true
    (json |> member "recent_turn_observation" |> to_bool);
  Alcotest.(check string)
    "runtime observation scope is matched"
    "matched"
    (json |> member "runtime_observation_scope" |> to_string);
  Alcotest.(check bool)
    "runtime contract scope is verified"
    true
    (json |> member "runtime_contract" |> member "verified" |> to_bool);
  Alcotest.(check bool)
    "weak selected-model hint is not promoted to actual model"
    true
    (json |> member "runtime_contract" |> member "actual_model_id" = `Null)
;;

let () =
  Alcotest.run
    "keeper_runtime_trust_snapshot"
    [ ( "status_runtime_provenance"
      , [ Alcotest.test_case
            "missing runtime attempt does not fabricate active_model"
            `Quick
            test_active_model_missing_attempt_is_unknown
        ] )
    ; ( "decision_log_read_drops"
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
            "not-dispatched observation remains non-blocking"
            `Quick
            test_observation_not_dispatched_receipt_remains_non_blocking
        ; Alcotest.test_case
            "unknown completion-contract result remains visible"
            `Quick
            test_unknown_completion_contract_result_stays_visible
        ; Alcotest.test_case
            "no-visible-output no-work receipt does not mark attention"
            `Quick
            test_no_visible_output_no_work_receipt_does_not_mark_attention
        ; Alcotest.test_case
            "no-visible-output active receipt does not mark attention"
            `Quick
            test_no_visible_output_active_receipt_does_not_mark_attention
        ; Alcotest.test_case
            "runtime blocker supersedes completion observation"
            `Quick
            test_runtime_blocker_supersedes_completion_observation
        ; Alcotest.test_case
            "runtime exhausted blocker display uses typed parser"
            `Quick
            test_runtime_exhausted_blocker_uses_typed_parser
        ; Alcotest.test_case
            "completion-observation labels reject drift before typed parser"
            `Quick
            test_completion_observation_rejects_drifted_label_before_parser
        ; Alcotest.test_case
            "unknown completion-observation label is explicit"
            `Quick
            test_unknown_completion_observation_label_is_explicit
        ; Alcotest.test_case
            "unknown completion-contract label uses explicit sentinel"
            `Quick
            test_unknown_completion_observation_is_explicit
        ; Alcotest.test_case
            "operator disposition display uses typed parser"
            `Quick
            test_operator_disposition_display_uses_typed_parser
        ; Alcotest.test_case
            "status model observability reuses runtime-trust execution selected model"
            `Quick
            test_model_observability_uses_runtime_trust_execution_selected_model
        ; Alcotest.test_case
            "status model observability treats missing runtime_id as unscoped"
            `Quick
            test_model_observability_missing_runtime_id_is_unscoped
        ; Alcotest.test_case
            "status model observability keeps matched weak model hint non-actual"
            `Quick
            test_model_observability_runtime_match_does_not_promote_model_hint
        ] )
    ]
;;
