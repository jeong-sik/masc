type runtime = { codec : Execution_codec_executor.t }
type locator = Execution_agent_scope.scope_locator

type terminal_outcome =
  | Terminal_succeeded
  | Terminal_failed
  | Terminal_cancelled

type operator_repair_reason = Execution_agent_scope.operator_repair_reason =
  | Effect_outcome_unknown

type recovery_action = Execution_agent_scope.recovery_action =
  | Retire
  | Operator_repair_required of operator_repair_reason

type terminal_disposition =
  { outcome : terminal_outcome
  ; recovery : recovery_action
  }

type store_mode =
  | Fresh
  | Resume of locator

type store =
  { codec : Execution_codec_executor.t
  ; dir : Eio.Fs.dir_ty Eio.Path.t
  ; on_scope_ready : (locator -> (unit, string) result) option
  ; on_terminal_disposition : (terminal_disposition -> (unit, string) result) option
  ; mode : store_mode
  }

exception Abort_failed_after_exception of exn * Printexc.raw_backtrace * string

let create_runtime ~sw ~domain_mgr ~domain_count =
  Execution_runtime.create ~sw ~domain_mgr ~domain_count
  |> Result.map (fun runtime -> { codec = Execution_codec_executor.of_runtime runtime })
  |> Result.map_error (fun error ->
    Error.Config
      (InvalidConfig
         { field = "execution_domain_count"
         ; detail = Execution_runtime.create_error_to_string error
         }))
;;

let runtime_codec (runtime : runtime) = runtime.codec

let store ~(runtime : runtime) ~dir ?on_scope_ready ?on_terminal_disposition ?resume () =
  let mode =
    match resume with
    | None -> Fresh
    | Some locator -> Resume locator
  in
  { codec = runtime.codec; dir; on_scope_ready; on_terminal_disposition; mode }
;;

let locator_to_yojson = Execution_agent_scope.scope_locator_to_yojson
let locator_of_yojson = Execution_agent_scope.scope_locator_of_yojson
let locator_run_id = Execution_agent_scope.scope_locator_run_id

let execution_failure detail =
  Provider_failure_attribution.of_sdk_error
    (Error.Internal ("durable execution: " ^ detail))
;;

let persist_terminal_disposition persist disposition =
  match persist disposition with
  | Ok () -> Ok ()
  | Error detail ->
    Error (execution_failure ("terminal disposition sink failed: " ^ detail))
  | exception exn ->
    (match Llm_provider.Reserved_exn.reraise_if_reserved exn with
     | () ->
       Error
         (execution_failure
            ("terminal disposition sink raised: " ^ Printexc.to_string exn))
     | exception reserved -> raise reserved)
;;

let notify_terminal scope on_terminal_disposition outcome =
  match on_terminal_disposition with
  | None -> Ok ()
  | Some persist ->
    (match Execution_agent_scope.terminal_recovery_action scope with
     | Error error ->
       Error
         (execution_failure
            ("terminal disposition unavailable: "
             ^ Execution_agent_scope.error_to_string error))
     | Ok recovery -> persist_terminal_disposition persist { outcome; recovery })
;;

let abort_failure_of_error (detailed : Provider_failure_attribution.detailed_error) =
  Execution_event.
    { kind = Internal_failure; detail = Error.to_string detailed.error; data = None }
;;

let reraise_after_abort_failure exn backtrace abort_detail =
  match Llm_provider.Reserved_exn.reraise_if_reserved exn with
  | () ->
    Printexc.raise_with_backtrace
      (Abort_failed_after_exception (exn, backtrace, abort_detail))
      backtrace
  | exception reserved ->
    Eio.traceln
      "durable execution cleanup failed while preserving reserved exception: %s"
      abort_detail;
    Printexc.raise_with_backtrace reserved backtrace
;;

let capture_traceln_for_inline_test f =
  Eio_main.run
  @@ fun env ->
  let buffer = Buffer.create 256 in
  let captured_traceln =
    { Eio.Debug.traceln =
        (fun ?__POS__:_ format ->
          Format.kasprintf
            (fun message ->
               Buffer.add_string buffer message;
               Buffer.add_char buffer '\n')
            format)
    }
  in
  Eio.Fiber.with_binding (Eio.Stdenv.debug env)#traceln captured_traceln (fun () ->
    let result = f () in
    result, Buffer.contents buffer)
;;

let%test "abort failure preserves cancellation class" =
  let preserved, diagnostic =
    capture_traceln_for_inline_test (fun () ->
      try
        match
          reraise_after_abort_failure
            (Eio.Cancel.Cancelled Exit)
            (Printexc.get_callstack 8)
            "injected abort failure"
        with
        | () -> false
      with
      | Eio.Cancel.Cancelled Exit -> true
      | Eio.Cancel.Cancelled _ | Abort_failed_after_exception _ -> false)
  in
  preserved
  && String.equal
       (String.trim diagnostic)
       "durable execution cleanup failed while preserving reserved exception: injected \
        abort failure"
;;

let%test "abort failure preserves reserved runtime exception" =
  let preserved, diagnostic =
    capture_traceln_for_inline_test (fun () ->
      try
        match
          reraise_after_abort_failure
            Sys.Break
            (Printexc.get_callstack 8)
            "injected abort failure"
        with
        | () -> false
      with
      | Sys.Break -> true
      | Abort_failed_after_exception _ -> false)
  in
  preserved
  && String.equal
       (String.trim diagnostic)
       "durable execution cleanup failed while preserving reserved exception: injected \
        abort failure"
;;

let abort_after_exception scope on_terminal_disposition exn backtrace =
  let reason =
    match exn with
    | Eio.Cancel.Cancelled _ ->
      Execution_agent_scope.Cancelled
        { reason = Some (Printexc.to_string exn); data = None }
    | _ ->
      Execution_agent_scope.Failed
        Execution_event.
          { kind = Internal_failure; detail = Printexc.to_string exn; data = None }
  in
  match
    Eio.Cancel.protect (fun () ->
      match Execution_agent_scope.abort scope reason with
      | Error error -> Error (Execution_agent_scope.error_to_string error)
      | Ok () ->
        let outcome =
          match exn with
          | Eio.Cancel.Cancelled _ -> Terminal_cancelled
          | _ -> Terminal_failed
        in
        (match notify_terminal scope on_terminal_disposition outcome with
         | Ok () -> Ok ()
         | Error detailed ->
           Error (Error.to_string detailed.Provider_failure_attribution.error)))
  with
  | Ok () -> Printexc.raise_with_backtrace exn backtrace
  | Error cleanup_detail -> reraise_after_abort_failure exn backtrace cleanup_detail
;;

let abort_error scope on_terminal_disposition detailed =
  match
    Execution_agent_scope.abort
      scope
      (Execution_agent_scope.Failed (abort_failure_of_error detailed))
  with
  | Ok () ->
    (match notify_terminal scope on_terminal_disposition Terminal_failed with
     | Ok () -> Error detailed
     | Error notification_error -> Error notification_error)
  | Error abort_error ->
    Error
      (execution_failure
         (Printf.sprintf
            "agent failed: %s; abort failed: %s"
            (Error.to_string detailed.Provider_failure_attribution.error)
            (Execution_agent_scope.error_to_string abort_error)))
;;

let settle_success scope on_terminal_disposition value =
  match Execution_agent_scope.finish scope Execution_event.Succeeded with
  | Ok () ->
    notify_terminal scope on_terminal_disposition Terminal_succeeded
    |> Result.map (fun () -> value)
  | Error error ->
    let detail = Execution_agent_scope.error_to_string error in
    let detailed = execution_failure ("run settlement failed: " ^ detail) in
    (match
       Execution_agent_scope.abort
         scope
         (Execution_agent_scope.Failed
            Execution_event.{ kind = Persistence_failure; detail; data = None })
     with
     | Ok () ->
       (match notify_terminal scope on_terminal_disposition Terminal_failed with
        | Ok () -> Error detailed
        | Error notification_error -> Error notification_error)
     | Error abort_error ->
       Error
         (execution_failure
            (Printf.sprintf
               "run settlement failed: %s; abort failed: %s"
               detail
               (Execution_agent_scope.error_to_string abort_error))))
;;

let settle_success_after_run scope on_terminal_disposition value =
  match
    Eio.Cancel.protect (fun () -> settle_success scope on_terminal_disposition value)
  with
  | result -> result
  | exception exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    abort_after_exception scope on_terminal_disposition exn backtrace
;;

let with_scope ?on_terminal_disposition scope run =
  Execution_context.with_agent_scope scope (fun () ->
    match run () with
    | Ok value -> settle_success_after_run scope on_terminal_disposition value
    | Error detailed -> abort_error scope on_terminal_disposition detailed
    | exception exn ->
      let backtrace = Printexc.get_raw_backtrace () in
      abort_after_exception scope on_terminal_disposition exn backtrace)
;;

let prepare_scope store on_terminal_disposition scope =
  let locator = Execution_agent_scope.scope_locator scope in
  match store.on_scope_ready with
  | None -> Ok ()
  | Some persist ->
    (match persist locator with
     | result -> result
     | exception exn ->
       let backtrace = Printexc.get_raw_backtrace () in
       abort_after_exception scope on_terminal_disposition exn backtrace)
;;

let captured_terminal_sink store captured =
  Option.map
    (fun _ disposition ->
       match !captured with
       | None ->
         captured := Some disposition;
         Ok ()
       | Some _ -> Error "terminal disposition emitted more than once")
    store.on_terminal_disposition
;;

let deliver_captured_terminal store captured =
  match store.on_terminal_disposition, !captured with
  | Some persist, Some disposition -> persist_terminal_disposition persist disposition
  | None, None | None, Some _ | Some _, None -> Ok ()
;;

let finish_writer_scope store captured run_writer =
  match run_writer () with
  | Ok result ->
    (match Eio.Cancel.protect (fun () -> deliver_captured_terminal store captured) with
     | Ok () -> result
     | Error notification_error -> Error notification_error)
  | Error failure ->
    Error (execution_failure (Execution_lane_writer.scope_failure_to_string failure))
  | exception exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    (match Eio.Cancel.protect (fun () -> deliver_captured_terminal store captured) with
     | Ok () -> Printexc.raise_with_backtrace exn backtrace
     | Error notification_error ->
       reraise_after_abort_failure
         exn
         backtrace
         (Error.to_string notification_error.Provider_failure_attribution.error)
     | exception notification_exn ->
       let notification_backtrace = Printexc.get_raw_backtrace () in
       (match Llm_provider.Reserved_exn.reraise_if_reserved exn with
        | () ->
          let combined, combined_backtrace =
            Eio.Exn.combine (exn, backtrace) (notification_exn, notification_backtrace)
          in
          Printexc.raise_with_backtrace combined combined_backtrace
        | exception reserved ->
          Eio.traceln
            "durable execution terminal sink raised while preserving reserved exception: \
             %s"
            (Printexc.to_string notification_exn);
          Printexc.raise_with_backtrace reserved backtrace))
;;

let with_fresh store agent run =
  let captured : terminal_disposition option ref = ref None in
  let on_terminal_disposition = captured_terminal_sink store captured in
  finish_writer_scope store captured (fun () ->
    Execution_lane_writer.run ~codec:store.codec ~dir:store.dir
    @@ fun ~sw writer ->
    match
      Execution_agent_scope.start ~writer ~agent_name:agent.Agent_types.state.config.name
    with
    | Error error ->
      Error (execution_failure (Execution_agent_scope.error_to_string error))
    | Ok scope ->
      let ready = prepare_scope store on_terminal_disposition scope in
      (match ready with
       | Error detail ->
         abort_error
           scope
           on_terminal_disposition
           (execution_failure ("scope locator sink failed: " ^ detail))
       | Ok () -> with_scope ?on_terminal_disposition scope (fun () -> run ~sw scope)))
;;

let with_resumed store locator agent run =
  let captured : terminal_disposition option ref = ref None in
  let on_terminal_disposition = captured_terminal_sink store captured in
  finish_writer_scope store captured (fun () ->
    Execution_lane_writer.resume ~codec:store.codec ~dir:store.dir
    @@ fun ~sw writer ->
    match Execution_lane_writer.await_ready writer with
    | Error failure ->
      Error (execution_failure (Execution_lane_writer.scope_failure_to_string failure))
    | Ok () ->
      (match
         Execution_agent_scope.resume_running
           ~writer
           ~agent_name:agent.Agent_types.state.config.name
           locator
       with
       | Error error ->
         Error (execution_failure (Execution_agent_scope.error_to_string error))
       | Ok scope ->
         (match prepare_scope store on_terminal_disposition scope with
          | Error detail ->
            abort_error
              scope
              on_terminal_disposition
              (execution_failure ("scope locator sink failed: " ^ detail))
          | Ok () ->
            Execution_context.with_resume_once (fun () ->
              with_scope ?on_terminal_disposition scope (fun () -> run ~sw scope)))))
;;

let with_store store agent run =
  match store.mode with
  | Fresh -> with_fresh store agent run
  | Resume locator -> with_resumed store locator agent run
;;

let is_resume store =
  match store.mode with
  | Fresh -> false
  | Resume _ -> true
;;
