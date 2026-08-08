open Alcotest
open Agent_sdk
module Internal = Agent_sdk__
module Runtime_internal = Internal.Execution_runtime
module Codec = Internal.Execution_codec_executor
module Event = Internal.Execution_event
module Journal = Internal.Execution_journal

exception Cancel_running_codec
exception Cancel_queued_codec
exception Cancel_nested_codec

type live_caller_outcome =
  | Live_caller_returned of (string list, Codec.failure) result
  | Live_caller_cancelled
  | Live_caller_raised of exn

let require_runtime = function
  | Ok runtime -> runtime
  | Error error -> fail (Runtime_internal.create_error_to_string error)
;;

let require = function
  | Ok value -> value
  | Error failure -> fail (Codec.failure_to_string failure)
;;

let require_journal = function
  | Ok value -> value
  | Error error -> fail (Journal.error_to_string error)
;;

let require_id = function
  | Ok value -> value
  | Error detail -> fail detail
;;

let one_event () =
  let correlation_id = require_id (Event.Correlation_id.fresh ()) in
  let journal = require_journal (Journal.create ~correlation_id ()) in
  let _run, opened =
    require_journal (Journal.start_run journal ~agent_name:"codec-test")
  in
  opened
;;

let require_worker name caller = function
  | None -> fail (name ^ " did not record a worker domain")
  | Some worker ->
    check bool (name ^ " runs outside the caller domain") true (worker <> caller);
    worker
;;

let rec await predicate =
  if predicate ()
  then ()
  else (
    Eio.Fiber.yield ();
    await predicate)
;;

let fork_cancellable ~sw fn =
  let context, resolve_context = Eio.Promise.create () in
  let finished, resolve_finished = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    let cancelled =
      match
        Eio.Cancel.sub (fun context ->
          Eio.Promise.resolve resolve_context context;
          fn ())
      with
      | () -> false
      | exception Eio.Cancel.Cancelled _ -> true
      | exception exn -> raise exn
    in
    Eio.Promise.resolve resolve_finished cancelled);
  Eio.Promise.await context, finished
;;

let with_runtime env f =
  Eio.Switch.run (fun sw ->
    let runtime =
      require_runtime
        (Runtime_internal.create
           ~sw
           ~domain_mgr:(Eio.Stdenv.domain_mgr env)
           ~domain_count:1)
    in
    f runtime (Codec.of_runtime runtime))
;;

let test_closed_requests_share_real_worker env =
  with_runtime env (fun _runtime codec ->
    let caller = Domain.self () in
    check (list string) "empty encode" [] (require (Codec.encode_events codec []));
    let payload = Event.to_json_string (one_event ()) in
    (match require (Codec.decode_canonical_event codec payload) with
     | Ok _event -> ()
     | Error _ -> fail "canonical event failed to decode");
    check
      bool
      "canonical payload compares exactly"
      true
      (require (Codec.compare_canonical_payload codec ~expected:payload ~actual:payload));
    let stats = Codec.stats codec in
    let encode_worker =
      require_worker "encode" caller stats.encode_events.last_worker_domain
    in
    let decode_worker =
      require_worker "decode" caller stats.decode_canonical_event.last_worker_domain
    in
    let compare_worker =
      require_worker "compare" caller stats.compare_canonical_payload.last_worker_domain
    in
    check bool "encode and decode share one worker" true (encode_worker = decode_worker);
    check bool "decode and compare share one worker" true (decode_worker = compare_worker);
    List.iter
      (fun (name, (operation : Codec.operation_stats)) ->
         check int (name ^ " requested") 1 operation.requested;
         check int (name ^ " started") 1 operation.started;
         check int (name ^ " completed") 1 operation.completed;
         check int (name ^ " job failures") 0 operation.job_failed;
         check int (name ^ " worker cancellations") 0 operation.worker_cancelled;
         check int (name ^ " executor failures") 0 operation.executor_failed;
         check int (name ^ " caller cancellations") 0 operation.caller_cancelled;
         check
           bool
           (name ^ " caller identity")
           true
           (operation.last_caller_domain = Some caller))
      [ "encode", stats.encode_events
      ; "decode", stats.decode_canonical_event
      ; "compare", stats.compare_canonical_payload
      ])
;;

let test_invalid_event_is_typed_codec_result env =
  with_runtime env (fun _runtime codec ->
    match require (Codec.decode_canonical_event codec "{}") with
    | Error (Codec.Invalid_event { detail = _ }) -> ()
    | Error Codec.Noncanonical_event -> fail "invalid event reported as noncanonical"
    | Ok _ -> fail "invalid event decoded successfully")
;;

let test_released_runtime_is_typed_executor_failure env =
  let escaped = ref None in
  Eio.Switch.run (fun sw ->
    let runtime =
      require_runtime
        (Runtime_internal.create
           ~sw
           ~domain_mgr:(Eio.Stdenv.domain_mgr env)
           ~domain_count:1)
    in
    escaped := Some (Codec.of_runtime runtime));
  let codec = Option.get !escaped in
  match Codec.encode_events codec [] with
  | Error (Codec.Executor_unavailable { operation = Codec.Encode_events; _ }) -> ()
  | Error failure ->
    fail ("unexpected released-runtime failure: " ^ Codec.failure_to_string failure)
  | Ok _ -> fail "released execution runtime accepted a codec request"
;;

let test_running_and_queued_cancellation_stop_workers env =
  with_runtime env (fun _runtime codec ->
    Eio.Switch.run (fun sw ->
      let event = one_event () in
      let rec unbounded_events = event :: unbounded_events in
      let running_context, running_finished =
        fork_cancellable ~sw (fun () ->
          ignore (Codec.encode_events codec unbounded_events : (string list, _) result))
      in
      await (fun () -> (Codec.stats codec).encode_events.started = 1);
      let payload = Event.to_json_string event in
      let queued_context, queued_finished =
        fork_cancellable ~sw (fun () ->
          ignore
            (Codec.compare_canonical_payload codec ~expected:payload ~actual:payload
             : (bool, _) result))
      in
      await (fun () -> (Codec.stats codec).compare_canonical_payload.requested = 1);
      Eio.Cancel.cancel queued_context Cancel_queued_codec;
      check bool "queued caller is cancelled" true (Eio.Promise.await queued_finished);
      Eio.Cancel.cancel running_context Cancel_running_codec;
      check bool "running caller is cancelled" true (Eio.Promise.await running_finished);
      await (fun () -> (Codec.stats codec).encode_events.worker_cancelled = 1);
      let stats = Codec.stats codec in
      check
        int
        "running caller cancellation observed"
        1
        stats.encode_events.caller_cancelled;
      check
        int
        "running worker cancellation observed"
        1
        stats.encode_events.worker_cancelled;
      check
        int
        "running cancellation is not executor failure"
        0
        stats.encode_events.executor_failed;
      check
        int
        "queued caller cancellation observed"
        1
        stats.compare_canonical_payload.caller_cancelled;
      check
        int
        "queued job never starts after its submitter is cancelled"
        0
        stats.compare_canonical_payload.started;
      check
        int
        "queued cancellation has no worker to cancel"
        0
        stats.compare_canonical_payload.worker_cancelled;
      check
        int
        "queued cancellation is not executor failure"
        0
        stats.compare_canonical_payload.executor_failed))
;;

let test_same_runtime_reentry_is_inline env =
  with_runtime env (fun runtime codec ->
    let caller = Domain.self () in
    let payload = Event.to_json_string (one_event ()) in
    let worker, identical =
      match
        Runtime_internal.Private.run_cpu runtime (fun () ->
          let worker = Domain.self () in
          ( worker
          , require
              (Codec.compare_canonical_payload codec ~expected:payload ~actual:payload) ))
      with
      | Ok value -> value
      | Error { exception_; backtrace } ->
        let backtrace = Option.value ~default:(Printexc.get_raw_backtrace ()) backtrace in
        Printexc.raise_with_backtrace exception_ backtrace
    in
    check bool "outer job runs off caller" true (worker <> caller);
    check bool "reentrant codec result is exact" true identical;
    let runtime_stats = Runtime_internal.stats runtime in
    check int "only outer job requests the pool" 1 runtime_stats.pool_requested;
    check int "inner job is structurally inline" 1 runtime_stats.reentrant_inline;
    let codec_stats = (Codec.stats codec).compare_canonical_payload in
    check
      bool
      "inline job stays on outer worker"
      true
      (codec_stats.last_worker_domain = Some worker))
;;

let test_same_runtime_reentry_inherits_cancellation env =
  with_runtime env (fun runtime codec ->
    Eio.Switch.run (fun sw ->
      let event = one_event () in
      let rec unbounded_events = event :: unbounded_events in
      let context, finished =
        fork_cancellable ~sw (fun () ->
          ignore
            (Runtime_internal.Private.run_cpu runtime (fun () ->
               ignore
                 (Codec.encode_events codec unbounded_events
                  : (string list, Codec.failure) result))))
      in
      await (fun () -> (Codec.stats codec).encode_events.started = 1);
      Eio.Cancel.cancel context Cancel_nested_codec;
      check bool "outer runtime caller is cancelled" true (Eio.Promise.await finished);
      await (fun () -> (Codec.stats codec).encode_events.worker_cancelled = 1);
      let runtime_stats = Runtime_internal.stats runtime in
      check int "outer request reached the pool once" 1 runtime_stats.pool_requested;
      check int "nested codec remained inline" 1 runtime_stats.reentrant_inline;
      check int "runtime observed caller cancellation" 1 runtime_stats.caller_cancelled;
      let codec_stats = (Codec.stats codec).encode_events in
      check
        int
        "nested worker observed inherited cancellation"
        1
        codec_stats.worker_cancelled;
      check
        int
        "nested cancellation is not executor failure"
        0
        codec_stats.executor_failed;
      check int "nested codec did not complete" 0 codec_stats.completed))
;;

let test_runtime_release_is_not_caller_cancellation env =
  Eio.Switch.run (fun sw ->
    let runtime_ready, resolve_runtime_ready = Eio.Promise.create () in
    let release_runtime, resolve_release_runtime = Eio.Promise.create () in
    let runtime_scope =
      Eio.Fiber.fork_promise ~sw (fun () ->
        Eio.Switch.run (fun runtime_sw ->
          let runtime =
            require_runtime
              (Runtime_internal.create
                 ~sw:runtime_sw
                 ~domain_mgr:(Eio.Stdenv.domain_mgr env)
                 ~domain_count:1)
          in
          Eio.Promise.resolve resolve_runtime_ready (runtime, Codec.of_runtime runtime);
          Eio.Promise.await release_runtime))
    in
    let _runtime, codec = Eio.Promise.await runtime_ready in
    let event = one_event () in
    let rec unbounded_events = event :: unbounded_events in
    let outcome, resolve_outcome = Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
      let outcome =
        match Codec.encode_events codec unbounded_events with
        | result -> Live_caller_returned result
        | exception Eio.Cancel.Cancelled _ -> Live_caller_cancelled
        | exception exn -> Live_caller_raised exn
      in
      Eio.Promise.resolve resolve_outcome outcome);
    await (fun () -> (Codec.stats codec).encode_events.started = 1);
    Eio.Promise.resolve resolve_release_runtime ();
    (match Eio.Promise.await runtime_scope with
     | Ok () -> ()
     | Error exn -> fail ("runtime scope failed: " ^ Printexc.to_string exn));
    (match Eio.Promise.await outcome with
     | Live_caller_returned
         (Error (Codec.Executor_unavailable { operation = Codec.Encode_events; _ })) -> ()
     | Live_caller_returned (Error failure) ->
       fail ("unexpected runtime-release failure: " ^ Codec.failure_to_string failure)
     | Live_caller_returned (Ok _) ->
       fail "runtime release completed an unbounded codec job"
     | Live_caller_cancelled ->
       fail "runtime release was misreported as caller cancellation"
     | Live_caller_raised exn -> fail ("runtime release raised: " ^ Printexc.to_string exn));
    let stats = (Codec.stats codec).encode_events in
    check int "runtime release cancels the worker" 1 stats.worker_cancelled;
    check int "runtime release is an executor failure" 1 stats.executor_failed;
    check int "live caller is not marked cancelled" 0 stats.caller_cancelled)
;;

let test_non_positive_domain_count_is_typed env =
  Eio.Switch.run (fun sw ->
    match
      Runtime_internal.create ~sw ~domain_mgr:(Eio.Stdenv.domain_mgr env) ~domain_count:0
    with
    | Error (Runtime_internal.Non_positive_domain_count 0) -> ()
    | Error error -> fail (Runtime_internal.create_error_to_string error)
    | Ok _ -> fail "execution runtime accepted a non-positive domain count")
;;

let () =
  Eio_main.run (fun env ->
    run
      "execution codec executor"
      [ ( "real runtime"
        , [ test_case "closed requests share one off-domain worker" `Quick (fun () ->
              test_closed_requests_share_real_worker env)
          ; test_case "invalid event remains a typed decode result" `Quick (fun () ->
              test_invalid_event_is_typed_codec_result env)
          ; test_case "released runtime is an explicit executor failure" `Quick (fun () ->
              test_released_runtime_is_typed_executor_failure env)
          ; test_case "running and queued cancellation stop workers" `Quick (fun () ->
              test_running_and_queued_cancellation_stop_workers env)
          ; test_case "same-runtime reentry executes on the worker" `Quick (fun () ->
              test_same_runtime_reentry_is_inline env)
          ; test_case "same-runtime reentry inherits cancellation" `Quick (fun () ->
              test_same_runtime_reentry_inherits_cancellation env)
          ; test_case "runtime release is not caller cancellation" `Quick (fun () ->
              test_runtime_release_is_not_caller_cancellation env)
          ; test_case "non-positive domain count is typed" `Quick (fun () ->
              test_non_positive_domain_count_is_typed env)
          ] )
      ])
;;
