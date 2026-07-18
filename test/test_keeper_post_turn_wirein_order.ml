(** Behavioral post-turn durability and compaction tests. *)

open Alcotest

module Compact_policy = Masc.Keeper_compact_policy
module Post_turn = Masc.Keeper_post_turn
module Admission = Masc.Keeper_turn_admission
module Cycle = Masc.Keeper_heartbeat_loop_cycle
module Queue = Keeper_event_queue
module Registry_queue = Masc.Keeper_registry_event_queue
module WO = Masc.Keeper_world_observation

let test_compaction_rejection_tag_is_stable () =
  let error =
    Post_turn.Compaction_rejected
      (Compact_policy.Invalid_structural_evidence
         Keeper_compaction_evidence.No_messages_compacted)
  in
  check string
    "categorical tag excludes evidence detail"
    "invalid_structural_evidence"
    (Post_turn.compaction_recovery_error_to_tag error);
  check string
    "diagnostic detail remains observable"
    "compaction rejected: invalid_structural_evidence:no_messages_compacted"
    (Post_turn.compaction_recovery_error_to_string error)

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

let test_manual_compaction_serializes_owner_lane () =
  Eio_main.run @@ fun env ->
  Masc_test_deps.init_eio_clock env;
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  let base_path = Masc_test_deps.setup_test_workspace () in
  let meta = make_meta ~name:"compaction-owner" ~trace_id:"trace-compaction-owner" () in
  let peer = make_meta ~name:"compaction-peer" ~trace_id:"trace-compaction-peer" () in
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () ->
      Runtime.For_testing.restore runtime_snapshot;
      Admission.For_testing.reset ();
      Masc.Keeper_registry.unregister ~base_path meta.name;
      Masc.Keeper_registry.unregister ~base_path peer.name;
      Masc_test_deps.cleanup_test_workspace base_path)
    (fun () ->
      let config = Masc.Workspace.default_config base_path in
      ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
      let runtime_path =
        Filename.concat (Masc_test_deps.find_project_root ()) "config/runtime.toml"
      in
      (match Runtime.init_default ~config_path:runtime_path with
       | Ok () -> ()
       | Error detail -> failf "runtime fixture initialization failed: %s" detail);
      Result.get_ok (Masc.Keeper_meta_store.write_meta config meta);
      let owner_entry = Masc.Keeper_registry.register ~base_path meta.name meta in
      let peer_entry = Masc.Keeper_registry.register ~base_path peer.name peer in
      Atomic.set owner_entry.fiber_wakeup false;
      Atomic.set peer_entry.fiber_wakeup false;
      let checkpoint =
        { (make_checkpoint ()) with session_id = "trace-compaction-owner"
        ; agent_name = meta.agent_name
        }
      in
      let closed_cycle =
        [ block_message Assistant [ tool_use "closed-a"; tool_use "closed-b" ]
        ; block_message User [ tool_result "closed-a" ]
        ; block_message Tool [ tool_result "closed-b" ]
        ]
      in
      let protected_suffix =
        [ block_message Assistant [ tool_use "open" ]
        ; Agent_sdk.Types.text_message Assistant "tool progress"
        ]
      in
      let session =
        Masc.Keeper_context_core.create_session
          ~session_id:checkpoint.session_id
          ~base_dir:(Masc.Keeper_types_profile.session_base_dir config)
      in
      let checkpoint =
        let context =
          Masc.Keeper_context_core.context_of_oas_checkpoint checkpoint
        in
        match
          Masc.Keeper_context_core.save_oas_checkpoint_classified
            ~multimodal_policy:meta.multimodal_policy
            ~keeper_name:meta.name
            ~session
            ~agent_name:meta.agent_name
            ~ctx:context
            ~generation:meta.runtime.generation
        with
        | Ok (checkpoint, Masc.Keeper_checkpoint_store.Saved _) -> checkpoint
        | Ok (_, Stale_noop _) -> fail "initial checkpoint save was stale"
        | Error error ->
          failf
            "initial checkpoint save failed: %s"
            (Masc.Keeper_context_core.checkpoint_write_error_to_string
               ~persistence_error_to_string:Fun.id
               error)
      in
      let ctx : _ Masc.Keeper_tool_surface.context =
        { config
        ; agent_name = "operator"
        ; sw
        ; clock = Eio.Stdenv.clock env
        ; proc_mgr = None
        ; net = None
        ; publication_recovery_provider =
            Masc_test_deps.non_runtime_publication_recovery_provider
        }
      in
      let held, held_u = Eio.Promise.create () in
      let release, release_u = Eio.Promise.create () in
      let finished, finished_u = Eio.Promise.create () in
      Eio.Fiber.fork ~sw (fun () ->
        let result =
          Admission.run_serialized ~base_path ~keeper_name:meta.name (fun () ->
            Eio.Promise.resolve held_u ();
            Eio.Promise.await release;
            let expanded =
              { checkpoint with
                turn_count = checkpoint.turn_count + 1
              ; messages =
                  checkpoint.messages
                  @ closed_cycle
                  @ protected_suffix
              }
            in
            Masc.Keeper_checkpoint_store.save_oas_classified
              ~session_dir:session.session_dir
              expanded
            |> Result.get_ok
            |> ignore)
        in
        Eio.Promise.resolve finished_u result);
      Eio.Promise.await held;
      let tool_result =
        Masc.Keeper_tool_surface.dispatch
          ctx
          ~name:"masc_keeper_compact"
          ~args:(`Assoc [ "name", `String meta.name ])
      in
      (match tool_result with
       | Some (Tool_result.Completed output) ->
         check string "request durably enqueued" "enqueued"
           Yojson.Safe.Util.(output.data |> member "queue_outcome" |> to_string)
       | Some (Tool_result.Deferred output) ->
         failf
           "compaction enqueue unexpectedly deferred: %s"
           (Yojson.Safe.to_string output.data)
       | Some (Tool_result.Failed failure) ->
         failf "compaction enqueue failed: %s" failure.message
       | None -> fail "masc_keeper_compact is not registered");
      check bool "owner wake set" true (Atomic.get owner_entry.fiber_wakeup);
      check bool "peer wake untouched" false (Atomic.get peer_entry.fiber_wakeup);
      let intake =
        Masc.Keeper_heartbeat_loop.heartbeat_event_intake
          ~ctx
          ~meta_after_triage:meta
          ~pending_board_events:[]
      in
      let lease =
        match intake.claimed_lease, intake.consumed_stimuli with
        | Some lease, [ { Queue.payload = Manual_compaction_requested; _ } ] -> lease
        | _ -> fail "manual compaction request was not the sole durable lease"
      in
      let obs =
        WO.observe
          ~pending_board_events:(Some intake.pending_board_events)
          ~config
          ~meta
      in
      let decision : WO.keeper_cycle_decision =
        { should_run = true
        ; channel = Reactive
        ; verdict = Run { reasons = Manual_compaction_pending, [] }
        ; since_last_scheduled_autonomous = None
        }
      in
      let run_cycle () =
        Cycle.run_keeper_cycle
          ~ctx
          ~meta_after_triage:meta
          ~stop:(Atomic.make false)
          ~obs
          ~turn_decision:decision
          ~shared_context:(Agent_sdk.Context.create_sync ())
          ~wake:(Masc.Keeper_registry.Woken [ Manual_compaction_requested ])
          ~manual_compaction_requested:true
          ()
      in
      (match run_cycle () with
       | Cycle.Busy _ -> ()
       | _ -> fail "manual compaction crossed an active owner turn slot");
      (match Admission.run_if_free ~base_path ~keeper_name:peer.name (fun () -> ()) with
       | `Ran () -> ()
       | `Busy _ -> fail "owner turn blocked an independent peer lane");
      check int "checkpoint unchanged while owner busy" 3
        (Result.get_ok
           (Masc.Keeper_checkpoint_store.load_oas
              ~session_dir:session.session_dir
              ~session_id:checkpoint.session_id)
         |> fun saved -> List.length saved.messages);
      Eio.Promise.resolve release_u ();
      (match Eio.Promise.await finished with
       | `Ran () -> ()
       | `Rejected _ -> fail "simulated owner turn was rejected");
      Atomic.set owner_entry.fiber_stop true;
      let outcome =
        Masc.Keeper_compaction_llm_summarizer.For_testing.with_make_override
          (fun ~runtime_ids:_ ~keeper_name:_ () ->
             Some (fun ~units ->
               check int "only closed units reach LLM" 4 (List.length units);
               check bool "parallel cycle is one decision unit" true
                 (match List.nth units 3 with
                  | Masc.Keeper_compaction_unit.Closed_tool_cycle messages ->
                    messages = closed_cycle
                  | Ordinary_message _ -> false);
               Masc.Keeper_compaction_llm_summarizer.plan_of_json
                 ~runtime_id:"test.compaction"
                 ~units
                 (`Assoc
                   [ ( Masc.Keeper_structured_output_schema.compaction_plan_field_decisions
                     , `List
                         [ `Assoc
                             [ ( Masc.Keeper_structured_output_schema.compaction_plan_field_unit_index
                               , `Int 1 )
                             ; ( Masc.Keeper_structured_output_schema.compaction_plan_field_action
                               , `String
                                   Masc.Keeper_structured_output_schema.compaction_plan_action_summarize
                               )
                             ; ( Masc.Keeper_structured_output_schema.compaction_plan_field_summary
                               , `String "owner-lane compacted context" )
                             ]
                         ] )
                   ])
               |> Result.to_option))
          run_cycle
      in
      (match outcome with
       | Cycle.Manual_compaction_applied _ -> ()
       | _ -> fail "owner-lane cycle did not apply manual compaction");
      let compacted =
        Result.get_ok
          (Masc.Keeper_checkpoint_store.load_oas
             ~session_dir:session.session_dir
             ~session_id:checkpoint.session_id)
      in
      check int "compacted checkpoint retains all protected messages" 8
        (List.length compacted.messages);
      check bool "open tool/progress suffix is exact" true
        (List.filteri (fun index _ -> index >= 6) compacted.messages = protected_suffix);
      let _, reinjectable =
        Masc.Keeper_context_runtime.load_context_from_checkpoint
          ~trace_id:checkpoint.session_id
          ~base_dir:(Masc.Keeper_types_profile.session_base_dir config)
      in
      check int "compacted checkpoint available to same-lane injection" 8
        (reinjectable
         |> Option.map Masc.Keeper_context_runtime.messages_of_context
         |> Option.value ~default:[]
         |> List.length);
      let manifest = only_compaction_manifest config meta in
      let evidence =
        Yojson.Safe.Util.(manifest.decision |> member "exact_evidence")
      in
      check int "manifest records post-turn source size" 8
        Yojson.Safe.Util.(evidence |> member "before_message_count" |> to_int);
      check int "manifest records protected compacted size" 8
        Yojson.Safe.Util.(evidence |> member "after_message_count" |> to_int);
      check int "manifest counts only eligible summarized messages" 1
        Yojson.Safe.Util.(evidence |> member "summarized_message_count" |> to_int);
      check int "manifest retains closed and open ToolUse blocks" 3
        Yojson.Safe.Util.(evidence |> member "after_tool_use_count" |> to_int);
      let concurrent_checkpoint =
        { compacted with
          messages =
            [ Agent_sdk.Types.text_message
                Agent_sdk.Types.User
                "concurrent checkpoint source"
            ]
        }
      in
      let stale_plan_result =
        Masc.Keeper_compaction_llm_summarizer.For_testing.with_make_override
          (fun ~runtime_ids:_ ~keeper_name:_ () ->
             Some (fun ~units ->
               (match
                  Masc.Keeper_checkpoint_store.save_oas_classified
                    ~session_dir:session.session_dir
                    concurrent_checkpoint
                with
                | Ok (Masc.Keeper_checkpoint_store.Saved _) -> ()
                | Ok (Stale_noop _) ->
                  fail "concurrent equal-turn checkpoint save was stale"
                | Error detail ->
                  failf "concurrent checkpoint save failed: %s" detail);
               Masc.Keeper_compaction_llm_summarizer.plan_of_json
                 ~runtime_id:"test.compaction"
                 ~units
                 (`Assoc
                   [ ( Masc.Keeper_structured_output_schema.compaction_plan_field_decisions
                     , `List
                         [ `Assoc
                             [ ( Masc.Keeper_structured_output_schema.compaction_plan_field_unit_index
                               , `Int 1 )
                             ; ( Masc.Keeper_structured_output_schema.compaction_plan_field_action
                               , `String
                                   Masc.Keeper_structured_output_schema.compaction_plan_action_summarize
                               )
                             ; ( Masc.Keeper_structured_output_schema.compaction_plan_field_summary
                               , `String "stale plan must not commit" )
                             ]
                         ] )
                   ])
               |> Result.to_option))
          (fun () ->
             Post_turn.recover_latest_checkpoint_for_compaction
               ~base_dir:(Masc.Keeper_types_profile.session_base_dir config)
               ~meta
               ~trigger:Compaction_trigger.Manual)
      in
      (match stale_plan_result with
       | Error
           (Post_turn.Checkpoint_cas_failed
              (Masc.Keeper_checkpoint_store.Source_changed _)) ->
         ()
       | Error error ->
         failf
           "stale plan returned wrong error: %s"
           (Post_turn.compaction_recovery_error_to_string error)
       | Ok _ -> fail "stale compaction plan replaced a concurrent checkpoint");
      let retained_concurrent_checkpoint =
        Masc.Keeper_checkpoint_store.load_oas
          ~session_dir:session.session_dir
          ~session_id:checkpoint.session_id
        |> Result.get_ok
      in
      check bool "CAS preserves concurrent checkpoint exactly" true
        (retained_concurrent_checkpoint.messages = concurrent_checkpoint.messages);
      Registry_queue.settle_result
        ~base_path
        meta.name
        ~settled_at:(Time_compat.now ())
        ~lease
        ~settlement:Ack
      |> Result.get_ok
      |> ignore)
;;

let test_malformed_structure_preserves_checkpoint () =
  Eio_main.run @@ fun _env ->
  let meta = make_meta ~name:"malformed-compaction" () in
  let orphan = block_message User [ tool_result "orphan" ] in
  let checkpoint = { (make_checkpoint ()) with messages = [ orphan ] } in
  let context =
    Masc.Keeper_context_core.context_of_oas_checkpoint checkpoint in
  let make_called = Atomic.make false in
  let preparation =
    Masc.Keeper_compaction_llm_summarizer.For_testing.with_make_override
      (fun ~runtime_ids:_ ~keeper_name:_ () ->
         Atomic.set make_called true;
         None)
      (fun () ->
         Compact_policy.compact_for_request_typed
           ~meta
           ~trigger:Compaction_trigger.Manual
           context)
  in
  check bool "malformed input never reaches LLM" false (Atomic.get make_called);
  check bool "original message remains exact" true
    (Masc.Keeper_context_core.messages_of_context preparation.context = [ orphan ]);
  match preparation.decision with
  | Compact_policy.Rejected
      ( Manual
      , Invalid_structure
          (Masc.Keeper_compaction_unit.Orphan_tool_result
            { message_index = 0; tool_use_id = "orphan" }) ) ->
    ()
  | _ -> fail "malformed compaction was not rejected with typed structure"
;;

let () =
  run "post-turn durability" [
    "durable compaction", [
      test_case "compaction rejection tag is stable"
        `Quick test_compaction_rejection_tag_is_stable;
      test_case "regular post-turn does not auto-compact"
        `Quick test_regular_post_turn_does_not_auto_compact;
      test_case "manual compaction serializes the owner lane"
        `Quick test_manual_compaction_serializes_owner_lane;
      test_case "malformed structure preserves checkpoint"
        `Quick test_malformed_structure_preserves_checkpoint;
    ];
  ]
