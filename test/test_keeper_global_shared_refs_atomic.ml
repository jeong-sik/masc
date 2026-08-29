(** Regression tests for the ref -> Atomic conversions of keeper-wide shared
    callback refs and caches (PR #21487). Each test registers a callback,
    invokes it through the public API, and restores the default no-op so the
    tests remain order-independent. *)

open Alcotest

let test_keepalive_signal_callbacks () =
  let open Masc in
  let started = ref false in
  Keeper_keepalive_signal.register_grpc_heartbeat_starter
    { Keeper_keepalive_signal.f =
        (fun ~ctx:_ ~m:_ ~stop:_ ->
           started := true;
           Some (fun () -> ()))
    };
  let _ =
    Keeper_keepalive_signal.grpc_heartbeat_starter
      ~ctx:(Obj.magic ())
      ~m:(Obj.magic ())
      ~stop:(Atomic.make false)
  in
  check bool "grpc starter invoked" true !started;
  Keeper_keepalive_signal.register_grpc_heartbeat_starter
    { Keeper_keepalive_signal.f = (fun ~ctx:_ ~m:_ ~stop:_ -> None) };
  let wake_called = ref false in
  Keeper_keepalive_signal.register_record_wake_payload
    (fun
      ~keeper_name:_
      ~trace_id:_
      ~turn_index:_
      ~context_window:_
      ~system_prompt_bytes:_
      ~tool_schema_json_bytes:_
      ~message_content_bytes:_
      ~message_count:_
      ~role_counts:_
      ~tool_count:_
    -> wake_called := true);
  Keeper_keepalive_signal.record_wake_payload
    ~keeper_name:"k"
    ~trace_id:"t"
    ~turn_index:0
    ~context_window:4096
    ~system_prompt_bytes:0
    ~tool_schema_json_bytes:0
    ~message_content_bytes:0
    ~message_count:0
    ~role_counts:[]
    ~tool_count:0;
  check bool "wake payload callback invoked" true !wake_called;
  Keeper_keepalive_signal.register_record_wake_payload
    (fun
      ~keeper_name:_
      ~trace_id:_
      ~turn_index:_
      ~context_window:_
      ~system_prompt_bytes:_
      ~tool_schema_json_bytes:_
      ~message_content_bytes:_
      ~message_count:_
      ~role_counts:_
      ~tool_count:_
    -> ());
  let skipped = ref false in
  Keeper_keepalive_signal.register_record_tool_skipped
    (fun ~tool_name:_ ~reason_code:_ -> skipped := true);
  Keeper_keepalive_signal.record_tool_skipped ~tool_name:"t" ~reason_code:"r";
  check bool "tool skipped callback invoked" true !skipped;
  Keeper_keepalive_signal.register_record_tool_skipped
    (fun ~tool_name:_ ~reason_code:_ -> ());
  let output = ref false in
  Keeper_keepalive_signal.register_record_execute_output
    (fun
      ~keeper_name:_
      ~task_id:_
      ~stdout:_
      ~stderr:_
      ~status:_
      ~streamed:_
    -> output := true);
  Keeper_keepalive_signal.record_execute_output
    ~keeper_name:"k"
    ~task_id:None
    ~stdout:""
    ~stderr:""
    ~status:(`Assoc [])
    ~streamed:false;
  check bool "execute output callback invoked" true !output;
  Keeper_keepalive_signal.register_record_execute_output
    (fun
      ~keeper_name:_
      ~task_id:_
      ~stdout:_
      ~stderr:_
      ~status:_
      ~streamed:_
    -> ());
  let stream_start = ref false in
  let stream_chunk = ref false in
  let stream_end = ref false in
  Keeper_keepalive_signal.register_record_execute_stream_start
    (fun ~keeper_name:_ ~task_id:_ -> stream_start := true);
  Keeper_keepalive_signal.register_record_execute_stream_chunk
    (fun ~keeper_name:_ ~stream:_ _chunk -> stream_chunk := true);
  Keeper_keepalive_signal.register_record_execute_stream_end
    (fun ~keeper_name:_ ~task_id:_ ~status:_ -> stream_end := true);
  Keeper_keepalive_signal.record_execute_stream_start
    ~keeper_name:"k"
    ~task_id:None;
  Keeper_keepalive_signal.record_execute_stream_chunk
    ~keeper_name:"k"
    ~stream:`Stdout
    "x";
  Keeper_keepalive_signal.record_execute_stream_end
    ~keeper_name:"k"
    ~task_id:None
    ~status:(`Assoc []);
  check bool "stream start callback invoked" true !stream_start;
  check bool "stream chunk callback invoked" true !stream_chunk;
  check bool "stream end callback invoked" true !stream_end;
  Keeper_keepalive_signal.register_record_execute_stream_start
    (fun ~keeper_name:_ ~task_id:_ -> ());
  Keeper_keepalive_signal.register_record_execute_stream_chunk
    (fun ~keeper_name:_ ~stream:_ _chunk -> ());
  Keeper_keepalive_signal.register_record_execute_stream_end
    (fun ~keeper_name:_ ~task_id:_ ~status:_ -> ())
;;

let test_turn_lifecycle_callback () =
  let open Masc in
  let called = ref false in
  Keeper_turn_lifecycle.register_remove_pending_confirms_by_target
    (fun _config ~target_type:_ ~target_id:_ ->
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
    [ ( "keepalive-signal"
      , [ test_case
            "all global callback registrations"
            `Quick
            test_keepalive_signal_callbacks
        ] )
    ; ( "turn-lifecycle"
      , [ test_case
            "remove_pending_confirms_by_target callback"
            `Quick
            test_turn_lifecycle_callback
        ] )
    ]
;;
