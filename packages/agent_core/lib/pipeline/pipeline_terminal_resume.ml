open Types
open Agent_types
open Result_syntax

let replay ~persist_checkpoint ~refusal agent ~response ~turn ~invocations ~tool_results tool_uses =
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
     conversion as a live turn's results. They carry no
     [Tool_results_appended_at] stamp: the journal does not keep when they
     settled, and the replay time would make them look new. *)
  let* history_results =
    Agent_turn.make_tool_results ~media_store:agent.media_store report.completed_results
  in
  (* The refusal note rides with the results, as on the fresh path, so a
     crash between settling and the checkpoint does not drop it (#32715). *)
  update_state agent (fun state ->
    let with_results = Util.snoc state.messages (make_message ~role:Tool history_results) in
    { state with
      messages =
        (match refusal with
         | None -> with_results
         | Some note -> Util.snoc with_results note)
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
