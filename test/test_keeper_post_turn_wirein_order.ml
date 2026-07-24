(** Behavioral post-turn durability and compaction tests. *)

open Alcotest

module Compact_policy = Masc.Keeper_compact_policy
module Post_turn = Masc.Keeper_post_turn
module Admission = Masc.Keeper_turn_admission
module Cycle = Masc.Keeper_heartbeat_loop_cycle
module Queue = Keeper_event_queue
module Registry_queue = Masc.Keeper_registry_event_queue
module WO = Masc.Keeper_world_observation
module Projection_target = Masc.Keeper_compaction_projection_target
module Exact_fixture = Compaction_exact_output_fixture
module Schema = Masc.Keeper_structured_output_schema
module Summarizer = Masc.Keeper_compaction_llm_summarizer

let exact_terminal ?(slot_id = "compaction-slot") ?(call_id = "call-compaction") cause =
  Keeper_event_queue_state.
    { cause
    ; slot_id
    ; call_id
    ; plan_fingerprint = "compaction-plan"
    ; request_body_sha256 = String.make 64 'c'
    }
;;

let compaction_decision ?summary unit_index action =
  `Assoc
    [ Schema.compaction_plan_field_unit_index, `Int unit_index
    ; Schema.compaction_plan_field_action, `String action
    ; ( Schema.compaction_plan_field_summary
      , Option.fold ~none:`Null ~some:(fun value -> `String value) summary )
    ]
;;

let exact_response decisions =
  Exact_fixture.openai_response
    (`Assoc [ Schema.compaction_plan_field_decisions, `List decisions ])
;;

let summarize_response summary =
  exact_response
    [ compaction_decision
        ~summary
        1
        Schema.compaction_plan_action_summarize
    ]
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
         , exact_terminal Keeper_event_queue_state.Invalid_structural_evidence ))
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
    (preserves Keeper_event_queue_state.No_eligible_history);
  check
    bool
    "post-dispatch exact terminal remains source-bound after final admission Busy"
    true
    (preserves
       (Keeper_event_queue_state.Exact_execution_terminal
          (exact_terminal Keeper_event_queue_state.Exact_execution_failed)))
;;

let test_empty_projection_target_is_typed () =
  let resolver_called = ref false in
  let evidence =
    Projection_target.request
      ~assignment_id:""
      ~resolve_context_window:(fun _ ->
        resolver_called := true;
        Projection_target.Resolved_context_window 1)
    |> Projection_target.capture
    |> Projection_target.captured_evidence
  in
  check bool "empty assignment skips runtime resolution" false !resolver_called;
  match evidence with
  | Projection_target.Unavailable Projection_target.Empty_assignment -> ()
  | Projection_target.Exact _ | Projection_target.Unavailable _ ->
    fail "empty assignment was not retained as typed unavailable evidence"
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

let projection_request_of_meta
      (meta : Masc.Keeper_meta_contract.keeper_meta)
  =
  Projection_target.request
    ~assignment_id:(Masc.Keeper_meta_contract.runtime_id_of_meta meta)
    ~resolve_context_window:(fun runtime ->
      match
        Masc.Keeper_context_runtime.resolve_max_context_resolution_for_runtime
          ~requested_override:meta.max_context_override
          runtime
      with
      | Ok resolution ->
        Projection_target.Resolved_context_window resolution.effective_budget
      | Error (Invalid_requested_context_override value) ->
        Projection_target.Invalid_context_window value
      | Error (Runtime_context_window_unavailable _) ->
        Projection_target.Context_window_not_resolved)
;;

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
  with_eio_context env sw @@ fun () ->
  let base_path = Masc_test_deps.setup_test_workspace () in
  let meta = make_meta ~name:"compaction-owner" ~trace_id:"trace-compaction-owner" () in
  let peer = make_meta ~name:"compaction-peer" ~trace_id:"trace-compaction-peer" () in
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () ->
      Runtime.For_testing.restore runtime_snapshot;
      Admission.For_testing.reset ();
      Masc.Keeper_registry.For_testing.unregister ~base_path meta.name;
      Masc.Keeper_registry.For_testing.unregister ~base_path peer.name;
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
          (Exact_fixture.Reply
             (summarize_response "owner-lane compacted context"))
      in
      publish_exact_fixture
        ~source:"post-turn owner-lane compaction"
        exact_server;
      Result.get_ok (Masc.Keeper_meta_store.write_meta config meta);
      let owner_entry = Masc.Keeper_registry.For_testing.register ~base_path meta.name meta in
      let peer_entry = Masc.Keeper_registry.For_testing.register ~base_path peer.name peer in
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
            ~generation:meta.runtime.nonce
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
      let exact_execution_guard =
        Masc.Keeper_heartbeat_loop.For_testing.exact_execution_guard
          ~base_path
          ~keeper_name:meta.name
          ~lease
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
          ~exact_execution_guard
          ()
      in
      let busy_outcome = run_cycle () in
      (match busy_outcome with
       | Cycle.Busy _ -> ()
       | _ -> fail "manual compaction crossed an active owner turn slot");
      (match
         Masc.Keeper_heartbeat_loop.settlement_of_cycle_outcome
           ~base_path
           ~settled_at:(Time_compat.now ())
           ~stop_requested:false
           ~compaction_consecutive_failures:
             meta.runtime.compaction_rt.consecutive_failures
           ~lease
           (Some busy_outcome)
       with
       | Registry_queue.Requeue Registry_queue.Cycle_busy -> ()
       | _ -> fail "effect-free preflight Busy did not remain safely requeueable");
      check int
        "busy owner lane performs no exact dispatch"
        0
        (Exact_fixture.post_count exact_server);
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
      let outcome = run_cycle () in
      (match outcome with
       | Cycle.Manual_compaction_applied _ -> ()
       | _ -> fail "owner-lane cycle did not apply manual compaction");
      check int
        "manual compaction crosses the real exact-output dispatch once"
        1
        (Exact_fixture.post_count exact_server);
      let eligible_units = eligible_units_of_only_request exact_server in
      check int "only one closed eligible unit reaches the LLM" 1
        (List.length eligible_units);
      check int "eligible Assistant unit keeps its source index" 1
        Yojson.Safe.Util.(List.hd eligible_units |> member "unit_index" |> to_int);
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
      check bool "manifest retains nonblank OAS call id" true
        Yojson.Safe.Util.(evidence |> member "call_id" |> to_string |> String.trim |> fun value -> value <> "");
      check bool "manifest retains nonblank exact slot id" true
        Yojson.Safe.Util.(evidence |> member "slot_id" |> to_string |> String.trim |> fun value -> value <> "");
      let applied_settlement =
        Masc.Keeper_heartbeat_loop.settlement_of_cycle_outcome
          ~base_path
          ~settled_at:(Time_compat.now ())
          ~stop_requested:false
          ~compaction_consecutive_failures:
            meta.runtime.compaction_rt.consecutive_failures
          ~lease
          (Some outcome)
      in
      (match
         Masc.Keeper_heartbeat_loop.For_testing.settle_claimed_lease_exact
           ~after_exact_disposition_prepare:(fun () -> ())
           ~base_path
           ~keeper_name:meta.name
           ~settled_at:(Time_compat.now ())
           ~lease
           ~settlement:applied_settlement
           ()
       with
       | Ok
           ( Registry_queue.Settled _
           | Registry_queue.Already_settled _ ) ->
         (match
            Masc.Keeper_reaction_ledger.project_event_queue_transition_outbox_result
              ~base_path
              ~keeper_name:meta.name
          with
          | Ok () -> ()
          | Error detail ->
            failf "applied compaction ledger projection failed: %s" detail)
       | Ok (Registry_queue.Committed_followup_failed { detail; _ }) ->
         failf "applied compaction follow-up failed: %s" detail
       | Error detail ->
         failf "applied compaction settlement failed: %s" detail);
      let concurrent_checkpoint =
        { compacted with
          messages =
            [ Agent_sdk.Types.text_message
                Agent_sdk.Types.User
                "concurrent checkpoint source"
            ]
        }
      in
      let stale_server =
        Exact_fixture.start_server
          ~on_request_before_reply:(fun () ->
            match
              Masc.Keeper_checkpoint_store.save_oas_classified
                ~session_dir:session.session_dir
                concurrent_checkpoint
            with
            | Ok (Masc.Keeper_checkpoint_store.Saved _) -> ()
            | Ok (Stale_noop _) ->
              fail "concurrent equal-turn checkpoint save was stale"
            | Error detail ->
              failf "concurrent checkpoint save failed: %s" detail)
          ~sw
          ~net:(Eio.Stdenv.net env)
          ~clock:(Eio.Stdenv.clock env)
          (Exact_fixture.Reply (summarize_response "stale plan must not commit"))
      in
      publish_exact_fixture
        ~source:"post-turn stale-source CAS"
        stale_server;
      let stale_plan_result =
        Post_turn.recover_latest_checkpoint_for_compaction
          ~base_dir:(Masc.Keeper_types_profile.session_base_dir config)
          ~meta
          ~trigger:Compaction_trigger.Manual
          ~exact_execution_guard:Exact_fixture.permissive_exact_execution_guard
          ~projection_request:(projection_request_of_meta meta)
          ()
      in
      check int
        "stale-source plan performs one real exact dispatch"
        1
        (Exact_fixture.post_count stale_server);
      (match stale_plan_result with
       | Error
           (Post_turn.No_compaction
              { reason =
                  Keeper_event_queue_state.Exact_execution_terminal
                    { cause = Keeper_event_queue_state.Checkpoint_source_changed
                    ; slot_id
                    ; call_id
                    }
              ; _
              }) ->
         check bool "stale terminal retains slot id" true (String.trim slot_id <> "");
         check bool "stale terminal retains call id" true (String.trim call_id <> "")
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
      let race_checkpoint =
        { (make_checkpoint ()) with
          session_id = checkpoint.session_id
        ; agent_name = meta.agent_name
        ; turn_count = retained_concurrent_checkpoint.turn_count + 1
        }
      in
      (match
         Masc.Keeper_context_core.save_oas_checkpoint_classified
           ~multimodal_policy:meta.multimodal_policy
           ~keeper_name:meta.name
           ~session
           ~agent_name:meta.agent_name
           ~ctx:(Masc.Keeper_context_core.context_of_oas_checkpoint race_checkpoint)
           ~generation:meta.runtime.nonce
       with
       | Ok (_, Masc.Keeper_checkpoint_store.Saved _) -> ()
       | Ok (_, Stale_noop _) -> fail "race fixture checkpoint save was stale"
       | Error detail ->
         failf
           "race fixture checkpoint save failed: %s"
           (Masc.Keeper_context_core.checkpoint_write_error_to_string
              ~persistence_error_to_string:Fun.id
              detail));
      let commit_block_held, commit_block_held_u = Eio.Promise.create () in
      let commit_block_release, commit_block_release_u = Eio.Promise.create () in
      let commit_block_finished, commit_block_finished_u = Eio.Promise.create () in
      let race_server =
        Exact_fixture.start_server
          ~on_request_before_reply:(fun () ->
            Eio.Fiber.fork ~sw (fun () ->
              let result =
                Admission.run_serialized
                  ~base_path
                  ~keeper_name:meta.name
                  (fun () ->
                    Eio.Promise.resolve commit_block_held_u ();
                    Eio.Promise.await commit_block_release)
              in
              Eio.Promise.resolve commit_block_finished_u result);
            Eio.Promise.await commit_block_held)
          ~sw
          ~net:(Eio.Stdenv.net env)
          ~clock:(Eio.Stdenv.clock env)
          (Exact_fixture.Reply
             (summarize_response
                "prepared while another turn acquires the slot"))
      in
      publish_exact_fixture
        ~source:"post-turn planning-admission race"
        race_server;
      let race_stimulus : Queue.stimulus =
        { post_id = "manual-compaction-race"
        ; urgency = Immediate
        ; arrived_at = Time_compat.now ()
        ; payload = Manual_compaction_requested
        }
      in
      Result.get_ok
        (Registry_queue.enqueue_durable_result
           ~base_path
           meta.name
           race_stimulus);
      check int
        "race stimulus is durably pending"
        1
        (Keeper_event_queue_persistence.load_pending_result
           ~base_path
           ~keeper_name:meta.name
         |> Result.get_ok
         |> Queue.length);
      (match Registry_queue.active_lease_result ~base_path meta.name with
       | Ok None -> ()
       | Ok (Some _) -> fail "applied compaction left its source lease active"
       | Error detail -> failf "active lease read failed: %s" detail);
      let race_lease =
        match
          Registry_queue.claim_when_result
            ~base_path
            meta.name
            ~claimed_at:(Time_compat.now ())
            ~ready:(fun stimulus ->
              match stimulus.Queue.payload with
              | Manual_compaction_requested -> true
              | _ -> false)
        with
        | Ok (Some lease) -> lease
        | Ok None -> fail "race manual compaction request was not claimed"
        | Error detail ->
          failf "race manual compaction claim failed: %s" detail
      in
      let busy_after_prepare =
        Masc.Keeper_manual_compaction.run_admitted
          ~config
          ~meta
          ~exact_execution_guard:
            (Masc.Keeper_heartbeat_loop.For_testing.exact_execution_guard
               ~base_path
               ~keeper_name:meta.name
               ~lease:race_lease)
          ()
      in
      check int
        "planning-admission race performs one exact dispatch"
        1
        (Exact_fixture.post_count race_server);
      let no_compaction =
        match busy_after_prepare with
        | `No_compaction
            ({ reason =
                 Keeper_event_queue_state.Exact_execution_terminal
                   { cause = Keeper_event_queue_state.Commit_admission_unavailable
                   ; slot_id
                   ; call_id
                   }
             ; _
             } as no_compaction) ->
          check bool "busy terminal retains slot id" true (String.trim slot_id <> "");
          check bool "busy terminal retains call id" true (String.trim call_id <> "");
          no_compaction
        | `Busy _ ->
          fail "post-dispatch final admission collapsed to replayable Busy"
        | `Applied _ | `No_compaction _ | `Compaction_failed _ ->
          fail "post-dispatch final admission lost its typed terminal receipt fence"
      in
      (match Masc.Keeper_registry.get ~base_path meta.name with
       | Some entry ->
         check bool
           "busy commit admission never activates compaction lifecycle"
           false
           entry.conditions.compaction_active
       | None -> fail "owner registry entry disappeared after busy commit admission");
      Eio.Promise.resolve commit_block_release_u ();
      (match Eio.Promise.await commit_block_finished with
       | `Ran () -> ()
       | `Rejected _ -> fail "race fixture owner turn was rejected");
      let settlement =
        Masc.Keeper_heartbeat_loop.settlement_of_cycle_outcome
          ~base_path
          ~settled_at:(Time_compat.now ())
          ~stop_requested:false
          ~compaction_consecutive_failures:
            meta.runtime.compaction_rt.consecutive_failures
          ~lease:race_lease
          (Some
             (Cycle.Manual_compaction_not_applied
                { meta; no_compaction }))
      in
      (match settlement with
       | Registry_queue.No_compaction
           { reason =
               Keeper_event_queue_state.Exact_execution_terminal
                 { cause = Keeper_event_queue_state.Commit_admission_unavailable
                 ; _
                 }
           ; _
           } ->
         ()
       | Registry_queue.Requeue _ ->
         fail "post-dispatch final admission remained replayable"
       | Registry_queue.No_compaction _ ->
         fail "post-dispatch final admission changed its terminal cause"
       | Registry_queue.Ack
       | Registry_queue.Cancel_accepted _
       | Registry_queue.Transfer_accepted _
       | Registry_queue.Settle_from_source_terminal _
       | Registry_queue.Settle_exact _
       | Registry_queue.Escalate _ ->
         fail "post-dispatch final admission lost source-bound terminal evidence");
      (match
         Masc.Keeper_heartbeat_loop.For_testing.settle_claimed_lease_exact
           ~after_exact_disposition_prepare:(fun () -> ())
           ~base_path
           ~keeper_name:meta.name
           ~settled_at:(Time_compat.now ())
           ~lease:race_lease
           ~settlement
           ()
       with
       | Ok
           ( Registry_queue.Settled _
           | Registry_queue.Already_settled _ ) ->
         (match
            Masc.Keeper_reaction_ledger.project_event_queue_transition_outbox_result
              ~base_path
              ~keeper_name:meta.name
          with
          | Ok () -> ()
          | Error detail ->
            failf "post-dispatch terminal ledger projection failed: %s" detail)
       | Ok (Registry_queue.Committed_followup_failed { detail; _ }) ->
         failf "post-dispatch terminal follow-up failed: %s" detail
       | Error detail ->
         failf "post-dispatch terminal settlement failed: %s" detail);
      let next_intake =
        Masc.Keeper_heartbeat_loop.heartbeat_event_intake
          ~ctx
          ~meta_after_triage:meta
          ~pending_board_events:[]
      in
      (match next_intake.claimed_lease, next_intake.consumed_stimuli with
       | None, [] -> ()
       | _ -> fail "terminal post-dispatch compaction stimulus re-entered the lane");
      check int
        "terminal post-dispatch settlement never repeats exact dispatch"
        1
        (Exact_fixture.post_count race_server))
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
       match
         Post_turn.prepare_compaction
           ~base_dir:(Masc.Keeper_types_profile.session_base_dir config)
           ~meta
           ~trigger:Compaction_trigger.Manual
           ~projection_request:(projection_request_of_meta meta)
           ()
       with
       | Error
           (Post_turn.No_compaction
              { source
              ; reason = Keeper_event_queue_state.Exact_lane_unconfigured
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
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore runtime_snapshot)
    (fun () ->
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
  let preparation =
    Compact_policy.compact_for_request_typed
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

let test_prepare_commit_source_cas () =
  (* The prepare/commit split exists so the provider call can run outside
     the keeper admission; the source CAS — not the slot — is the
     interleaving guard.  Pin both halves: a prepared plan commits, and
     the same prepared value is rejected once the source has advanced. *)
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
  match
    Post_turn.prepare_compaction
      ~base_dir:(Masc.Keeper_types_profile.session_base_dir config)
      ~meta
      ~trigger:Compaction_trigger.Manual
      ~exact_execution_guard:Exact_fixture.permissive_exact_execution_guard
      ~projection_request:(projection_request_of_meta meta)
      ()
  with
  | Error error ->
    failf
      "prepare failed: %s"
      (Post_turn.compaction_recovery_error_to_string error)
  | Ok prepared ->
    check int
      "prepare performs one real exact dispatch"
      1
      (Exact_fixture.post_count exact_server);
    (match Post_turn.commit_prepared_compaction prepared with
     | Ok _ -> ()
     | Error error ->
       failf
         "commit of a fresh prepared plan failed: %s"
         (Post_turn.compaction_recovery_error_to_string error));
    (* The first commit advanced the durable source; the same
       prepared value is now stale and must be CAS-rejected. *)
    (match Post_turn.commit_prepared_compaction prepared with
     | Error
         (Post_turn.No_compaction
            { reason =
                Keeper_event_queue_state.Exact_execution_terminal
                  { cause = Keeper_event_queue_state.Checkpoint_source_changed
                  ; slot_id
                  ; call_id
                  }
            ; _
            }) ->
       check bool "stale prepared terminal retains slot" true (String.trim slot_id <> "");
       check bool "stale prepared terminal retains call" true (String.trim call_id <> "")
     | Error error ->
       failf
         "stale prepared value failed with the wrong error: %s"
         (Post_turn.compaction_recovery_error_to_string error)
     | Ok _ -> fail "stale prepared value committed past the source CAS"))
;;

let test_invalid_structural_evidence_after_dispatch_is_terminal () =
  Eio_main.run @@ fun env ->
  Masc_test_deps.init_eio_clock env;
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  with_eio_context env sw @@ fun () ->
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore runtime_snapshot)
    (fun () ->
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
      let context =
        make_checkpoint () |> Masc.Keeper_context_core.context_of_oas_checkpoint
      in
      let quarantine_calls = ref [] in
      let exact_execution_guard : Summarizer.exact_execution_guard =
        { Exact_fixture.permissive_exact_execution_guard with
          quarantine =
            (fun cause observation ->
               quarantine_calls := (cause, observation) :: !quarantine_calls;
               Ok Summarizer.Fsync_completed)
        }
      in
      let plan_for_units ~units =
        match
          Summarizer.make
            ~exact_execution_guard
            ~keeper_name:meta.name
            ()
        with
        | None -> Error Summarizer.Exact_execution_context_unavailable
        | Some summarize -> summarize ~units
      in
      let preparation =
        Compact_policy.For_testing.compact_for_request_typed_with_accounting
          ~plan_for_units
          ~summarized_message_count_override:(-1)
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
               ( Keeper_compaction_evidence.Invalid_field
                   (Keeper_compaction_evidence.Summarized_message_count, Negative_integer)
               , { cause = Keeper_event_queue_state.Invalid_structural_evidence
                 ; slot_id
                 ; call_id
                 } ) ) ->
         check bool "invalid evidence terminal retains slot" true
           (String.trim slot_id <> "");
         check bool "invalid evidence terminal retains call" true
           (String.trim call_id <> "")
       | _ -> fail "post-dispatch invalid evidence was not a typed terminal");
      match !quarantine_calls with
      | [ Keeper_event_queue_state.Invalid_structural_evidence, observation ] ->
        check bool "invalid evidence quarantine retains slot" true
          (String.trim observation.slot_id <> "");
        check bool "invalid evidence quarantine retains call" true
          (String.trim observation.call_id <> "")
      | _ -> fail "invalid evidence terminal was not quarantined exactly once")
;;

let test_post_dispatch_non_reducing_output_is_quarantined () =
  Eio_main.run @@ fun env ->
  Masc_test_deps.init_eio_clock env;
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  with_eio_context env sw @@ fun () ->
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore runtime_snapshot)
    (fun () ->
      init_runtime_fixture ();
      let run_case ~name response =
        let server =
          Exact_fixture.start_server
            ~sw
            ~net:(Eio.Stdenv.net env)
            ~clock:(Eio.Stdenv.clock env)
            (Exact_fixture.Reply response)
        in
        publish_exact_fixture ~source:name server;
        let quarantine_calls = ref [] in
        let exact_execution_guard : Summarizer.exact_execution_guard =
          { Exact_fixture.permissive_exact_execution_guard with
            quarantine =
              (fun cause observation ->
                 quarantine_calls := (cause, observation) :: !quarantine_calls;
                 Ok Summarizer.Fsync_completed)
          }
        in
        let preparation =
          Compact_policy.compact_for_request_typed
            ~exact_execution_guard
            ~meta:(make_meta ~name ())
            ~trigger:Compaction_trigger.Manual
            (make_checkpoint ()
             |> Masc.Keeper_context_core.context_of_oas_checkpoint)
        in
        check int (name ^ " performs one POST") 1 (Exact_fixture.post_count server);
        (match preparation.decision with
         | Compact_policy.Rejected
             ( Manual
             , Exact_execution_terminal
                 { cause = Keeper_event_queue_state.Domain_invalid_output
                 ; slot_id
                 ; call_id
                 } ) ->
           check bool (name ^ " terminal retains slot") true
             (String.trim slot_id <> "");
           check bool (name ^ " terminal retains call") true
             (String.trim call_id <> "")
         | _ -> fail (name ^ " was not a domain-invalid exact terminal"));
        match !quarantine_calls with
        | [ Keeper_event_queue_state.Domain_invalid_output, observation ] ->
          check bool (name ^ " quarantine retains slot") true
            (String.trim observation.slot_id <> "");
          check bool (name ^ " quarantine retains call") true
            (String.trim observation.call_id <> "")
        | _ -> fail (name ^ " was not quarantined exactly once")
      in
      run_case
        ~name:"unchanged-plan"
        (exact_response
           [ compaction_decision 1 Schema.compaction_plan_action_keep ]);
      run_case
        ~name:"larger-checkpoint"
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
  let projection_request =
    Projection_target.request
      ~assignment_id:""
      ~resolve_context_window:(fun _ ->
        Projection_target.Resolved_context_window 1)
  in
  let prepare ~streak ~trigger =
    Post_turn.prepare_compaction
      ~base_dir
      ~meta:(meta_with_streak streak)
      ~trigger
      ~projection_request
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
  match
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
  | Ok _ -> fail "reactive prepare on an empty store produced a compaction"
;;

let () =
  run "post-turn durability" [
    "durable compaction", [
      test_case "compaction rejection tag is stable"
        `Quick test_compaction_rejection_tag_is_stable;
      test_case
        "final-admission Busy distinguishes pre-dispatch from exact terminal"
        `Quick test_final_admission_busy_requeues_only_pre_dispatch_no_compaction;
      test_case "empty projection target is typed"
        `Quick test_empty_projection_target_is_typed;
      test_case "regular post-turn does not auto-compact"
        `Quick test_regular_post_turn_does_not_auto_compact;
      test_case "manual compaction serializes the owner lane"
        `Quick test_manual_compaction_serializes_owner_lane;
      test_case "malformed structure preserves checkpoint"
        `Quick test_malformed_structure_preserves_checkpoint;
      test_case "prepare/commit source CAS"
        `Quick test_prepare_commit_source_cas;
      test_case "invalid structural evidence is post-dispatch terminal"
        `Quick test_invalid_structural_evidence_after_dispatch_is_terminal;
      test_case "non-reducing output is quarantined"
        `Quick test_post_dispatch_non_reducing_output_is_quarantined;
      test_case "suspended streak refuses reactive prepare"
        `Quick test_suspended_streak_refuses_reactive_prepare;
      test_case "missing exact lane is source-bound no-compaction"
        `Quick test_missing_exact_lane_is_source_bound_no_compaction;
    ];
  ]
