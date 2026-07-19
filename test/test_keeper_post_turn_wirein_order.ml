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

let test_invalid_plan_is_distinct_from_provider_unavailable () =
  (* This test asserts the typed distinction between a provider transport
     failure ([Plan_provider_unavailable]) and a closed-plan-contract violation
     ([Invalid_compaction_plan]). Both terminals live *after* the runtime-id
     gate in [Keeper_compact_policy.requested_messages]: with an uninitialized
     global Runtime, [compaction_runtime_ids] is [[]] and the decision short-
     circuits to [Runtime_identity_unavailable] before the summarizer override
     is ever consulted, so both branches under test would be dead. Building the
     working context also drives [Context.set_scoped], which requires an Eio
     fiber. So this test must run inside [Eio_main.run] with the same Runtime
     fixture the sibling [test_manual_compaction_serializes_owner_lane] uses. *)
  Eio_main.run @@ fun env ->
  Masc_test_deps.init_eio_clock env;
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore runtime_snapshot)
    (fun () ->
      let runtime_path =
        Filename.concat (Masc_test_deps.find_project_root ()) "config/runtime.toml"
      in
      (match Runtime.init_default ~config_path:runtime_path with
       | Ok () -> ()
       | Error detail -> failf "runtime fixture initialization failed: %s" detail);
      let meta = make_meta () in
      let context =
        Masc.Keeper_context_core.context_of_oas_checkpoint (make_checkpoint ())
      in
      let decision failure =
        Masc.Keeper_compaction_llm_summarizer.For_testing.with_make_override
          (fun ~runtime_ids:_ ~keeper_name:_ () ->
             Some (fun ~units:_ -> Error failure))
          (fun () ->
             Compact_policy.compact_for_request_typed
               ~meta
               ~trigger:Compaction_trigger.Manual
               context)
        |> fun preparation -> preparation.Compact_policy.decision
      in
      (match decision Masc.Keeper_compaction_llm_summarizer.Invalid_plan with
       | Compact_policy.Rejected (Manual, Invalid_compaction_plan) -> ()
       | _ -> fail "invalid provider plan was not a typed source terminal");
      match decision Masc.Keeper_compaction_llm_summarizer.Provider_unavailable with
      | Compact_policy.Rejected (Manual, Plan_provider_unavailable) -> ()
      | _ -> fail "provider failure was collapsed into an invalid plan")

let rec json_has_key key = function
  | `Assoc fields ->
    List.exists
      (fun (field, value) -> String.equal field key || json_has_key key value)
      fields
  | `List values -> List.exists (json_has_key key) values
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ -> false
;;

let test_projection_target_is_immutable_and_credential_free () =
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore runtime_snapshot)
    (fun () ->
      let runtime_path =
        Filename.concat (Masc_test_deps.find_project_root ()) "config/runtime.toml"
      in
      (match Runtime.init_default ~config_path:runtime_path with
       | Ok () -> ()
       | Error detail -> failf "runtime fixture initialization failed: %s" detail);
      let runtime =
        Runtime.get_default_runtime ()
        |> Option.get
      in
      let target =
        Projection_target.request
          ~assignment_id:runtime.id
          ~resolve_context_window:(fun _ ->
            Projection_target.Resolved_context_window 17)
        |> Projection_target.capture
      in
      let captured =
        Projection_target.captured_evidence target
      in
      (match captured with
       | Projection_target.Exact exact ->
         check string "runtime identity" runtime.id exact.runtime_id;
         check int "effective context snapshot" 17 exact.effective_max_context
       | Projection_target.Unavailable _ ->
         fail "single runtime did not produce an exact target");
      let public_json =
        Projection_target.evidence_to_json captured
      in
      List.iter
        (fun key -> check bool ("credential field excluded: " ^ key) false (json_has_key key public_json))
        [ "api_key"; "base_url"; "credentials"; "endpoint"; "headers" ];
      let unresolved_identity = " missing-runtime " in
      let unresolved =
        Projection_target.request
          ~assignment_id:unresolved_identity
          ~resolve_context_window:(fun _ ->
            Projection_target.Resolved_context_window 17)
        |> Projection_target.capture
        |> Projection_target.captured_evidence
      in
      (match unresolved with
       | Projection_target.Unavailable
           (Projection_target.Runtime_unavailable { runtime_id }) ->
         check string "assignment identity is not normalized" unresolved_identity runtime_id
       | Projection_target.Exact _ | Projection_target.Unavailable _ ->
         fail "missing runtime identity was normalized or reclassified");
      let lane_target =
        Projection_target.request
          ~assignment_id:"default"
          ~resolve_context_window:(fun _ ->
            Projection_target.Resolved_context_window 17)
        |> Projection_target.capture
      in
      match
        Projection_target.captured_evidence lane_target
      with
      | Projection_target.Unavailable
          (Projection_target.Assignment_ambiguous { assignment_id = "default" }) ->
        Runtime.For_testing.restore runtime_snapshot;
        check bool
          "captured evidence survives runtime state replacement"
          true
          (Projection_target.captured_evidence target = captured)
      | Projection_target.Exact _ | Projection_target.Unavailable _ ->
        fail "lane target guessed a provider candidate")
;;

let with_input_count_response input_tokens f =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let socket =
    Eio.Net.listen
      net
      ~sw
      ~backlog:1
      ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port
    | _ -> fail "input-count fixture did not bind a TCP socket"
  in
  let callback _conn _request _body =
    Cohttp_eio.Server.respond_string
      ~status:`OK
      ~body:(Printf.sprintf {|{"input_tokens":%d}|} input_tokens)
      ()
  in
  let server = Cohttp_eio.Server.make ~callback () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Cohttp_eio.Server.run socket server ~on_error:raise);
  f ~sw ~net ~base_url:(Printf.sprintf "http://127.0.0.1:%d" port)
;;

let test_checkpoint_projection_uses_provider_native_fit () =
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore runtime_snapshot)
    (fun () ->
  let runtime_path =
    Filename.concat (Masc_test_deps.find_project_root ()) "config/runtime.toml"
  in
  (match Runtime.init_default ~config_path:runtime_path with
   | Ok () -> ()
   | Error detail -> failf "runtime fixture initialization failed: %s" detail);
  let checkpoint =
    { (make_checkpoint ()) with
      system_prompt = Some "Measure this exact compacted checkpoint."
    }
  in
  let trace_id =
    Keeper_id.Trace_id.of_string checkpoint.session_id |> Result.get_ok
  in
  let checkpoint_ref =
    Keeper_checkpoint_ref.create
      ~trace_id
      ~generation:3
      ~turn_count:checkpoint.turn_count
      ~canonical_checkpoint_bytes:(Agent_sdk.Checkpoint.to_string checkpoint)
    |> Result.get_ok
  in
  let observe input_tokens =
    with_input_count_response input_tokens (fun ~sw ~net ~base_url ->
      let runtime = Runtime.get_default_runtime () |> Option.get in
      let provider_config =
        Llm_provider.Provider_config.make
          ~kind:Llm_provider.Provider_config.Anthropic
          ~model_id:"compaction-fit-fixture"
          ~base_url
          ~api_key:"test-key"
          ~request_path:"/v1/messages"
          ~max_tokens:64
          ()
      in
      let runtime = { runtime with Runtime.provider_config = provider_config } in
      Projection_target.exact_request
        ~runtime
        ~effective_max_context:512
      |> Projection_target.capture
      |> Projection_target.bind_committed_checkpoint ~checkpoint checkpoint_ref
      |> Projection_target.measure_checkpoint_fit ~sw ~net)
  in
  let fitting = observe 321 in
  check bool
    "fit is correlated to committed checkpoint"
    true
    (Keeper_checkpoint_ref.equal fitting.checkpoint_ref checkpoint_ref);
  check bool
    "fit evidence excludes API keys"
    false
    (json_has_key "api_key" (Projection_target.fit_evidence_to_json fitting));
  (match fitting.result with
   | Projection_target.Fit.Fits fit ->
     check int "provider input count" 321 fit.input_tokens;
     check int "reserved output" 64 fit.reserved_output_tokens;
     check int "captured context" 512 fit.max_context_tokens
   | Projection_target.Fit.Exceeds _
   | Projection_target.Fit.Unavailable _ ->
     fail "provider-native measurement should fit");
  let exceeding = observe 500 in
  match exceeding.result with
  | Projection_target.Fit.Exceeds fit ->
    check int "overflow input count" 500 fit.input_tokens;
    check int "overflow output reservation" 64 fit.reserved_output_tokens;
    check int "overflow context" 512 fit.max_context_tokens
  | Projection_target.Fit.Fits _
  | Projection_target.Fit.Unavailable _ ->
    fail "provider-native measurement should exceed the captured context")
;;

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
      let busy_outcome =
        Masc.Keeper_compaction_llm_summarizer.For_testing.with_make_override
          (fun ~runtime_ids:_ ~keeper_name:_ () ->
             fail "busy admission spent a compaction provider call")
          run_cycle
      in
      (match busy_outcome with
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
               |> Result.map_error (fun _ ->
                 Masc.Keeper_compaction_llm_summarizer.Invalid_plan)))
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
               |> Result.map_error (fun _ ->
                 Masc.Keeper_compaction_llm_summarizer.Invalid_plan)))
          (fun () ->
             Post_turn.recover_latest_checkpoint_for_compaction
               ~base_dir:(Masc.Keeper_types_profile.session_base_dir config)
               ~meta
               ~trigger:Compaction_trigger.Manual
               ~projection_request:(projection_request_of_meta meta))
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
           ~generation:meta.runtime.generation
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
      let busy_after_prepare =
        Masc.Keeper_compaction_llm_summarizer.For_testing.with_make_override
          (fun ~runtime_ids:_ ~keeper_name:_ () ->
             Some (fun ~units ->
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
               Eio.Promise.await commit_block_held;
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
                               , `String "prepared while another turn acquires the slot" )
                             ]
                         ] )
                   ])
               |> Result.map_error (fun _ ->
                 Masc.Keeper_compaction_llm_summarizer.Invalid_plan)))
          (fun () -> Masc.Keeper_manual_compaction.run_admitted ~config ~meta)
      in
      (match busy_after_prepare with
       | `Busy _ -> ()
       | `Applied _ | `No_compaction _ | `Compaction_failed _ ->
         fail "compaction commit crossed a turn admitted during preparation");
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

  (* The prepare/commit split exists so the provider call can run outside
     the keeper admission; the source CAS — not the slot — is the
     interleaving guard.  Pin both halves: a prepared plan commits, and
     the same prepared value is rejected once the source has advanced. *)
  Eio_main.run @@ fun env ->
  Masc_test_deps.init_eio_clock env;
  Fs_compat.set_fs (Eio.Stdenv.fs env);
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
       let runtime_path =
         Filename.concat (Masc_test_deps.find_project_root ()) "config/runtime.toml"
       in
       (match Runtime.init_default ~config_path:runtime_path with
        | Ok () -> ()
        | Error detail -> failf "runtime fixture initialization failed: %s" detail);
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
  let plan_for ~units =
    match
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
                       , `String "shorter" )
                     ]
                 ] )
           ])
    with
    | Ok plan -> Ok plan
    | Error _ -> Error Masc.Keeper_compaction_llm_summarizer.Invalid_plan
  in
  Masc.Keeper_compaction_llm_summarizer.For_testing.with_make_override
    (fun ~runtime_ids:_ ~keeper_name:_ () -> Some (fun ~units -> plan_for ~units))
    (fun () ->
       match
         Post_turn.prepare_compaction
           ~base_dir:(Masc.Keeper_types_profile.session_base_dir config)
           ~meta
           ~trigger:Compaction_trigger.Manual
           ~projection_request:(projection_request_of_meta meta)
       with
       | Error error ->
         failf
           "prepare failed: %s"
           (Post_turn.compaction_recovery_error_to_string error)
       | Ok prepared ->
         (match Post_turn.commit_prepared_compaction prepared with
          | Ok recovery ->
            let committed_ref =
              Projection_target.checkpoint_ref recovery.projection_target
            in
            let _, durable_ref =
              Masc.Keeper_checkpoint_store.load_oas_with_ref
                ~session_dir:session.session_dir
                ~session_id:checkpoint.session_id
              |> Result.get_ok
            in
            check bool
              "projection target retains exact committed checkpoint ref"
              true
              (Keeper_checkpoint_ref.equal committed_ref durable_ref)
          | Error error ->
            failf
              "commit of a fresh prepared plan failed: %s"
              (Post_turn.compaction_recovery_error_to_string error));
         (* The first commit advanced the durable source; the same
            prepared value is now stale and must be CAS-rejected. *)
         match Post_turn.commit_prepared_compaction prepared with
         | Error
             (Post_turn.Checkpoint_cas_failed
                (Masc.Keeper_checkpoint_store.Source_changed _)) ->
           ()
         | Error error ->
           failf
             "stale prepared value failed with the wrong error: %s"
             (Post_turn.compaction_recovery_error_to_string error)
         | Ok _ -> fail "stale prepared value committed past the source CAS"))
;;

let () =
  run "post-turn durability" [
    "durable compaction", [
      test_case "compaction rejection tag is stable"
        `Quick test_compaction_rejection_tag_is_stable;
      test_case "empty projection target is typed"
        `Quick test_empty_projection_target_is_typed;
      test_case "regular post-turn does not auto-compact"
        `Quick test_regular_post_turn_does_not_auto_compact;
      test_case "invalid plan is distinct from provider unavailability"
        `Quick test_invalid_plan_is_distinct_from_provider_unavailable;
      test_case "projection target snapshot excludes credentials"
        `Quick test_projection_target_is_immutable_and_credential_free;
      test_case "checkpoint projection uses provider-native fit"
        `Quick test_checkpoint_projection_uses_provider_native_fit;
      test_case "manual compaction serializes the owner lane"
        `Quick test_manual_compaction_serializes_owner_lane;
      test_case "malformed structure preserves checkpoint"
        `Quick test_malformed_structure_preserves_checkpoint;
    ];
  ]
