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
               (* Detail-less wire form: the producer
                  ([Keeper_execution_receipt_types.stop_reason_to_string] via
                  [Keeper_turn_disposition.to_wire]) emits no [detail] for
                  [Runtime_agent.TurnBudgetExhausted {turns_used; limit}].
                  #22618 fabricated a full-detail form no producer emits. *)
             ; "terminal_reason_code", `String "turn_budget_exhausted(8/8)"
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
         "completion_contract_result:not_dispatched"
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
         (snapshot |> member "execution" |> member "mutation_guard_summary"
         |> to_string))
;;

let test_completion_contract_result_rejects_drifted_label_before_parser () =
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
             ; "terminal_reason_code", `String "completed"
             ; "completion_contract_result", `String " Passive_Only "
             ]);
       let snapshot = K.snapshot_json ~config ~meta in
       let open Yojson.Safe.Util in
       Alcotest.(check string)
         "raw drifted result remains visible"
         " Passive_Only "
         (snapshot |> member "execution" |> member "completion_contract_result"
          |> to_string);
       Alcotest.(check string)
         "does not normalize drifted label before the exact parser"
         "unknown_completion_contract_result: Passive_Only "
         (snapshot |> member "execution" |> member "mutation_guard_summary" |> to_string))
;;

let test_legacy_satisfied_completion_contract_result_is_unknown () =
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
             ; "terminal_reason_code", `String "completed"
             ; "completion_contract_result", `String "satisfied"
             ]);
       let snapshot = K.snapshot_json ~config ~meta in
       let open Yojson.Safe.Util in
       Alcotest.(check string)
         "legacy non-canonical label stays unknown"
         "unknown_completion_contract_result:satisfied"
         (snapshot |> member "execution" |> member "mutation_guard_summary" |> to_string))
;;

let test_passive_only_no_work_receipt_does_not_mark_attention () =
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
       let keeper_name = "runtime-trust-passive-only-no-work" in
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
             ; "terminal_reason_code", `String "completed"
             ; "completion_contract_result", `String "passive_only"
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

let test_completion_blocker_supersedes_passive_only_receipt () =
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
       let keeper_name = "runtime-trust-accept-empty" in
       let blocker_detail =
         "Provider returned an empty assistant turn for runtime runpod_fable5.gemma4-coder-fable5; no text or tool progress was produced."
       in
       let blocker =
         Masc.Keeper_meta_contract.blocker_info_of_class
           ~detail:blocker_detail
           Masc.Keeper_meta_contract.Completion_contract_violation
       in
       let meta =
         make_meta keeper_name
         |> Masc.Keeper_meta_contract.map_runtime (fun rt ->
           { rt with last_blocker = Some blocker })
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
             ; "terminal_reason_code", `String "completed"
             ; "completion_contract_result", `String "passive_only"
             ]);
       let snapshot = K.snapshot_json ~config ~meta in
       let open Yojson.Safe.Util in
       Alcotest.(check string)
         "runtime blocker class"
         "completion_contract_violation"
         (snapshot
          |> member "runtime_blockers"
          |> member "runtime_blocker_class"
          |> to_string);
       Alcotest.(check string)
         "passive-only receipt does not become display reason"
         "fsm_invariant"
         (snapshot |> member "disposition_reason" |> to_string);
       Alcotest.(check string)
         "attention follows runtime blocker"
         "runtime_blocked"
         (snapshot |> member "attention_reason" |> to_string);
       Alcotest.(check bool)
         "runtime blocker summary names empty provider turn"
         true
         (String.equal
            blocker_detail
            (snapshot
             |> member "runtime_blockers"
             |> member "runtime_blocker_summary"
             |> to_string)))
;;

let test_unknown_completion_contract_result_is_explicit () =
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
             ; "terminal_reason_code", `String "completed"
             ; "completion_contract_result", `String "passive-only"
             ]);
       let snapshot = K.snapshot_json ~config ~meta in
       let open Yojson.Safe.Util in
       Alcotest.(check string)
         "raw result remains visible"
         "passive-only"
         (snapshot |> member "execution" |> member "completion_contract_result" |> to_string);
       Alcotest.(check string)
         "unknown result uses explicit sentinel"
         "unknown_completion_contract_result:passive-only"
         (snapshot |> member "execution" |> member "mutation_guard_summary" |> to_string))
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
            "unknown completion-contract result remains visible"
            `Quick
            test_unknown_completion_contract_result_stays_visible
        ; Alcotest.test_case
            "passive-only no-work receipt does not mark attention"
            `Quick
            test_passive_only_no_work_receipt_does_not_mark_attention
        ; Alcotest.test_case
            "runtime blocker supersedes passive-only receipt"
            `Quick
            test_completion_blocker_supersedes_passive_only_receipt
        ; Alcotest.test_case
            "completion-contract labels reject drift before typed parser"
            `Quick
            test_completion_contract_result_rejects_drifted_label_before_parser
        ; Alcotest.test_case
            "legacy satisfied completion-contract label is unknown"
            `Quick
            test_legacy_satisfied_completion_contract_result_is_unknown
        ; Alcotest.test_case
            "unknown completion-contract label uses explicit sentinel"
            `Quick
            test_unknown_completion_contract_result_is_explicit
        ; Alcotest.test_case
            "status model observability reuses runtime-trust execution selected model"
            `Quick
            test_model_observability_uses_runtime_trust_execution_selected_model
        ] )
    ]
;;
