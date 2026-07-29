(** Behavioral post-turn durability and compaction tests. *)

open Alcotest

module Compact_policy = Masc.Keeper_compact_policy
module Post_turn = Masc.Keeper_post_turn
module Admission = Masc.Keeper_turn_admission
module Cycle = Masc.Keeper_heartbeat_loop_cycle
module Queue = Keeper_event_queue
module Registry_queue = Masc.Keeper_registry_event_queue
module WO = Masc.Keeper_world_observation
module Exact_fixture = Compaction_exact_output_fixture
module Schema = Masc.Keeper_structured_output_schema
module Summarizer = Masc.Keeper_compaction_llm_summarizer

let ensure_registered_keeper
      ~base_path
      (meta : Masc.Keeper_meta_contract.keeper_meta)
  =
  match Masc.Keeper_registry.get ~base_path meta.name with
  | Some _ -> ()
  | None ->
    ignore
      (Masc.Keeper_registry.register_offline
         ~base_path
         meta.name
         meta)
;;

let exact_terminal ?(slot_id = "compaction-slot") ?(call_id = "call-compaction") cause =
  Keeper_compaction_outcome.
    { cause
    ; slot_id
    ; call_id
    ; plan_fingerprint = "compaction-plan"
    ; request_body_sha256 = String.make 64 'c'
    }
;;

let exact_response ~summary ~keep_from_unit_index =
  Exact_fixture.openai_response
    (`Assoc
       [ Schema.compaction_plan_field_summary, `String summary
       ; ( Schema.compaction_plan_field_keep_from_unit_index
         , `Int keep_from_unit_index )
       ])
;;

let summarize_response summary =
  exact_response ~summary ~keep_from_unit_index:2
;;

let invalid_boundary_response =
  exact_response ~summary:"invalid boundary" ~keep_from_unit_index:1
;;

let init_runtime_fixture () =
  let runtime_path =
    Filename.concat (Masc_test_deps.find_project_root ()) "config/runtime.toml"
  in
  match Runtime.init_default ~config_path:runtime_path with
  | Ok () -> ()
  | Error detail -> failf "runtime fixture initialization failed: %s" detail
;;

let publish_exact_fixture ?connect_timeout_s ~source
    (server : Exact_fixture.test_server) =
  Exact_fixture.publish_runtime_lane
    ?connect_timeout_s
    ~source
    ~base_url:server.Exact_fixture.base_url
    ()
  |> ignore
;;

let with_eio_context env sw f =
  Eio_context.with_test_env
    ~net:(Eio.Stdenv.net env)
    ~clock:(Eio.Stdenv.clock env)
    ~mono_clock:(Eio.Stdenv.mono_clock env)
    ~sw
    f
;;

let rec find_eligible_units_payload = function
  | `String value when String.starts_with ~prefix:"eligible_units=" value ->
    Some value
  | `Assoc fields ->
    List.find_map (fun (_, value) -> find_eligible_units_payload value) fields
  | `List values -> List.find_map find_eligible_units_payload values
  | _ -> None
;;

let eligible_units_of_only_request server =
  let request_body =
    match Exact_fixture.request_bodies server with
    | [ request_body ] -> request_body
    | requests ->
      failf "expected one exact-output request, got %d" (List.length requests)
  in
  let payload =
    match
      request_body
      |> Yojson.Safe.from_string
      |> find_eligible_units_payload
    with
    | Some payload -> payload
    | None -> fail "exact-output request omitted eligible_units"
  in
  let prefix = "eligible_units=" in
  let payload_end =
    String.index_opt payload '\n'
    |> Option.value ~default:(String.length payload)
  in
  payload
  |> fun payload ->
  String.sub payload (String.length prefix) (payload_end - String.length prefix)
  |> Yojson.Safe.from_string
  |> Yojson.Safe.Util.to_list
;;

let test_compaction_rejection_tag_is_stable () =
  let error =
    Post_turn.Compaction_rejected
      (Compact_policy.Invalid_structural_evidence
         ( Keeper_compaction_evidence.No_messages_compacted
         , exact_terminal Keeper_compaction_outcome.Invalid_structural_evidence ))
  in
  check string
    "categorical tag excludes evidence detail"
    "invalid_structural_evidence"
    (Post_turn.compaction_recovery_error_to_tag error);
  check
    string
    "diagnostic detail remains observable"
    "compaction rejected: invalid_structural_evidence:no_messages_compacted:\
     invalid_structural_evidence:slot_id=compaction-slot:call_id=call-compaction:\
     plan_fingerprint=compaction-plan:\
     request_body_sha256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    (Post_turn.compaction_recovery_error_to_string error)

let test_final_admission_busy_requeues_only_pre_dispatch_no_compaction () =
  let preserves =
    Masc.Keeper_manual_compaction.For_testing
    .preserve_no_compaction_after_final_admission_busy
  in
  check
    bool
    "No_eligible_history remains replayable after final admission Busy"
    false
    (preserves Keeper_compaction_outcome.No_eligible_history);
  check
    bool
    "post-dispatch exact terminal remains source-bound after final admission Busy"
    true
    (preserves
       (Keeper_compaction_outcome.Exact_execution_terminal
          (exact_terminal Keeper_compaction_outcome.Exact_execution_failed)))
;;

let test_exact_no_compaction_acknowledges_without_persistence_facade () =
  let disposition =
    Masc.Keeper_unified_turn.source_disposition_after_no_compaction_reason
  in
  List.iter
    (fun reason ->
       match disposition reason with
       | Masc.Keeper_unified_turn.Acknowledge_after_in_turn_handling -> ()
       | _ -> fail "exact terminal no-compaction did not acknowledge its source")
    [ Keeper_compaction_outcome.Exact_lane_unconfigured
    ; Keeper_compaction_outcome.Exact_execution_terminal
        (exact_terminal Keeper_compaction_outcome.Exact_execution_failed)
    ];
  match disposition Keeper_compaction_outcome.No_eligible_history with
  | Masc.Keeper_unified_turn.Follow_failure_route_after_no_compaction
      { reason = Keeper_compaction_outcome.No_eligible_history } ->
    ()
  | _ -> fail "pre-dispatch no-compaction lost its ordinary failure route"
;;

let make_meta
      ?(name = "post-turn-no-auto-compact")
      ?(trace_id = "trace-post-turn-no-auto-compact")
      ()
  : Masc.Keeper_meta_contract.keeper_meta
  =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String name
        ; "trace_id", `String trace_id
        ])
  with
  | Ok meta -> meta
  | Error detail -> failf "keeper meta fixture failed: %s" detail

let make_checkpoint () =
  Agent_sdk.Checkpoint.
    { version = checkpoint_version
    ; session_id = "trace-post-turn-no-auto-compact"
    ; agent_name = "post-turn-no-auto-compact"
    ; model = "test-model"
    ; system_prompt = None
    ; messages =
        [ Agent_sdk.Types.text_message Agent_sdk.Types.User "keep"
        ; Agent_sdk.Types.text_message Agent_sdk.Types.Assistant (String.make 2048 'x')
        ; Agent_sdk.Types.text_message Agent_sdk.Types.User (String.make 2048 'y')
        ]
    ; usage = Agent_sdk.Types.empty_usage
    ; turn_count = 7
    ; created_at = 1_700_000_000.0
    ; tools = []
    ; tool_choice = None
    ; disable_parallel_tool_use = false
    ; temperature = None
    ; top_p = None
    ; top_k = None
    ; min_p = None
    ; enable_thinking = None
    ; preserve_thinking = None
    ; response_format = Agent_sdk.Types.Off
    ; thinking_budget = None
    ; reasoning_effort = None
    ; cache_system_prompt = false
    ; context = Agent_sdk.Context.create_sync ()
    ; mcp_sessions = []
    ; working_context = None
    }

let block_message role content : Agent_sdk.Types.message =
  { role; content; name = None; tool_call_id = None; metadata = [] }

let tool_use id =
  Agent_sdk.Types.ToolUse
    { id; name = "test_tool"; input = `Assoc [ "id", `String id ] }

let tool_result id =
  Agent_sdk.Types.ToolResult
    { tool_use_id = id
    ; content = "result:" ^ id
    ; outcome = Tool_succeeded
    ; json = None
    ; content_blocks = None
    }

let test_atomic_cycle_and_normalization_cross_evidence_gate () =
  Eio_main.run @@ fun env ->
  Masc_test_deps.init_eio_clock env;
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  with_eio_context env sw @@ fun () ->
  let base_path = Masc_test_deps.setup_test_workspace () in
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () ->
      Runtime.For_testing.restore runtime_snapshot;
      Masc_test_deps.cleanup_test_workspace base_path)
    (fun () ->
      let config = Masc.Workspace.default_config base_path in
      ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
      init_runtime_fixture ();
      let run_case ~name ~messages response =
        let server =
          Exact_fixture.start_server
            ~sw
            ~net:(Eio.Stdenv.net env)
            ~clock:(Eio.Stdenv.clock env)
            (Exact_fixture.Reply response)
        in
        publish_exact_fixture ~source:name server;
        let meta = make_meta ~name () in
        ensure_registered_keeper ~base_path:config.base_path meta;
        let checkpoint = { (make_checkpoint ()) with messages } in
        let context =
          checkpoint |> Masc.Keeper_context_core.context_of_oas_checkpoint
        in
        let preparation =
          Compact_policy.compact_for_request_typed
            ~before_dispatch_authority:(fun _ -> Ok ())
            ~base_path:config.base_path
            ~meta
            ~trigger:Compaction_trigger.Manual
            context
        in
        check int (name ^ " dispatches exactly once") 1
          (Exact_fixture.post_count server);
        match preparation.decision, preparation.evidence with
        | Compact_policy.Prepared Compaction_trigger.Manual, Some _ ->
          (match preparation.post_success_terminalizer with
           | None -> failf "%s lost its post-success terminalizer" name
           | Some terminalizer ->
             (match
                Summarizer.terminalize_post_success
                  terminalizer
                  Keeper_compaction_outcome.Domain_invalid_output
              with
              | Summarizer.Terminalized _ -> ()
              | _ -> failf "%s could not close its exact attempt" name))
        | _ -> failf "%s did not cross the structural evidence gate" name
      in
      run_case
        ~name:"atomic-cycle-evidence"
        ~messages:
          [ block_message Agent_sdk.Types.User [ Agent_sdk.Types.Text "prompt" ]
          ; block_message Agent_sdk.Types.Assistant
              [ Agent_sdk.Types.Thinking
                  { content = "private"; signature = None }
              ; tool_use "atomic"
              ]
          ; block_message Agent_sdk.Types.Tool
              [ Agent_sdk.Types.ToolResult
                  { tool_use_id = "atomic"
                  ; content = String.make 4096 'r'
                  ; outcome = Tool_succeeded
                  ; json = Some (`Assoc [ "status", `String "done" ])
                  ; content_blocks = None
                  }
              ]
          ; block_message Agent_sdk.Types.Assistant
              [ Agent_sdk.Types.Text "raw suffix" ]
          ]
        (summarize_response "done");
      run_case
        ~name:"reasoning-normalization-evidence"
        ~messages:
          [ block_message Agent_sdk.Types.User [ Agent_sdk.Types.Text "prompt" ]
          ; block_message Agent_sdk.Types.Assistant
              [ Agent_sdk.Types.Thinking
                  { content = String.make 4096 'p'; signature = None }
              ; Agent_sdk.Types.Text "visible"
              ]
          ; block_message Agent_sdk.Types.User
              [ Agent_sdk.Types.Text "follow-up" ]
          ]
        (summarize_response "visible"))
;;

let test_regular_post_turn_does_not_auto_compact () =
  Eio_main.run @@ fun _env ->
  let meta = make_meta () in
  let checkpoint = make_checkpoint () in
  let result =
    Post_turn.apply_post_turn_lifecycle_with_resilience_handles
      ~resilience_audit_store:None
      ~resilience_strategy_executor:None
      ~meta
      ~checkpoint:(Some checkpoint)
  in
  match result.checkpoint with
  | None -> fail "regular post-turn discarded the checkpoint"
  | Some retained ->
    check int "checkpoint turn retained" checkpoint.turn_count retained.turn_count;
    check bool "checkpoint messages retained exactly" true
      (retained.messages = checkpoint.messages)

let only_compaction_manifest config (meta : Masc.Keeper_meta_contract.keeper_meta) =
  let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  Masc.Keeper_runtime_manifest.path_for_trace
    config
    ~keeper_name:meta.name
    ~trace_id
  |> Fs_compat.load_file
  |> String.split_on_char '\n'
  |> List.filter_map (fun line ->
    if String.equal (String.trim line) ""
    then None
    else
      match Masc.Keeper_runtime_manifest.of_json (Yojson.Safe.from_string line) with
      | Ok ({ event = Context_compacted; _ } as row) -> Some row
      | Ok _ -> None
      | Error detail -> failf "runtime manifest decode failed: %s" detail)
  |> function
  | [ row ] -> row
  | rows -> failf "expected one manual compaction manifest, got %d" (List.length rows)
;;

let test_missing_exact_lane_is_source_bound_no_compaction () =
  Eio_main.run @@ fun env ->
  Masc_test_deps.init_eio_clock env;
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  with_eio_context env sw @@ fun () ->
  let base_path = Masc_test_deps.setup_test_workspace () in
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () ->
      Runtime.For_testing.restore runtime_snapshot;
      Masc_test_deps.cleanup_test_workspace base_path)
    (fun () ->
       let meta = make_meta () in
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       init_runtime_fixture ();
       let checkpoint = make_checkpoint () in
       let session =
         Masc.Keeper_context_core.create_session
           ~session_id:checkpoint.session_id
           ~base_dir:(Masc.Keeper_types_profile.session_base_dir config)
       in
       let context = Masc.Keeper_context_core.context_of_oas_checkpoint checkpoint in
       let expected_source =
         match
          Masc.Keeper_context_core.save_oas_checkpoint_classified
            ~multimodal_policy:meta.multimodal_policy
            ~keeper_name:meta.name
            ~session
            ~agent_name:meta.agent_name
            ~ctx:context
            ~generation:1
        with
        | Ok _ ->
          (match
             Masc.Keeper_checkpoint_store.load_oas_with_ref
               ~session_dir:session.session_dir
               ~session_id:checkpoint.session_id
           with
           | Ok (_, source) -> source
           | Error error ->
             failf
               "missing-lane checkpoint source fixture failed: %s"
               (Post_turn.compaction_recovery_error_to_string
                  (Post_turn.Checkpoint_ref_load_failed error)))
        | Error detail ->
          failf
            "missing-lane checkpoint fixture failed: %s"
            (Masc.Keeper_context_core.checkpoint_write_error_to_string
               ~persistence_error_to_string:(fun detail -> detail)
               detail)
       in
       let resolver_snapshot =
         Exact_fixture.resolver_snapshot
           ~source:"post-turn missing exact lane"
           [ ({ id = "unused-exact-target"; base_url = "http://127.0.0.1:9" }
              : Exact_fixture.target_fixture)
           ]
       in
       (match Runtime_exact_output_registry.publish ~lanes:[] resolver_snapshot with
        | Ok _ -> ()
        | Error error ->
          failf
            "empty exact lane registry fixture failed: %s"
            (Runtime_exact_output_registry.publication_error_to_string error));
       ensure_registered_keeper ~base_path:config.base_path meta;
       match
         Post_turn.prepare_compaction
           ~base_path:config.base_path
           ~base_dir:(Masc.Keeper_types_profile.session_base_dir config)
           ~meta
           ~trigger:Compaction_trigger.Manual
           ()
       with
       | Error
           (Post_turn.No_compaction
              { source
              ; reason = Keeper_compaction_outcome.Exact_lane_unconfigured
              }) ->
         check string
           "terminal evidence retains checkpoint trace"
           (Keeper_id.Trace_id.to_string expected_source.trace_id)
           (Keeper_id.Trace_id.to_string source.trace_id);
         check int
           "terminal evidence retains checkpoint turn"
           expected_source.turn_count
           source.turn_count;
         check int
           "terminal evidence retains checkpoint generation"
           expected_source.generation
           source.generation;
         check string
           "terminal evidence retains checkpoint digest"
           expected_source.sha256
           source.sha256
       | Error error ->
         failf
           "missing exact lane returned a retryable error: %s"
           (Post_turn.compaction_recovery_error_to_string error)
       | Ok _ -> fail "missing exact lane unexpectedly prepared compaction")
;;

let test_malformed_structure_preserves_checkpoint () =
  Eio_main.run @@ fun env ->
  Masc_test_deps.init_eio_clock env;
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  with_eio_context env sw @@ fun () ->
  let base_path = Masc_test_deps.setup_test_workspace () in
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () ->
      Runtime.For_testing.restore runtime_snapshot;
      Masc_test_deps.cleanup_test_workspace base_path)
    (fun () ->
  let config = Masc.Workspace.default_config base_path in
  ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
  init_runtime_fixture ();
  let exact_server =
    Exact_fixture.start_server
      ~sw
      ~net:(Eio.Stdenv.net env)
      ~clock:(Eio.Stdenv.clock env)
      (Exact_fixture.Reply (summarize_response "must remain unreachable"))
  in
  publish_exact_fixture ~source:"post-turn malformed structure" exact_server;
  let meta = make_meta ~name:"malformed-compaction" () in
  let orphan = block_message User [ tool_result "orphan" ] in
  let checkpoint = { (make_checkpoint ()) with messages = [ orphan ] } in
  let context =
    Masc.Keeper_context_core.context_of_oas_checkpoint checkpoint in
  ensure_registered_keeper ~base_path:config.base_path meta;
  let preparation =
    Compact_policy.compact_for_request_typed
      ~base_path:config.base_path
      ~meta
      ~trigger:Compaction_trigger.Manual
      context
  in
  check int "malformed input never reaches exact dispatch" 0
    (Exact_fixture.post_count exact_server);
  check bool "original message remains exact" true
    (Masc.Keeper_context_core.messages_of_context preparation.context = [ orphan ]);
  match preparation.decision with
  | Compact_policy.Rejected
      ( Manual
      , Invalid_structure
          (Masc.Keeper_compaction_unit.Orphan_tool_result
            { message_index = 0; tool_use_id = "orphan" }) ) ->
    ()
  | _ -> fail "malformed compaction was not rejected with typed structure")
;;

let test_checkpoint_installation_auxiliary_manifest_tags () =
  let write_error =
    { Masc.Keeper_fs.renamed = true
    ; stage = Masc.Keeper_fs.Parent_directory_fsync_after_rename
    ; failure = Masc.Keeper_fs.Operation_failed "injected durability uncertainty"
    }
  in
  let lock_error =
    { File_lock_eio.lock_path = "/tmp/checkpoint-installation-auxiliary.lock"
    ; phase = File_lock_eio.Release_process_lock
    ; cause =
        { File_lock_eio.error = Unix.EIO
        ; operation = "injected_release"
        ; argument = "/tmp/checkpoint-installation-auxiliary.lock"
        }
    ; cleanup_failure = None
    }
  in
  let failure detail = Failure detail, Printexc.get_callstack 1 in
  let auxiliaries =
    [ Masc.Keeper_checkpoint_store.Commit_durability_unknown write_error
    ; Masc.Keeper_checkpoint_store.Commit_observer_failed (failure "observer")
    ; Masc.Keeper_checkpoint_store.Release_process_lock_failed lock_error
    ; Masc.Keeper_checkpoint_store.Post_commit_unwind_interrupted
        (failure "unwind")
    ; Masc.Keeper_checkpoint_store.History_write_failed (failure "history")
    ]
  in
  let kinds =
    auxiliaries
    |> List.map
         Masc.Keeper_manual_compaction.For_testing.checkpoint_installation_auxiliary_to_json
    |> List.map (fun json ->
      let open Yojson.Safe.Util in
      check bool
        "every installation auxiliary requires operator action"
        true
        (json |> member "operator_action_required" |> to_bool);
      check bool
        "every installation auxiliary has detail"
        true
        (json |> member "detail" |> to_string |> String.trim |> fun detail ->
         detail <> "");
      json |> member "kind" |> to_string)
  in
  check (list string)
    "all installation auxiliary constructors have stable manifest tags"
    [ "commit_durability_unknown"
    ; "commit_observer_failed"
    ; "release_process_lock_failed"
    ; "post_commit_unwind_interrupted"
    ; "history_write_failed"
    ]
    kinds
;;

let[@inline never] raise_history_cancellation () =
  raise
    (Eio.Cancel.Cancelled
       (Failure "injected history cancellation at canonical origin"))
;;

let string_contains ~needle haystack =
  let needle_length = String.length needle in
  let haystack_length = String.length haystack in
  let rec loop offset =
    offset + needle_length <= haystack_length
    && (String.sub haystack offset needle_length = needle
        || loop (offset + 1))
  in
  needle_length = 0 || loop 0
;;

let test_prepare_commit_source_cas () =
  (* The prepare/commit split exists so the provider call can run outside
     the keeper admission; the source CAS — not the slot — is the
     interleaving guard. Pin both halves with two tokens prepared from one
     source: the first commits and the second is rejected after advancement. *)
  Eio_main.run @@ fun env ->
  Masc_test_deps.init_eio_clock env;
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  with_eio_context env sw @@ fun () ->
  let base_path = Masc_test_deps.setup_test_workspace () in
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () ->
      Runtime.For_testing.restore runtime_snapshot;
      Masc_test_deps.cleanup_test_workspace base_path)
    (fun () ->
       let meta = make_meta () in
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       init_runtime_fixture ();
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let checkpoint = make_checkpoint () in
       let session =
         Masc.Keeper_context_core.create_session
           ~session_id:checkpoint.session_id
           ~base_dir:(Masc.Keeper_types_profile.session_base_dir config)
       in
       let context = Masc.Keeper_context_core.context_of_oas_checkpoint checkpoint in
       (match
          Masc.Keeper_context_core.save_oas_checkpoint_classified
            ~multimodal_policy:meta.multimodal_policy
            ~keeper_name:meta.name
            ~session
            ~agent_name:meta.agent_name
            ~ctx:context
            ~generation:1
        with
        | Ok _ -> ()
        | Error detail ->
          failf
            "fixture checkpoint save failed: %s"
            (Masc.Keeper_context_core.checkpoint_write_error_to_string
               ~persistence_error_to_string:(fun detail -> detail)
               detail));
  let exact_server =
    Exact_fixture.start_server
      ~sw
      ~net:(Eio.Stdenv.net env)
      ~clock:(Eio.Stdenv.clock env)
      (Exact_fixture.Reply (summarize_response "shorter"))
  in
  publish_exact_fixture ~source:"post-turn prepared source CAS" exact_server;
  ensure_registered_keeper ~base_path:config.base_path meta;
  match
    Post_turn.prepare_compaction
      ~before_dispatch_authority:(fun _ -> Ok ())
      ~base_path:config.base_path
      ~base_dir:(Masc.Keeper_types_profile.session_base_dir config)
      ~meta
      ~trigger:Compaction_trigger.Manual
      ()
  with
  | Error error ->
    failf
      "prepare failed: %s"
      (Post_turn.compaction_recovery_error_to_string error)
  | Ok prepared ->
    let stale_prepared =
      match
        Post_turn.prepare_compaction
          ~before_dispatch_authority:(fun _ -> Ok ())
          ~base_path:config.base_path
          ~base_dir:(Masc.Keeper_types_profile.session_base_dir config)
          ~meta
          ~trigger:Compaction_trigger.Manual
          ()
      with
      | Ok stale_prepared -> stale_prepared
      | Error error ->
        failf
          "second prepare failed: %s"
          (Post_turn.compaction_recovery_error_to_string error)
    in
    check int
      "two prepared tokens perform one exact dispatch each"
      2
      (Exact_fixture.post_count exact_server);
    let was_recording = Printexc.backtrace_status () in
    Printexc.record_backtrace true;
    let recovery =
      Fun.protect
        ~finally:(fun () -> Printexc.record_backtrace was_recording)
        (fun () ->
           match
             Post_turn.For_testing.commit_prepared_compaction_with_history
               ~save_oas_history:(fun ~session_dir:_ _ ->
                 raise_history_cancellation ())
               prepared
           with
           | Post_turn.Committed recovery -> recovery
           | Post_turn.Commit_failed { error; _ } ->
             failf
               "commit of a fresh prepared plan failed: %s"
               (Post_turn.compaction_recovery_error_to_string error)
           | Post_turn.Already_rejected no_compaction ->
             failf
               "fresh prepared plan was rejected: %s"
               (Post_turn.compaction_recovery_error_to_string
                  (Post_turn.No_compaction no_compaction))
           | Post_turn.Commit_in_progress _
           | Post_turn.Already_committed _ ->
             fail "fresh prepared plan did not own its commit")
    in
    (match recovery.checkpoint_installation with
     | Masc.Keeper_checkpoint_store.Installed installed ->
       check bool
         "history cancellation remains typed after install"
         true
         (List.exists
            (function
              | Masc.Keeper_checkpoint_store.History_write_failed
                  (Eio.Cancel.Cancelled _, backtrace) ->
                Printexc.raw_backtrace_length backtrace > 0
                && string_contains
                     ~needle:"raise_history_cancellation"
                     (Printexc.raw_backtrace_to_string backtrace)
              | _ -> false)
            installed.auxiliary)
     | Masc.Keeper_checkpoint_store.Not_installed _ ->
       fail "history cancellation downgraded the installed checkpoint");
    let committed_snapshot =
      Post_turn.For_testing.post_success_snapshot prepared
    in
    check bool
      "installed history cancellation leaves the affine phase committed"
      true
      (committed_snapshot.phase
       = Masc.Keeper_compaction_llm_summarizer.Phase_committed);
    check int
      "history cancellation retains one Domain_valid completion"
      1
      committed_snapshot.domain_valid_attempts;
    check int
      "history cancellation performs no Domain_rejected completion"
      0
      committed_snapshot.domain_rejected_attempts;
    (* Both tokens were prepared from the same source. The first commit
       advances it; the second token now proves the source-CAS rejection
       without violating the same-token affine commit contract. *)
    (match
       Post_turn.commit_prepared_compaction stale_prepared
     with
     | Post_turn.Already_rejected
         { reason =
             Keeper_compaction_outcome.Exact_execution_terminal
               { cause = Keeper_compaction_outcome.Checkpoint_source_changed
               ; slot_id
               ; call_id
               }
         ; _
         } ->
       check bool "stale prepared terminal retains slot" true (String.trim slot_id <> "");
       check bool "stale prepared terminal retains call" true (String.trim call_id <> "")
     | Post_turn.Already_rejected no_compaction ->
       failf
         "stale prepared value returned an unexpected rejection: %s"
         (Post_turn.compaction_recovery_error_to_string
            (Post_turn.No_compaction no_compaction))
     | Post_turn.Commit_failed { error; _ } ->
       failf
         "stale prepared value failed with the wrong error: %s"
         (Post_turn.compaction_recovery_error_to_string error)
     | Post_turn.Committed _
     | Post_turn.Already_committed _ ->
       fail "stale prepared value committed past the source CAS"
     | Post_turn.Commit_in_progress _ ->
       fail "stale prepared value did not reach canonical rejection"))
;;

let run_post_install_failure
      ~name
      ?complete_post_success_commit
      ?(cancel_after_install = false)
      ()
  =
  Eio_main.run @@ fun env ->
  Masc_test_deps.init_eio_clock env;
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  with_eio_context env sw @@ fun () ->
  let base_path = Masc_test_deps.setup_test_workspace () in
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () ->
      Runtime.For_testing.restore runtime_snapshot;
      Masc_test_deps.cleanup_test_workspace base_path)
    (fun () ->
       let meta = make_meta ~name () in
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       init_runtime_fixture ();
       let checkpoint = make_checkpoint () in
       let session =
         Masc.Keeper_context_core.create_session
           ~session_id:checkpoint.session_id
           ~base_dir:(Masc.Keeper_types_profile.session_base_dir config)
       in
       let context =
         Masc.Keeper_context_core.context_of_oas_checkpoint checkpoint
       in
       (match
          Masc.Keeper_context_core.save_oas_checkpoint_classified
            ~multimodal_policy:meta.multimodal_policy
            ~keeper_name:meta.name
            ~session
            ~agent_name:meta.agent_name
            ~ctx:context
            ~generation:1
        with
        | Ok _ -> ()
        | Error detail ->
          failf
            "fixture checkpoint save failed: %s"
            (Masc.Keeper_context_core.checkpoint_write_error_to_string
               ~persistence_error_to_string:(fun detail -> detail)
               detail));
       let exact_server =
         Exact_fixture.start_server
           ~sw
           ~net:(Eio.Stdenv.net env)
           ~clock:(Eio.Stdenv.clock env)
           (Exact_fixture.Reply (summarize_response "shorter"))
       in
       publish_exact_fixture ~source:name exact_server;
       ensure_registered_keeper ~base_path:config.base_path meta;
       let prepared =
         match
           Post_turn.prepare_compaction
             ~before_dispatch_authority:(fun _ -> Ok ())
             ~base_path:config.base_path
             ~base_dir:(Masc.Keeper_types_profile.session_base_dir config)
             ~meta
             ~trigger:Compaction_trigger.Manual
             ()
         with
         | Ok prepared -> prepared
         | Error error ->
           failf
             "prepare failed: %s"
             (Post_turn.compaction_recovery_error_to_string error)
       in
       let internal_waiter = ref None in
       let outer_waiter = ref None in
       let outcome =
         Post_turn.For_testing.commit_prepared_compaction_with_history
           ~after_checkpoint_installed:(fun () ->
             (match
                Post_turn.For_testing.claim_post_success_commit prepared
              with
              | Summarizer.Commit_claim_in_progress waiter ->
                internal_waiter := Some waiter;
                (match Post_turn.commit_prepared_compaction prepared with
                 | Post_turn.Commit_in_progress waiter ->
                   outer_waiter := Some waiter
                 | Post_turn.Committed _
                 | Post_turn.Commit_failed _
                 | Post_turn.Already_committed _
                 | Post_turn.Already_rejected _ ->
                   fail "installed commit did not expose its outer waiter")
              | Summarizer.Commit_claim_acquired
              | Summarizer.Commit_claim_already_committed
              | Summarizer.Commit_claim_rejected _ ->
                fail "installed commit did not expose its affine waiter");
             if cancel_after_install
             then
               raise
                 (Eio.Cancel.Cancelled
                    (Failure "injected post-install compaction cancellation")))
           ?complete_post_success_commit
           ~save_oas_history:(fun ~session_dir:_ _ -> ())
           prepared
       in
       (match outcome with
        | Post_turn.Commit_failed { committed = Some _; _ } -> ()
        | Post_turn.Commit_failed { committed = None; _ } ->
          fail "post-install failure lost the durable recovery"
        | Post_turn.Committed _
        | Post_turn.Commit_in_progress _
        | Post_turn.Already_committed _
        | Post_turn.Already_rejected _ ->
          fail "post-install failure did not publish typed commit failure");
       (match !internal_waiter with
        | Some waiter -> Eio.Promise.await waiter
        | None -> fail "post-install failure did not capture the commit waiter");
       (match !outer_waiter with
        | Some waiter ->
          (match Eio.Promise.await waiter with
           | Post_turn.Commit_completion_failed
               { committed = Some _; _ } ->
             ()
           | Post_turn.Commit_completion_failed { committed = None; _ }
           | Post_turn.Commit_completion_committed _
           | Post_turn.Commit_completion_rejected _ ->
             fail "outer waiter did not retain the durable failed commit")
        | None -> fail "post-install failure did not capture the outer waiter");
       let snapshot = Post_turn.For_testing.post_success_snapshot prepared in
       check bool
         "post-install failure closes the affine commit phase"
         true
         (snapshot.phase = Summarizer.Phase_committed);
       check int
         "post-install failure attempts Domain_valid exactly once"
         1
         snapshot.domain_valid_attempts;
       check int
         "post-install failure never rejects the installed checkpoint"
         0
         snapshot.domain_rejected_attempts;
       check int
         "post-install finalization performs no provider redispatch"
         1
         (Exact_fixture.post_count exact_server);
       (match
          Post_turn.For_testing.claim_post_success_commit prepared
        with
        | Summarizer.Commit_claim_already_committed -> ()
        | Summarizer.Commit_claim_acquired
        | Summarizer.Commit_claim_in_progress _
        | Summarizer.Commit_claim_rejected _ ->
          fail "closed Domain_valid failure admitted another claimant");
       (match Post_turn.commit_prepared_compaction prepared with
        | Post_turn.Commit_failed { committed = Some _; _ } -> ()
        | Post_turn.Commit_failed { committed = None; _ }
        | Post_turn.Committed _
        | Post_turn.Commit_in_progress _
        | Post_turn.Already_committed _
        | Post_turn.Already_rejected _ ->
          fail "closed Domain_valid failure lost its canonical outer result"))
;;

let test_post_install_domain_valid_error_resolves_waiters () =
  run_post_install_failure
    ~name:"post-install-domain-valid-error"
    ~complete_post_success_commit:
      (fun _ -> Error "injected post-success completion error")
    ()
;;

let test_post_install_domain_valid_exception_resolves_waiters () =
  run_post_install_failure
    ~name:"post-install-domain-valid-exception"
    ~complete_post_success_commit:
      (fun _ -> raise (Failure "injected post-success completion exception"))
    ()
;;

let test_post_install_cancellation_returns_committed_failure () =
  run_post_install_failure
    ~name:"post-install-cancellation"
    ~cancel_after_install:true
    ()
;;

let test_invalid_structural_evidence_after_dispatch_is_terminal () =
  Eio_main.run @@ fun env ->
  Masc_test_deps.init_eio_clock env;
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  with_eio_context env sw @@ fun () ->
  let base_path = Masc_test_deps.setup_test_workspace () in
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () ->
      Runtime.For_testing.restore runtime_snapshot;
      Masc_test_deps.cleanup_test_workspace base_path)
    (fun () ->
      let config = Masc.Workspace.default_config base_path in
      ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
      init_runtime_fixture ();
      let server =
        Exact_fixture.start_server
          ~sw
          ~net:(Eio.Stdenv.net env)
          ~clock:(Eio.Stdenv.clock env)
          (Exact_fixture.Reply (summarize_response "short"))
      in
      publish_exact_fixture ~source:"invalid structural evidence" server;
      let meta = make_meta ~name:"invalid-evidence-terminal" () in
      ensure_registered_keeper ~base_path:config.base_path meta;
      let context =
        make_checkpoint () |> Masc.Keeper_context_core.context_of_oas_checkpoint
      in
      let plan_for_units ~units =
        match
          Summarizer.make
            ~before_dispatch_authority:(fun _ -> Ok ())
            ~base_path:config.base_path
            ~keeper_name:meta.name
            ()
        with
        | None -> Error Summarizer.Exact_execution_context_unavailable
        | Some summarize -> summarize ~units
      in
      let preparation =
        Compact_policy.For_testing.compact_for_request_typed_with_accounting
          ~plan_for_units
          ~expected_after_message_count_override:0
          ~summarized_message_count_override:1
          ~meta
          ~trigger:Compaction_trigger.Manual
          context
      in
      check int "invalid evidence follows exactly one POST" 1
        (Exact_fixture.post_count server);
      (match preparation.decision with
       | Compact_policy.Rejected
           ( Manual
           , Invalid_structural_evidence
               ( Keeper_compaction_evidence.Invalid_transition
                   (Keeper_compaction_evidence.Messages, 0, observed_after_message_count)
               , { cause = Keeper_compaction_outcome.Invalid_structural_evidence
                 ; slot_id
                 ; call_id
                 } ) ) ->
         check bool "observed count is not the injected expectation" true
           (observed_after_message_count > 0);
         check bool "invalid evidence terminal retains slot" true
           (String.trim slot_id <> "");
         check bool "invalid evidence terminal retains call" true
           (String.trim call_id <> "")
       | _ -> fail "post-dispatch invalid evidence was not a typed terminal"))
;;

let test_post_dispatch_non_reducing_output_is_terminal () =
  Eio_main.run @@ fun env ->
  Masc_test_deps.init_eio_clock env;
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  with_eio_context env sw @@ fun () ->
  let base_path = Masc_test_deps.setup_test_workspace () in
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () ->
      Runtime.For_testing.restore runtime_snapshot;
      Masc_test_deps.cleanup_test_workspace base_path)
    (fun () ->
      let config = Masc.Workspace.default_config base_path in
      ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
      init_runtime_fixture ();
      let run_case ~name ~expected_cause response =
        let server =
          Exact_fixture.start_server
            ~sw
            ~net:(Eio.Stdenv.net env)
            ~clock:(Eio.Stdenv.clock env)
            (Exact_fixture.Reply response)
        in
        publish_exact_fixture ~source:name server;
        let meta = make_meta ~name () in
        ensure_registered_keeper ~base_path:config.base_path meta;
        let preparation =
          Compact_policy.compact_for_request_typed
            ~base_path:config.base_path
            ~before_dispatch_authority:(fun _ -> Ok ())
            ~meta
            ~trigger:Compaction_trigger.Manual
            (make_checkpoint ()
             |> Masc.Keeper_context_core.context_of_oas_checkpoint)
        in
        check int (name ^ " performs one POST") 1 (Exact_fixture.post_count server);
        (match preparation.decision with
         | Compact_policy.Rejected
             ( Manual
             , Exact_execution_terminal
                 { cause; slot_id; call_id } )
           when cause = expected_cause ->
           check bool (name ^ " terminal retains slot") true
             (String.trim slot_id <> "");
           check bool (name ^ " terminal retains call") true
             (String.trim call_id <> "")
         | _ -> fail (name ^ " did not report its own non-reduction cause"))
      in
      (* The two cases reported the same cause. Only one of them should: a plan the
         domain validator rejects IS invalid output, while a summarizer that returns a
         LARGER context produced valid output that worked against the purpose. Both stay
         terminal and keep slot and call provenance; they no longer read as the
         same failure. *)
      run_case
        ~name:"invalid-boundary-plan"
        ~expected_cause:Keeper_compaction_outcome.Domain_invalid_output
        invalid_boundary_response;
      run_case
        ~name:"larger-checkpoint"
        ~expected_cause:Keeper_compaction_outcome.Compaction_increased_checkpoint
        (summarize_response (String.make 20_000 'x')))
;;

(* RFC-0351 S0 / #25461: once the persisted failure streak suspends
   compaction retries, a reactive prepare must be refused before any
   checkpoint I/O — each new stimulus used to pay one full prepare
   (checkpoint load + summarizer LLM call) before its escalation settled.
   The fixture base_dir holds no checkpoint, so any prepare that passes the
   gate deterministically fails with [Checkpoint_ref_load_failed Ref_not_found];
   returning [Retry_suspended] instead proves the refusal fired first. *)
let test_suspended_streak_refuses_reactive_prepare () =
  Eio_main.run @@ fun _env ->
  let meta_with_streak streak =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
          [ "name", `String "prepare-admission"
          ; "trace_id", `String "trace-prepare-admission"
          ; "compaction_consecutive_failures", `Int streak
          ])
    with
    | Ok meta -> meta
    | Error detail -> failf "prepare-admission meta fixture: %s" detail
  in
  let base_dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-prepare-admission-%d" (Unix.getpid ()))
  in
  let prepare ~streak ~trigger =
    Post_turn.prepare_compaction
      ~base_path:base_dir
      ~base_dir
      ~meta:(meta_with_streak streak)
      ~trigger
      ()
  in
  let suspended = meta_with_streak 3 in
  check bool
    "fixture streak reaches the suspension threshold"
    true
    (Masc.Keeper_meta_contract.compaction_retry_suspended
       suspended.runtime.compaction_rt);
  (match
     prepare
       ~streak:3
       ~trigger:(Compaction_trigger.Provider_overflow { limit_tokens = None })
   with
   | Error (Post_turn.Retry_suspended { consecutive_failures }) ->
     check int "refusal reports the persisted streak" 3 consecutive_failures
   | Error error ->
     failf
       "suspended reactive prepare reached I/O instead of the admission gate: \
        %s"
       (Post_turn.compaction_recovery_error_to_string error)
   | Ok _ -> fail "suspended reactive prepare produced a prepared compaction");
  (match prepare ~streak:3 ~trigger:Compaction_trigger.Manual with
   | Error
       (Post_turn.Checkpoint_ref_load_failed Masc.Keeper_checkpoint_store.Ref_not_found)
     ->
     (* Reached the checkpoint load: the operator lever bypasses the gate. *)
     ()
   | Error error ->
     failf
       "suspended manual prepare did not reach the checkpoint load: %s"
       (Post_turn.compaction_recovery_error_to_string error)
   | Ok _ -> fail "manual prepare on an empty store produced a compaction");
  (match
     prepare
       ~streak:2
       ~trigger:(Compaction_trigger.Provider_overflow { limit_tokens = None })
   with
   | Error
       (Post_turn.Checkpoint_ref_load_failed Masc.Keeper_checkpoint_store.Ref_not_found)
     ->
     (* Below the threshold the reactive path is admitted unchanged. *)
     ()
   | Error error ->
     failf
       "below-threshold reactive prepare did not reach the checkpoint load: %s"
       (Post_turn.compaction_recovery_error_to_string error)
   | Ok _ -> fail "reactive prepare on an empty store produced a compaction");
  (* The byte axis follows the same gate as the token axis, not the operator lever.
     Both are raised by the turn path itself, so a suspended keeper must refuse both —
     the compiler forced that decision when the variant was added (masc#25739) but
     nothing pinned the answer, and the two plausible wrong answers are opposites:
     treating it like Manual would let a failing keeper re-enter compaction every turn,
     while refusing it below the threshold would deny a reduction the token axis is
     granted. *)
  let byte_over_capacity =
    Compaction_trigger.Request_body_over_capacity
      { actual_bytes = 2_000_000; limit_bytes = 1_048_576 }
  in
  (match prepare ~streak:3 ~trigger:byte_over_capacity with
   | Error (Post_turn.Retry_suspended { consecutive_failures }) ->
     check int "suspended byte-axis refusal reports the streak" 3 consecutive_failures
   | Error error ->
     failf
       "suspended byte-axis prepare reached I/O instead of the admission gate: %s"
       (Post_turn.compaction_recovery_error_to_string error)
   | Ok _ -> fail "suspended byte-axis prepare produced a prepared compaction");
  (match prepare ~streak:2 ~trigger:byte_over_capacity with
   | Error
       (Post_turn.Checkpoint_ref_load_failed Masc.Keeper_checkpoint_store.Ref_not_found)
     ->
     (* Below the threshold the byte axis is admitted exactly as the token axis is. *)
     ()
   | Error error ->
     failf
       "below-threshold byte-axis prepare did not reach the checkpoint load: %s"
       (Post_turn.compaction_recovery_error_to_string error)
   | Ok _ -> fail "byte-axis prepare on an empty store produced a compaction");
  List.iter
    (fun (reason, trigger) ->
       (match prepare ~streak:3 ~trigger with
        | Error (Post_turn.Retry_suspended { consecutive_failures }) ->
          check
            int
            ("suspended serving-axis " ^ reason ^ " reports the streak")
            3
            consecutive_failures
        | Error error ->
          failf
            "suspended serving-axis %s reached I/O instead of the admission gate: %s"
            reason
            (Post_turn.compaction_recovery_error_to_string error)
        | Ok _ ->
          failf "suspended serving-axis %s produced a prepared compaction" reason);
       match prepare ~streak:2 ~trigger with
       | Error
           (Post_turn.Checkpoint_ref_load_failed
              Masc.Keeper_checkpoint_store.Ref_not_found) ->
         ()
       | Error error ->
         failf
           "below-threshold serving-axis %s did not reach the checkpoint load: %s"
           reason
           (Post_turn.compaction_recovery_error_to_string error)
       | Ok _ ->
         failf
           "serving-axis %s prepare on an empty store produced a compaction"
           reason)
    [ ( "boundary_unknown"
      , Compaction_trigger.Serving_input_capacity
          (Compaction_trigger.Boundary_unknown
             { input_tokens = 524_299
             ; accepted_through = 524_298
             ; rejected_from = Some 524_300
             }) )
    ; ( "input_rejected"
      , Compaction_trigger.Serving_input_capacity
          (Compaction_trigger.Input_rejected
             { input_tokens = 524_300
             ; accepted_through = 524_298
             ; rejected_from = 524_299
             }) )
    ]
;;

(* Step 0 characterization — the compaction suspension gate is self-feeding.

   [test_suspended_streak_refuses_reactive_prepare] above pins the first hop: at
   [Keeper_meta_contract.compaction_retry_escalation_threshold] the reactive
   prepare is refused before any I/O. This test pins the two hops that close the
   loop — the refusal settles as a compaction failure, and that settlement
   advances the very counter the gate reads.

   Live evidence for the loop: keeper [kidsnote] reached
   compaction_consecutive_failures=907 against a threshold of 3
   (.masc/logs/system_log_2026-07-29.jsonl), so roughly 99.7% of that counter's
   value came from refusals that never attempted a compaction. While the counter
   is inflated this way, no statistic can say what actually drove the keeper to
   the threshold.

   The gate, the threshold, and the LLM-call bound it exists for are unchanged;
   only the self-feeding edge is cut. The second half of this test pins that a
   real compaction failure still advances the streak, so the ceiling that
   #25461 added keeps working. *)
let test_refusal_does_not_settle_as_compaction_failure () =
  Eio_main.run @@ fun _env ->
  let meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
          [ "name", `String "suspension-settlement"
          ; "trace_id", `String "trace-suspension-settlement"
          ; "compaction_consecutive_failures", `Int 3
          ])
    with
    | Ok meta -> meta
    | Error detail -> failf "suspension-settlement meta fixture: %s" detail
  in
  check
    bool
    "fixture sits at the suspension threshold"
    true
    (Masc.Keeper_meta_contract.compaction_retry_suspended
       meta.runtime.compaction_rt);
  (* A refused prepare attempted no compaction, so it settles as nothing. *)
  let turn_failure_with source_disposition : Masc.Keeper_unified_turn.turn_failure =
    { error = Agent_sdk.Error.Internal "suspended reactive prepare"
    ; runtime_id = "suspension-characterization"
    ; route =
        Keeper_runtime_failure_route.Retry_after_observed
          { retry_class = Keeper_runtime_failure_route.Rate_limited
          ; retry_after = None
          }
    ; source_disposition
    ; deferred_runtime_lane = None
    }
  in
  let settle source_disposition =
    Masc.Keeper_heartbeat_loop.compaction_outcome_of_cycle_outcome
      (Some (Cycle.Failed { meta; failure = turn_failure_with source_disposition }))
  in
  check
    bool
    "a refusal that attempted no compaction settles as nothing"
    true
    (settle
       (Masc.Keeper_unified_turn.Requeue_after_context_compaction
          (Masc.Keeper_unified_turn.Compaction_refused_without_attempt
             { consecutive_failures = 3 }))
     = None);
  (* The ceiling #25461 added still works: a compaction that ran and made no
     durable progress still advances the streak. *)
  check
    bool
    "an attempted compaction that made no progress still settles as a failure"
    true
    (settle
       (Masc.Keeper_unified_turn.Requeue_after_context_compaction
          (Masc.Keeper_unified_turn.Compaction_attempt_failed
             { reason = "checkpoint candidate rejected" }))
     = Some `Failed);
  (* And that settlement is what advances the counter the gate reads. *)
  let base =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-suspension-settlement-%d" (Unix.getpid ()))
  in
  let config = Masc.Workspace.default_config base in
  (match Masc.Keeper_meta_store.write_meta config meta with
   | Ok () -> ()
   | Error detail -> failf "durable meta write: %s" detail);
  (match
     Masc.Keeper_meta_store.persist_compaction_outcome
       config
       ~keeper_name:meta.name
       ~outcome:`Failed
   with
   | Ok `Persisted -> ()
   | Ok `No_durable_meta -> fail "settlement found no durable meta to advance"
   | Error detail -> failf "settlement persist: %s" detail);
  match Masc.Keeper_meta_store.read_meta config meta.name with
  | Error detail -> failf "durable meta read-back: %s" detail
  | Ok None -> fail "durable meta vanished after settlement"
  | Ok (Some settled) ->
    check
      int
      "an attempted-and-failed compaction advances the streak"
      4
      settled.runtime.compaction_rt.consecutive_failures;
    check
      bool
      "and that is what keeps the keeper suspended"
      true
      (Masc.Keeper_meta_contract.compaction_retry_suspended
         settled.runtime.compaction_rt)
;;

let () =
  run "post-turn durability" [
    "durable compaction", [
      test_case "compaction rejection tag is stable"
        `Quick test_compaction_rejection_tag_is_stable;
      test_case
        "final-admission Busy distinguishes pre-dispatch from exact terminal"
        `Quick test_final_admission_busy_requeues_only_pre_dispatch_no_compaction;
      test_case
        "exact no-compaction acknowledges without persistence facade"
        `Quick
        test_exact_no_compaction_acknowledges_without_persistence_facade;
      test_case "regular post-turn does not auto-compact"
        `Quick test_regular_post_turn_does_not_auto_compact;
      test_case
        "atomic cycle and normalization cross evidence gate"
        `Quick
        test_atomic_cycle_and_normalization_cross_evidence_gate;
      test_case "checkpoint installation auxiliary manifest tags"
        `Quick test_checkpoint_installation_auxiliary_manifest_tags;
      test_case "malformed structure preserves checkpoint"
        `Quick test_malformed_structure_preserves_checkpoint;
      test_case "prepare/commit source CAS"
        `Quick test_prepare_commit_source_cas;
      test_case "post-install Domain_valid error resolves waiters"
        `Quick test_post_install_domain_valid_error_resolves_waiters;
      test_case "post-install Domain_valid exception resolves waiters"
        `Quick test_post_install_domain_valid_exception_resolves_waiters;
      test_case "post-install cancellation returns committed failure"
        `Quick test_post_install_cancellation_returns_committed_failure;
      test_case "ephemeral plan accounting mismatch is post-dispatch terminal"
        `Quick test_invalid_structural_evidence_after_dispatch_is_terminal;
      test_case "non-reducing output is terminal"
        `Quick test_post_dispatch_non_reducing_output_is_terminal;
      test_case "suspended streak refuses reactive prepare"
        `Quick test_suspended_streak_refuses_reactive_prepare;
      test_case "refusal does not settle as a compaction failure"
        `Quick test_refusal_does_not_settle_as_compaction_failure;
      test_case "missing exact lane is source-bound no-compaction"
        `Quick test_missing_exact_lane_is_source_bound_no_compaction;
    ];
  ]
