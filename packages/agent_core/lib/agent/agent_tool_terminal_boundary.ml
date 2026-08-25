open Types
open Agent_tool_execution_types
open Result_syntax

let tool_use_blocks blocks =
  List.filter_map
    (function
      | ToolUse { id; name; input } -> Some (id, name, input)
      | Text _
      | Thinking _
      | ReasoningDetails _
      | RedactedThinking _
      | ToolResult _
      | Image _
      | Document _
      | Audio _ -> None)
    blocks
;;

let execute_handler ~tool ~name run =
  try run () with
  | exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    Llm_provider.Reserved_exn.reraise_if_reserved exn;
    (match Tool.completion tool with
     | Tool_contract.Terminal_after_success _ ->
       Printexc.raise_with_backtrace exn backtrace
     | Tool_contract.Continue_after_success ->
       Error
         { message = Printf.sprintf "Tool '%s' raised: %s" name (Printexc.to_string exn)
         ; recoverable = false
         ; error_class = Some Types.Unknown
         })
;;

let completed_dispatch completion (dispatch : tool_dispatch option) =
  match dispatch with
  | Some { result = { outcome = Tool_succeeded; invocation; _ }; _ } ->
    (match completion with
     | Tool_contract.Terminal_after_success _ -> Terminal_completed invocation
     | Tool_contract.Continue_after_success -> Continue_after_batch)
  | Some
      { result = { outcome = Tool_failed { failure_kind = Validation_error; _ }; _ }; _ }
    -> Continue_after_batch
  | Some { result = { outcome = Tool_failed _; invocation; content; _ }; _ } ->
    (match completion with
     | Tool_contract.Terminal_after_success Tool_contract.Proven_pre_effect ->
       Continue_after_batch
     | Tool_contract.Terminal_after_success
         ((Tool_contract.Proven_post_effect | Tool_contract.Effect_outcome_unknown) as
          effect_disposition) ->
       Terminal_failed { invocation; effect_disposition; detail = content }
     | Tool_contract.Continue_after_success -> Continue_after_batch)
  | None -> Continue_after_batch
;;

let rejected_results ~turn ~schedule ~completion ~id ~name ~input scheduled =
  let content =
    "Terminal tool admission rejected: a terminal tool must be the only tool call in the \
     provider turn"
  in
  List.map
    (fun tool_use ->
       let invocation =
         Tool_contract.Invocation.create
           ~tool_use_id:(id tool_use)
           ~turn
           ~schedule:(schedule tool_use)
           ~completion:(completion tool_use)
       in
       { invocation
       ; tool_name = name tool_use
       ; input = input tool_use
       ; content
       ; outcome =
           Tool_failed
             { failure_kind = Validation_error; error_class = Some Types.Deterministic }
       })
    scheduled
;;

let rejected_report ~turn ~schedule ~completion ~id ~name ~input scheduled =
  { completed_results =
      rejected_results ~turn ~schedule ~completion ~id ~name ~input scheduled
  ; completion = Continue_after_batch
  }
;;

let recovered_batch_completion ~invocations tool_results =
  let result_by_id =
    List.filter_map
      (function
        | ToolResult { tool_use_id; content; outcome; _ } ->
          Some (tool_use_id, (content, outcome))
        | Text _
        | Thinking _
        | ReasoningDetails _
        | RedactedThinking _
        | ToolUse _
        | Image _
        | Document _
        | Audio _ -> None)
      tool_results
  in
  let terminal_invocations =
    List.filter
      (fun invocation ->
         match Tool_contract.Invocation.completion invocation with
         | Tool_contract.Terminal_after_success _ -> true
         | Tool_contract.Continue_after_success -> false)
      invocations
  in
  match invocations, terminal_invocations with
  | _, [] -> Ok Continue_after_batch
  | [ invocation ], [ terminal_invocation ] ->
    let schedule = Tool_contract.Invocation.schedule terminal_invocation in
    let* () =
      Execution_tool_schedule.validate_completion
        ~completion:(Tool_contract.Invocation.completion terminal_invocation)
        schedule
      |> Result.map_error (fun _ ->
        Error.Internal "persisted terminal invocation violates singleton admission")
    in
    if
      not
        (String.equal
           (Tool_contract.Invocation.tool_use_id invocation)
           (Tool_contract.Invocation.tool_use_id terminal_invocation))
    then
      Error
        (Error.Internal
           "persisted terminal invocation identity differs from terminal authority")
    else (
      let tool_use_id = Tool_contract.Invocation.tool_use_id invocation in
      match List.assoc_opt tool_use_id result_by_id with
      | None ->
        Error
          (Error.Internal ("missing durable result for terminal invocation " ^ tool_use_id))
      | Some (_, Tool_succeeded) -> Ok (Terminal_completed invocation)
      | Some (_, Tool_failed { failure_kind = Validation_error; _ }) ->
        Ok Continue_after_batch
      | Some (detail, Tool_failed _) ->
        (match Tool_contract.Invocation.completion invocation with
         | Tool_contract.Terminal_after_success Tool_contract.Proven_pre_effect ->
           Ok Continue_after_batch
         | Tool_contract.Terminal_after_success
             ((Tool_contract.Proven_post_effect | Tool_contract.Effect_outcome_unknown) as
              effect_disposition) ->
           Ok (Terminal_failed { invocation; effect_disposition; detail })
         | Tool_contract.Continue_after_success ->
           Error
             (Error.Internal "persisted terminal invocation lost its terminal completion")))
  | _, [ _ ] ->
    Error
      (Error.Internal "persisted terminal invocation is mixed with an ordinary invocation")
  | _, _ :: _ :: _ ->
    Error
      (Error.Internal
         "multiple persisted terminal invocations violate singleton admission")
;;
