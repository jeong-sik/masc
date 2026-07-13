(** Regression tests for the ref -> Atomic conversions of keeper-wide shared
    callback refs and caches (PR #21487). Each test registers a callback,
    invokes it through the public API, and restores the default no-op so the
    tests remain order-independent. *)

open Alcotest

let tmp_base_path suffix =
  Filename.concat (Filename.get_temp_dir_name ()) ("masc-test-" ^ suffix)
;;

let test_compact_audit_store_cache () =
  let open Masc in
  let base1 = tmp_base_path "compact-audit-1" in
  let start =
    { Keeper_compact_audit.compaction_id = "id-1"
    ; ts_unix = 0.0
    ; keeper_name = "k"
    ; trigger = Keeper_compact_audit.Proactive
    ; correlation_id = "c"
    ; run_id = "r"
    }
  in
  let r1 = Keeper_compact_audit.persist_start ~base_path:base1 ~retention_days:14 start in
  check (result unit (of_pp (fun _ _ -> ()))) "persist_start base1 succeeds" (Ok ()) r1;
  let r1' = Keeper_compact_audit.persist_start ~base_path:base1 ~retention_days:14 start in
  check (result unit (of_pp (fun _ _ -> ()))) "persist_start base1 again succeeds" (Ok ()) r1';
  let base2 = tmp_base_path "compact-audit-2" in
  let r2 = Keeper_compact_audit.persist_start ~base_path:base2 ~retention_days:14 start in
  check (result unit (of_pp (fun _ _ -> ()))) "persist_start base2 succeeds" (Ok ()) r2;
  (* Switching back to base1 still works after base2 store was created. *)
  let r1'' = Keeper_compact_audit.persist_start ~base_path:base1 ~retention_days:14 start in
  check (result unit (of_pp (fun _ _ -> ()))) "persist_start base1 after base2 succeeds" (Ok ()) r1''
;;

let test_compact_policy_callback () =
  let open Masc in
  let called = ref false in
  let ts = 1234567890.0 in
  Keeper_compact_policy.register_record_pre_compact (fun ~keeper_name ~context_ratio:_ ~message_count:_ ~token_count:_ ~strategies:_ ~context_window:_ ~is_local_model:_ ~trigger:_ ->
    called := true;
    Some
      { Keeper_compact_policy.timestamp = ts
      ; keeper_name
      ; context_ratio = 0.5
      ; message_count = 1
      ; token_count = 1
      ; strategies = []
      ; context_window = 4096
      ; is_local_model = false
      ; trigger = Compaction_trigger.Manual
      });
  let result =
    Keeper_compact_policy.record_pre_compact_callback
      ~keeper_name:"k"
      ~context_ratio:0.5
      ~message_count:1
      ~token_count:1
      ~strategies:[]
      ~context_window:4096
      ~is_local_model:false
      ~trigger:Compaction_trigger.Manual
  in
  check bool "callback was invoked" true !called;
  check bool "returns registered event" true (Option.is_some result);
  (* Restore default. *)
  Keeper_compact_policy.register_record_pre_compact (fun ~keeper_name:_ ~context_ratio:_ ~message_count:_ ~token_count:_ ~strategies:_ ~context_window:_ ~is_local_model:_ ~trigger:_ -> None)
;;

let compact_policy_meta () =
  let open Masc in
  match
    Keeper_meta_json_parse.meta_of_json
      (`Assoc
        [ "name", `String "compact-policy-window"
        ; "agent_name", `String "compact-policy-window"
        ; "trace_id", `String "trace-compact-policy-window"
        ])
  with
  | Error err -> fail ("meta_of_json failed: " ^ err)
  | Ok meta ->
    { meta with
      compaction =
        { meta.compaction with
          ratio_gate = 0.99
        ; message_gate = 1
        ; token_gate = 0
        ; cooldown_sec = 0
        }
    }

let test_pre_compact_context_window_uses_working_context () =
  let open Masc in
  let recorded_window = ref None in
  let recorded_is_local_model = ref None in
  let restore () =
    Keeper_compact_policy.register_record_pre_compact
      (fun ~keeper_name:_ ~context_ratio:_ ~message_count:_ ~token_count:_
        ~strategies:_ ~context_window:_ ~is_local_model:_ ~trigger:_ -> None)
  in
  Fun.protect
    ~finally:restore
    (fun () ->
       Keeper_compact_policy.register_record_pre_compact
         (fun ~keeper_name ~context_ratio ~message_count ~token_count
           ~strategies ~context_window ~is_local_model ~trigger ->
            recorded_window := Some context_window;
            recorded_is_local_model := Some is_local_model;
            Some
              { Keeper_compact_policy.timestamp = 1.0
              ; keeper_name
              ; context_ratio
              ; message_count
              ; token_count
              ; strategies
              ; context_window
              ; is_local_model
              ; trigger
              });
       let ctx =
         Keeper_context_runtime.create ~eio:false
           ~system_prompt:"pre compact window"
           ~max_tokens:131_072
         |> fun ctx ->
         Keeper_context_runtime.append ctx
           (Agent_sdk.Types.user_msg "force message-gate compaction")
       in
       let _, trigger, decision =
         Keeper_compact_policy.compact_if_needed_typed
           ~meta:(compact_policy_meta ())
           ~now_ts:1.0
           ctx
       in
       check bool "compaction triggered" true (Option.is_some trigger);
       check bool "decision applied" true
         (Keeper_compact_policy.compaction_decision_applied decision);
       check (option int) "pre-compact event uses ctx max_tokens"
         (Some 131_072)
         !recorded_window;
       check (option bool) "uninitialized runtime locality is telemetry only"
         (Some false)
         !recorded_is_local_model)
;;

let test_meta_store_hook () =
  let open Masc in
  let called = ref false in
  Keeper_meta_store.register_runtime_meta_write_sync (fun _config _meta -> called := true);
  Keeper_meta_store.runtime_meta_write_sync_hook (Obj.magic ()) (Obj.magic ());
  check bool "sync hook was invoked" true !called;
  Keeper_meta_store.register_runtime_meta_write_sync (fun _config _meta -> ())
;;

let test_tool_dispatch_runtime () =
  let open Masc in
  let recorded = ref None in
  Keeper_tool_dispatch_runtime.For_testing.set_on_keeper_tool_call (fun ~tool_name ~success ~duration_ms ->
    recorded := Some (tool_name, success, duration_ms));
  Keeper_tool_dispatch_runtime.For_testing.record_keeper_tool_call ~tool_name:"t" ~success:true ~duration_ms:42;
  check (option (triple string bool int)) "recorder received call" (Some ("t", true, 42)) !recorded;
  (* Restore defaults. *)
  Keeper_tool_dispatch_runtime.For_testing.set_on_keeper_tool_call (fun ~tool_name:_ ~success:_ ~duration_ms:_ -> ())
;;

let test_tool_in_process_runtime () =
  let open Masc in
  let called = ref false in
  Keeper_tool_in_process_runtime.register_dashboard_surface_readiness (fun ?surface_id:_ () ->
    called := true;
    `Bool true);
  let json = Keeper_tool_in_process_runtime.handle_masc_surface_audit ~args:(`Assoc []) in
  check bool "surface readiness callback was invoked" true !called;
  check string "surface readiness JSON returned" "true" json;
  (* Restore default. *)
  Keeper_tool_in_process_runtime.register_dashboard_surface_readiness (fun ?surface_id:_ () -> `Assoc [])
;;

let test_keepalive_signal_callbacks () =
  let open Masc in
  (* gRPC heartbeat starter. *)
  let started = ref false in
  Keeper_keepalive_signal.register_grpc_heartbeat_starter
    { Keeper_keepalive_signal.f =
        (fun ~ctx:_ ~m:_ ~stop:_ ->
           started := true;
           Some (fun () -> ()))
    };
  let _ = Keeper_keepalive_signal.grpc_heartbeat_starter ~ctx:(Obj.magic ()) ~m:(Obj.magic ()) ~stop:(Atomic.make false) in
  check bool "grpc starter invoked" true !started;
  Keeper_keepalive_signal.register_grpc_heartbeat_starter
    { Keeper_keepalive_signal.f = (fun ~ctx:_ ~m:_ ~stop:_ -> None) };
  (* Wake payload. *)
  let wake_called = ref false in
  Keeper_keepalive_signal.register_record_wake_payload (fun ~keeper_name:_ ~trace_id:_ ~turn_index:_ ~model_id:_ ~context_window:_ ~approx_body_bytes:_ ~system_prompt_bytes:_ ~tool_defs_bytes:_ ~messages_bytes:_ ~message_count:_ ~role_counts:_ ~tool_count:_ ~has_compact_happened:_ ->
    wake_called := true);
  Keeper_keepalive_signal.record_wake_payload
    ~keeper_name:"k"
    ~trace_id:"t"
    ~turn_index:0
    ~model_id:"m"
    ~context_window:4096
    ~approx_body_bytes:0
    ~system_prompt_bytes:0
    ~tool_defs_bytes:0
    ~messages_bytes:0
    ~message_count:0
    ~role_counts:[]
    ~tool_count:0
    ~has_compact_happened:false;
  check bool "wake payload callback invoked" true !wake_called;
  Keeper_keepalive_signal.register_record_wake_payload (fun ~keeper_name:_ ~trace_id:_ ~turn_index:_ ~model_id:_ ~context_window:_ ~approx_body_bytes:_ ~system_prompt_bytes:_ ~tool_defs_bytes:_ ~messages_bytes:_ ~message_count:_ ~role_counts:_ ~tool_count:_ ~has_compact_happened:_ -> ());
  (* Tool skipped. *)
  let skipped = ref false in
  Keeper_keepalive_signal.register_record_tool_skipped (fun ~keeper_name:_ ~tool_name:_ ~reason_code:_ -> skipped := true);
  Keeper_keepalive_signal.record_tool_skipped ~keeper_name:"k" ~tool_name:"t" ~reason_code:"r";
  check bool "tool skipped callback invoked" true !skipped;
  Keeper_keepalive_signal.register_record_tool_skipped (fun ~keeper_name:_ ~tool_name:_ ~reason_code:_ -> ());
  (* Execute output. *)
  let output = ref false in
  Keeper_keepalive_signal.register_record_execute_output (fun ~keeper_name:_ ~task_id:_ ~stdout:_ ~stderr:_ ~status:_ ~streamed:_ -> output := true);
  Keeper_keepalive_signal.record_execute_output
    ~keeper_name:"k"
    ~task_id:None
    ~stdout:""
    ~stderr:""
    ~status:(`Assoc [])
    ~streamed:false;
  check bool "execute output callback invoked" true !output;
  Keeper_keepalive_signal.register_record_execute_output (fun ~keeper_name:_ ~task_id:_ ~stdout:_ ~stderr:_ ~status:_ ~streamed:_ -> ());
  (* Stream start/chunk/end. *)
  let stream_start = ref false in
  let stream_chunk = ref false in
  let stream_end = ref false in
  Keeper_keepalive_signal.register_record_execute_stream_start (fun ~keeper_name:_ ~task_id:_ -> stream_start := true);
  Keeper_keepalive_signal.register_record_execute_stream_chunk (fun ~keeper_name:_ ~stream:_ _chunk -> stream_chunk := true);
  Keeper_keepalive_signal.register_record_execute_stream_end (fun ~keeper_name:_ ~task_id:_ ~status:_ -> stream_end := true);
  Keeper_keepalive_signal.record_execute_stream_start ~keeper_name:"k" ~task_id:None;
  Keeper_keepalive_signal.record_execute_stream_chunk ~keeper_name:"k" ~stream:`Stdout "x";
  Keeper_keepalive_signal.record_execute_stream_end ~keeper_name:"k" ~task_id:None ~status:(`Assoc []);
  check bool "stream start callback invoked" true !stream_start;
  check bool "stream chunk callback invoked" true !stream_chunk;
  check bool "stream end callback invoked" true !stream_end;
  Keeper_keepalive_signal.register_record_execute_stream_start (fun ~keeper_name:_ ~task_id:_ -> ());
  Keeper_keepalive_signal.register_record_execute_stream_chunk (fun ~keeper_name:_ ~stream:_ _chunk -> ());
  Keeper_keepalive_signal.register_record_execute_stream_end (fun ~keeper_name:_ ~task_id:_ ~status:_ -> ())
;;

let test_turn_lifecycle_callback () =
  let open Masc in
  let called = ref false in
  Keeper_turn_lifecycle.register_remove_pending_confirms_by_target (fun _config ~target_type:_ ~target_id:_ ->
    called := true;
    Ok 7);
  let n =
    Keeper_turn_lifecycle.For_testing.remove_pending_confirms_by_target
      ~config:(Obj.magic ())
      ~target_type:Operator_action_constants.Keeper
      ~target_id:(Some "k")
  in
  check bool "remove pending confirms callback invoked" true !called;
  check (result int string) "remove pending confirms returned value" (Ok 7) n;
  Keeper_turn_lifecycle.For_testing.reset_remove_pending_confirms_by_target ()
;;

let () =
  Alcotest.run
    "keeper-global-shared-refs-atomic"
    [ ( "compact-audit"
      , [ test_case "store cache is shared per base_path" `Quick test_compact_audit_store_cache ] )
    ; ( "compact-policy"
      , [ test_case "record_pre_compact callback registration" `Quick test_compact_policy_callback
        ; test_case "pre_compact context window uses working context" `Quick
            test_pre_compact_context_window_uses_working_context
        ] )
    ; ( "meta-store"
      , [ test_case "runtime_meta_write_sync_hook registration" `Quick test_meta_store_hook ] )
    ; ( "tool-dispatch-runtime"
      , [ test_case "recorder and searcher registration" `Quick test_tool_dispatch_runtime ] )
    ; ( "tool-in-process-runtime"
      , [ test_case "dashboard surface readiness callback" `Quick test_tool_in_process_runtime ] )
    ; ( "keepalive-signal"
      , [ test_case "all global callback registrations" `Quick test_keepalive_signal_callbacks ] )
    ; ( "turn-lifecycle"
      , [ test_case "remove_pending_confirms_by_target callback" `Quick test_turn_lifecycle_callback ] )
    ]
;;
