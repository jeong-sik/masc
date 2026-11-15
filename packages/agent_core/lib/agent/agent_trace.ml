open Types
open Agent_types

let _log = Log.create ~module_name:"agent_trace" ()

(* Failure reporting is an observer too. Never turn a diagnostic sink failure
   into a new execution outcome; cancellation/runtime exceptions still escape. *)
let report_observer_failure report message fields =
  try report _log message fields with
  | exn -> Llm_provider.Reserved_exn.reraise_if_reserved exn
;;

(* Which raw-trace record a write belonged to.  The trace is diagnostic
   evidence, never execution authority: the provider response, the tool result
   and the hook decision are already decided when their record is written. *)
type trace_boundary =
  | Hook_invocation
  | Tool_execution_started
  | Tool_execution_finished
  | Assistant_block of int

let trace_boundary_fields = function
  | Hook_invocation -> [ Log.S ("trace_boundary", "hook_invocation") ]
  | Tool_execution_started -> [ Log.S ("trace_boundary", "tool_execution_started") ]
  | Tool_execution_finished -> [ Log.S ("trace_boundary", "tool_execution_finished") ]
  | Assistant_block block_index ->
    [ Log.S ("trace_boundary", "assistant_block"); Log.I ("block_index", block_index) ]
;;

(* A record the sink refused is reported as missing evidence and nothing else:
   it neither fails the stage that produced the fact nor reaches the tool
   dispatcher as an observer failure. *)
let report_missing_trace_record active boundary = function
  | Ok () -> ()
  | Error trace_error ->
    report_observer_failure
      Log.warn
      "raw trace record not written"
      (Log.S ("worker_run_id", Raw_trace.active_run_id active)
       :: Log.S ("trace_error", Error.to_string trace_error)
       :: trace_boundary_fields boundary)
;;

let record_hook_invocation active_run ?invocation ~hook_name ~decision ?detail () =
  match active_run with
  | None -> ()
  | Some active ->
    report_missing_trace_record
      active
      Hook_invocation
      (Raw_trace.record_hook_invoked
         active
         ?invocation
         ~hook_name
         ~hook_decision:(Agent_lifecycle.hook_decision_to_string decision)
         ?hook_detail:detail
         ())
;;

let invoke_hook_with_trace agent ?raw_trace_run ~turn ~hook_name hook_opt event =
  Tracing.with_span
    agent.options.tracer
    { kind = Hook_invoke
    ; name = hook_name
    ; agent_name = agent.state.config.name
    ; turn
    ; extra = []
    ; links = []
    }
    (fun _ ->
       let decision = Hooks.invoke_validated ~hook_name hook_opt event in
       record_hook_invocation
         raw_trace_run
         ?invocation:(Hooks.invocation_of_event event)
         ~hook_name
         ~decision
         ();
       decision)
;;

let execute_tools_with_trace agent active_run ~turn ?before_tool_execution tool_uses =
  let correlation_id = Option.bind agent.options.raw_trace Raw_trace.session_id in
  let run_id = Option.map Raw_trace.active_run_id active_run in
  let tools = Tool_set.to_list agent.tools in
  let on_tool_execution_started =
    match active_run with
    | None -> None
    | Some active ->
      Some
        (fun ~invocation ~tool_name ~input ->
          let ts = Unix.gettimeofday () in
          set_lifecycle
            agent
            ~current_run_id:(Raw_trace.active_run_id active)
            ~first_progress_at:ts
            ~last_progress_at:ts
            Running;
          report_missing_trace_record
            active
            Tool_execution_started
            (Raw_trace.record_tool_execution_started
               active
               ~invocation
               ~tool_name
               ~tool_input:input))
  in
  let on_tool_execution_finished =
    match active_run with
    | None -> None
    | Some active ->
      Some
        (fun ~invocation ~tool_name ~content ~is_error ->
          let ts = Unix.gettimeofday () in
          set_lifecycle
            agent
            ~current_run_id:(Raw_trace.active_run_id active)
            ~first_progress_at:ts
            ~last_progress_at:ts
            Running;
          report_missing_trace_record
            active
            Tool_execution_finished
            (Raw_trace.record_tool_execution_finished
               active
               ~invocation
               ~tool_name
               ~tool_result:content
               ~tool_error:is_error
               ()))
  in
  let on_hook_invoked ~invocation ~hook_name ~decision ~detail =
    record_hook_invocation active_run ?invocation ~hook_name ~decision ?detail ()
  in
  Agent_tools.execute_tools
    ~context:agent.context
    ~tools
    ~hooks:agent.options.hooks
    ?tool_approval:agent.options.tool_approval
    ~event_bus:agent.options.event_bus
    ~tracer:agent.options.tracer
    ~agent_name:agent.state.config.name
    ~turn_count:turn
    ~usage:agent.state.usage
    ?correlation_id
    ?run_id
    ?on_tool_execution_started
    ?on_tool_execution_finished
    ~on_hook_invoked
    ?before_tool_execution
    tool_uses
;;

let trace_assistant_blocks active_run blocks =
  match active_run with
  | None -> ()
  | Some active ->
    List.iteri
      (fun block_index block ->
         report_missing_trace_record
           active
           (Assistant_block block_index)
           (Raw_trace.record_assistant_block active ~block_index block))
      blocks
;;

(** Invoke the optional [on_run_complete] callback.
    Exceptions are caught and logged to prevent finalization failures
    from masking the actual run result.  Reserved exceptions
    ([Out_of_memory], [Stack_overflow], [Sys.Break],
    [Eio.Cancel.Cancelled]) still propagate; see
    {!Llm_provider.Reserved_exn}. *)
let invoke_on_run_complete agent ~ok =
  match agent.options.on_run_complete with
  | None -> ()
  | Some cb ->
    (try cb ok with
     | exn ->
       Llm_provider.Reserved_exn.reraise_if_reserved exn;
       report_observer_failure Log.warn
         "on_run_complete callback raised"
         [ Log.S ("error", Printexc.to_string exn) ])
;;

let final_text_of_response response =
  let text = Types.text_of_response response in
  if String.trim text = "" then None else Some text
;;

type trace_success =
  | Run_completed of
      { final_text : string option
      ; stop_reason : string option
      }
  | Run_yielded of { stop_reason : string }

let%test "raw trace final_text excludes thinking blocks" =
  let response =
    { Types.id = "resp"
    ; model = "model"
    ; unreadable_tool_uses = []
    ; stop_reason = EndTurn
    ; content =
        [ Thinking { signature = None; content = "private reasoning" }
        ; Text "visible answer"
        ]
    ; usage = None
    ; telemetry = None
    }
  in
  final_text_of_response response = Some "visible answer"
;;

let%test "raw trace final_text is absent for thinking-only responses" =
  let response =
    { Types.id = "resp"
    ; model = "model"
    ; unreadable_tool_uses = []
    ; stop_reason = EndTurn
    ; content = [ Thinking { signature = None; content = "private reasoning" } ]
    ; usage = None
    ; telemetry = None
    }
  in
  final_text_of_response response = None
;;

let with_raw_trace_run_classified_result
      ~of_core_error
      ~error_to_string
      ~classify_success
      agent
      user_prompt
      f
  =
  (* Reset lifecycle so each run() starts fresh — allows agent reuse
     after Completed/Failed without hitting invalid transition. *)
  Eio.Mutex.use_rw ~protect:true agent.mu (fun () -> agent.lifecycle <- None);
  let set_lifecycle_for_result result =
    match result with
    | Error err ->
      set_lifecycle
        agent
        ~finished_at:(Unix.gettimeofday ())
        ~last_error:(error_to_string err)
        Failed
    | Ok value ->
      (match classify_success value with
       | Run_completed _ ->
         set_lifecycle agent ~finished_at:(Unix.gettimeofday ()) Completed
       | Run_yielded _ -> set_lifecycle agent ~ready_at:(Unix.gettimeofday ()) Ready)
  in
  let invoke_completion_for_result result =
    match result with
    | Error _ -> invoke_on_run_complete agent ~ok:false
    | Ok value ->
      (match classify_success value with
       | Run_completed _ -> invoke_on_run_complete agent ~ok:true
       | Run_yielded _ -> ())
  in
  match agent.options.raw_trace with
  | None ->
    let ts = Unix.gettimeofday () in
    set_lifecycle agent ~accepted_at:ts ~started_at:ts Accepted;
    let result = f None in
    (* Contract (agent_types.mli): on_run_complete runs *before* lifecycle is
       updated, so completion hooks observe the pre-terminal run state.
       Reserved exceptions (e.g. Eio.Cancel.Cancelled) still propagate, but the
       terminal lifecycle transition must not be skipped. *)
    (try invoke_completion_for_result result with
     | exn ->
       set_lifecycle_for_result result;
       raise exn);
    set_lifecycle_for_result result;
    result
  | Some sink ->
    (match
       Raw_trace.start_run
         sink
         ~agent_name:agent.state.config.name
         ~prompt:user_prompt
         ~model:agent.state.config.model
         ?tool_choice:agent.state.config.tool_choice
         ?enable_thinking:agent.state.config.enable_thinking
         ?preserve_thinking:agent.state.config.preserve_thinking
         ?reasoning_effort:
           (Option.map
              Llm_provider.Reasoning_effort.to_string
              agent.state.config.reasoning_effort)
         ()
     with
     | Error error -> Error (of_core_error error)
     | Ok active ->
       let ts = Unix.gettimeofday () in
       set_lifecycle
         agent
         ~current_run_id:(Raw_trace.active_run_id active)
         ~accepted_at:ts
         ~started_at:ts
         Accepted;
       let finalize result =
         let final_text, stop_reason, error =
           match result with
           | Ok value ->
             (match classify_success value with
              | Run_completed { final_text; stop_reason } -> final_text, stop_reason, None
              | Run_yielded { stop_reason } -> None, Some stop_reason, None)
           | Error err -> None, None, Some (error_to_string err)
         in
         (* Raw trace is finished first (so a reserved exception re-raised from the
         callback cannot leave the trace open), then on_run_complete runs before
         the lifecycle transition per the agent_types.mli contract. *)
         Fun.protect
           ~finally:(fun () -> set_lifecycle_for_result result)
           (fun () ->
             (match Raw_trace.finish_run active ~final_text ~stop_reason ~error with
              | Ok _ -> ()
              | Error trace_error ->
                report_observer_failure Log.error
                  "raw trace finalization failed after run result"
                  [ Log.S ("worker_run_id", Raw_trace.active_run_id active)
                  ; Log.S ("finalization_error", Error.to_string trace_error)
                  ]);
             invoke_completion_for_result result;
             result)
       in
       (match f (Some active) with
        | result -> finalize result
        | exception exn ->
          let backtrace = Printexc.get_raw_backtrace () in
          (* The trace field is a string, so the classification has to be
             rendered rather than carried — but it is the same classification
             the lifecycle event publishes, so a raw trace and its event cannot
             describe the same failure differently. A timeout reads as one here
             instead of as an unhandled exception. *)
          let error_msg = Error.to_string (Error.of_raised_exn exn) in
          Fun.protect
            ~finally:(fun () ->
              set_lifecycle agent ~finished_at:(Unix.gettimeofday ())
                ~last_error:error_msg Failed)
            (fun () ->
              (match Raw_trace.finish_run active ~final_text:None ~stop_reason:None
                       ~error:(Some error_msg) with
               | Ok _ -> ()
               | Error trace_error ->
                 report_observer_failure Log.error
                   "raw trace finalization failed after run exception"
                   [ Log.S ("worker_run_id", Raw_trace.active_run_id active)
                   ; Log.S ("primary_exception", Printexc.to_string exn)
                   ; Log.S ("finalization_error", Error.to_string trace_error)
                   ]);
              Printexc.raise_with_backtrace exn backtrace)))
;;

let with_raw_trace_run_result ~of_core_error ~error_to_string agent user_prompt f =
  with_raw_trace_run_classified_result
    ~of_core_error
    ~error_to_string
    ~classify_success:(fun response ->
      Run_completed
        { final_text = final_text_of_response response
        ; stop_reason = Some (Types.show_stop_reason response.stop_reason)
        })
    agent
    user_prompt
    f
;;
