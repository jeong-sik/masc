module Program = Keeper_memory_os_program
module Source = Keeper_librarian_unread
open Result.Syntax

let digest = function
  | Source.Atom {message_sha256;_} | Source.Official_turn {message_sha256;_} -> message_sha256

let decision ~sources (step : Keeper_librarian_runtime.memory_step) =
  let input = step.source_input in
  let* () = match sources, input.messages with
    | [], [] ->
      if input.tool_observations <> [] || input.counterpart_observations <> [] then Ok ()
      else Error "a message-free Memory decision requires actual host observations"
    | [], _ :: _ | _ :: _, ([] | _ :: _) -> Ok () in
  let rec bind sources messages =
    match sources, messages with
    | [], [] -> Ok ()
    | source :: sources, message :: messages ->
      let* _ = Source.source_of_json (Source.source_to_json source) in
      if digest source = Source.message_digest message then bind sources messages
      else Error "Memory program source hash differs from the judged message"
    | [], _ :: _ | _ :: _, [] -> Error "Memory program sources do not match the judged message count"
  in
  let* () = bind sources input.messages in
  Ok {Program.run_id=step.run_id; keeper_id=input.keeper_id; turn_ref=input.turn_ref;
    input_current=Option.map
      (fun (current : Keeper_librarian.current_selection) -> current.facts) input.current;
    sources;
    input_evidence=`Assoc [
      "rendered_base_prompt", `String step.rendered_prompt;
      "prompt_variables", `Assoc (List.map (fun (key,value) -> key,`String value) step.prompt_variables);
      "messages", `List (List.map Agent_core.Checkpoint.message_to_json input.messages);
      "observations", `List (Keeper_librarian.observations_for_absorption input)];
    gate_evidence=Keeper_librarian_absorb_gate.run_result_to_yojson step.absorb_gate;
    working_state=step.working_state; new_claims=step.new_claims; dropped=step.dropped;
    absorbed=step.absorbed; revisions=step.revisions}

let create ~transaction_id ~keeper_id ~turn_ref ~sources ~unread ~initial_current ~steps =
  let rec bind acc = function
    | [] -> Ok (List.rev acc)
    | (sources,step) :: rest ->
      let* accepted = decision ~sources step in
      bind (accepted::acc) rest
  in
  let* decisions = bind [] steps in
  Program.create ~transaction_id ~keeper_id ~turn_ref ~sources ~unread ~initial_current ~decisions
