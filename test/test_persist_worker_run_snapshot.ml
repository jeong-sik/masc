module Lib = Masc_mcp
module U = Yojson.Safe.Util
module Oas = Agent_sdk

open Alcotest

let test_counter = ref 0

let temp_dir prefix =
  incr test_counter;
  let dir =
    Filename.temp_file (Printf.sprintf "%s_%d_" prefix !test_counter) ""
  in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path
        |> Array.iter (fun name -> rm (Filename.concat path name));
        Unix.rmdir path
      end else
        Unix.unlink path
  in
  try rm dir with _ -> ()

let sample_proof ~(run_id : string) : Oas.Cdal_proof.t =
  {
    schema_version = Oas.Cdal_proof.schema_version_current;
    run_id;
    contract_id = "dc-proof";
    requested_execution_mode = Oas.Execution_mode.Execute;
    effective_execution_mode = Oas.Execution_mode.Execute;
    mode_decision_source = "test";
    risk_class = Oas.Risk_class.Medium;
    provider_snapshot =
      {
        Oas.Cdal_proof.provider_name = "glm";
        model_id = "glm-5";
        api_version = None;
      };
    capability_snapshot =
      {
        Oas.Cdal_proof.tools =
          [ "file_read"; "file_write"; "shell_exec"; "masc_team_session_step" ];
        mcp_servers = [];
        max_turns = 10;
        max_tokens = Some 4096;
        thinking_enabled = None;
      };
    tool_trace_refs = [ "proof-store://proof-run-123/tool-trace-1" ];
    raw_evidence_refs =
      [
        "proof-store://proof-run-123/evidence-1";
        "proof-store://proof-run-123/evidence-2";
      ];
    checkpoint_ref = Some "proof-store://proof-run-123/checkpoint";
    result_status = Oas.Cdal_proof.Completed;
    started_at = 1000.0;
    ended_at = 1001.0;
    scope = None;
  }

let with_snapshot_env f =
  let dir = temp_dir "persist_worker_run_snapshot" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Lib.Room.default_config dir in
      ignore (Lib.Room.init config ~agent_name:(Some "snapshot-tester"));
      let ctx : _ Lib.Tool_team_session_step_exec.context =
        {
          config;
          agent_name = "snapshot-tester";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = None;
          net = None;
        }
      in
      let deps : Lib.Tool_team_session_step_exec.step_deps =
        {
          json_error = (fun msg -> msg);
          json_ok = (fun _ -> "{}");
          get_valid_session_id = (fun _ -> Error "unused");
          ensure_session_access = (fun _ _ -> Error "unused");
          parse_step_spawn_specs = (fun _ -> Error "unused");
          annotate_control_hierarchy_for_session = (fun _ specs -> specs);
          parse_turn_kind = (fun _ -> Error "unused");
          parse_turn_kind_opt = (fun _ -> Ok None);
          parse_wait_mode = (fun _ -> Team_session_types.Wait_blocking);
          int_opt_to_json =
            (function Some n -> `Int n | None -> `Null);
          float_opt_to_json =
            (function Some n -> `Float n | None -> `Null);
          truncate_for_event = (fun ?max_len:_ text -> text);
          make_worker_run_id = (fun () -> "unused-run-id");
          derived_local_runtime_actor =
            (fun ~session_id:_ ~prompt:_ -> "unused-worker");
          is_local_spawn_agent = (fun _ -> false);
          effective_execution_scope_of_spec = (fun _ -> None);
          inferred_controller_level_of_spec = (fun _ -> None);
          planned_worker_of_spec =
            (fun ?runtime_actor:_ _ ->
              failwith "planned_worker_of_spec unused");
          register_planned_workers = (fun _ _ _ -> Ok ());
          ensure_session_actor = (fun _ _ _ -> Ok ());
          record_session_turn_json =
            (fun ~config:_ ~session_id:_ ~actor:_ ~turn_kind:_
                 ~message:_ ~target_agent:_ ~task_title:_ ~task_description:_
                 ~task_priority:_ -> Error "unused");
          resolve_target_worker_name = (fun _ _ _ -> None);
          session_has_turn_for_actor = (fun _ _ _ -> false);
          auto_note_message_of_spawn_output = (fun _ -> None);
          reconcile_failed_spawn_actor =
            (fun _ _ _ -> Error "unused");
          extract_vote_id = (fun _ -> None);
          oas_worker_evidence_payload =
            (fun ~config:_ ~evidence_session_id:_ -> None);
          oas_trace_capability_to_string =
            (fun _ -> "summary_only");
          oas_worker_status_to_json = (fun _ -> `String "completed");
          worker_run_status_to_json =
            (function
             | `Accepted -> `String "accepted"
             | `Ready -> `String "ready"
             | `Running -> `String "running"
             | `Completed -> `String "completed"
             | `Failed -> `String "failed");
          raw_trace_run_ref_to_json = (fun _ -> `String "trace-ref");
          raw_trace_session_payloads =
            (fun ~config:_ ~fallback_session_id:_ _ -> None);
        }
      in
      let step_env : _ Lib.Tool_team_session_step_exec.step_env =
        {
          deps;
          ctx;
          session_id = "ts-proof-snapshot";
          actor = "snapshot-tester";
          wait_mode = Team_session_types.Wait_blocking;
        }
      in
      f config step_env)

let read_worker_meta config worker_run_id =
  Lib.Team_session_store.worker_run_meta_path config "ts-proof-snapshot"
    worker_run_id
  |> Room_utils.read_json config

let persist_snapshot ?proof step_env =
  Lib.Tool_team_session_step_exec.persist_worker_run_snapshot step_env
    ~worker_run_id:"wr-proof-snapshot"
    ~worker_name:"worker-proof"
    ~mode:"spawn"
    ~wait_mode:Team_session_types.Wait_blocking
    ~execution_scope:Team_session_types.Limited_code_change
    ~status:`Completed
    ~resolved_runtime:"llama-primary"
    ~resolved_model:"glm-5"
    ~success:true
    ~output_preview:"ok"
    ~trace_capability:"summary_only"
    ?proof
    ()

let test_persist_worker_run_snapshot_with_proof () =
  with_snapshot_env @@ fun config step_env ->
  let proof = sample_proof ~run_id:"proof-run-123" in
  persist_snapshot ~proof step_env;
  let json = read_worker_meta config "wr-proof-snapshot" in
  check string "session_id injected" "ts-proof-snapshot"
    (json |> U.member "session_id" |> U.to_string);
  check string "worker_run_id preserved" "wr-proof-snapshot"
    (json |> U.member "worker_run_id" |> U.to_string);
  check bool "evidence refs normalized" true
    ((json |> U.member "evidence_refs" |> U.to_list) <> []);
  check string "proof run id" "proof-run-123"
    (json |> U.member "proof_run_id" |> U.to_string);
  check string "proof status" "completed"
    (json |> U.member "proof_status" |> U.to_string);
  check string "contract id" "dc-proof"
    (json |> U.member "contract_id" |> U.to_string);
  check string "proof risk class" "medium"
    (json |> U.member "proof_risk_class" |> U.to_string);
  check string "proof execution mode" "execute"
    (json |> U.member "proof_execution_mode" |> U.to_string);
  check int "proof evidence count" 2
    (json |> U.member "proof_evidence_count" |> U.to_int);
  check bool "proof persisted" true
    (json |> U.member "proof_present" |> U.to_bool);
  check bool "proof path exists" true
    (json |> U.member "proof_path" |> U.to_string |> Sys.file_exists);
  check string "tool surface status" "available"
    (json |> U.member "tool_surface_status" |> U.to_string);
  check string "tool surface source" "local_worker_tools"
    (json |> U.member "tool_surface_source" |> U.to_string);
  check (list string) "tool surface shell names"
    [ "file_read"; "file_write"; "shell_exec" ]
    (json |> U.member "tool_surface_shell_names" |> U.to_list
   |> List.map U.to_string)

let test_persist_worker_run_snapshot_without_proof () =
  with_snapshot_env @@ fun config step_env ->
  persist_snapshot step_env;
  let json = read_worker_meta config "wr-proof-snapshot" in
  check string "session_id injected without proof" "ts-proof-snapshot"
    (json |> U.member "session_id" |> U.to_string);
  check bool "proof_run_id null" true
    (json |> U.member "proof_run_id" = `Null);
  check bool "contract_id null" true
    (json |> U.member "contract_id" = `Null);
  check bool "proof_status null" true
    (json |> U.member "proof_status" = `Null);
  check bool "proof_risk_class null" true
    (json |> U.member "proof_risk_class" = `Null);
  check bool "proof_execution_mode null" true
    (json |> U.member "proof_execution_mode" = `Null);
  check bool "proof_evidence_count null" true
    (json |> U.member "proof_evidence_count" = `Null);
  check string "tool surface status without proof" "available"
    (json |> U.member "tool_surface_status" |> U.to_string)

let test_persist_worker_run_snapshot_rejects_invalid_run_id () =
  with_snapshot_env @@ fun config step_env ->
  let proof = sample_proof ~run_id:"../escape" in
  persist_snapshot ~proof step_env;
  let json = read_worker_meta config "wr-proof-snapshot" in
  check bool "invalid proof_run_id dropped" true
    (json |> U.member "proof_run_id" = `Null);
  check bool "invalid proof_status dropped" true
    (json |> U.member "proof_status" = `Null);
  check bool "invalid proof_risk_class dropped" true
    (json |> U.member "proof_risk_class" = `Null);
  check bool "invalid proof_execution_mode dropped" true
    (json |> U.member "proof_execution_mode" = `Null);
  check bool "invalid proof_evidence_count dropped" true
    (json |> U.member "proof_evidence_count" = `Null)

let () =
  Alcotest.run "persist_worker_run_snapshot"
    [
      ( "snapshot",
        [
          test_case "with proof" `Quick
            test_persist_worker_run_snapshot_with_proof;
          test_case "without proof" `Quick
            test_persist_worker_run_snapshot_without_proof;
          test_case "invalid run id" `Quick
            test_persist_worker_run_snapshot_rejects_invalid_run_id;
        ] );
    ]
