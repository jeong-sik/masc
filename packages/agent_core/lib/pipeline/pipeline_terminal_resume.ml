open Types
open Agent_types
open Result_syntax

let replay ~persist_checkpoint agent ~response ~turn ~invocations ~tool_results tool_uses =
  let* report =
    Pipeline_terminal_tool.recovered_report
      ~response
      ~turn
      ~invocations
      ~tool_results
      tool_uses
  in
  let tool_uses_list = Nonempty.to_list tool_uses in
  (* The journal's settled results enter history here, through the same
     conversion as a live turn's results. *)
  let* history_results =
    Agent_turn.make_tool_results ~media_store:agent.media_store report.completed_results
  in
  update_state agent (fun state ->
    { state with
      messages = Util.snoc state.messages (make_message ~role:Tool history_results)
    });
  let base_state = agent.state in
  let* () = persist_checkpoint After_tool_results_appended base_state in
  let finish = Pipeline_terminal_tool.outcome ~response report.Agent_tools.completion in
  match agent.options.context_injector with
  | None -> finish After_tool_results_appended
  | Some injector ->
    let* injection =
      Agent_turn.apply_context_injection
        ~context:agent.context
        ~messages:agent.state.messages
        ~injector
        ~tool_uses:tool_uses_list
        ~results:report.completed_results
      |> Result.map_error (fun error ->
        Error.Internal
          (Printf.sprintf
             "context injector failed%s: %s"
             (match error.Agent_turn.tool_name with
              | Some name -> " for tool " ^ name
              | None -> "")
             error.detail))
    in
    (match injection with
     | Agent_turn.No_injection -> finish After_tool_results_appended
     | Agent_turn.Injected messages ->
       let injected_state = { agent.state with messages } in
       set_state agent injected_state;
       let* () = persist_checkpoint After_context_injection injected_state in
       finish After_context_injection)
;;
