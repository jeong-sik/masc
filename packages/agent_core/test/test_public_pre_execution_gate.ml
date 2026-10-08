(* This host-facing API must not require private scheduling/settlement CMIs. *)
module Gate = Agent_core.Agent_tool_pre_execution_gate
module Contract = Agent_core.Tool_contract
module Hooks = Agent_core.Hooks

let () =
  let invocation = Contract.Invocation.create ~tool_use_id:"public-consumer" ~turn:1
    ~schedule:{ planned_index = 0; batch_index = 0; batch_size = 1; execution_mode = Serial }
    ~completion:Continue_after_success in
  let settle ?tool_approval decision =
    Gate.settle ?tool_approval ~event_bus:None ~agent_name:"public-consumer"
      ~invocation ~tool_name:"read" ~input:(`Assoc []) decision in
  (match settle Hooks.Continue with Gate.Admit -> () | _ -> failwith "continue was not admitted");
  (match settle (Hooks.Block "held") with Gate.Block "held" -> () | _ -> failwith "block was not preserved");
  let prompt = Hooks.ElicitToolApproval { question = "Read?"; because = "fixture" } in
  (match settle prompt with
   | Gate.Reject { stage = Hooks.Pre_tool_use; _ } -> ()
   | _ -> failwith "missing approval callback was not rejected");
  let called = ref false in
  let tool_approval (request : Hooks.tool_approval_request) =
    called := true;
    if Contract.Invocation.tool_use_id request.invocation <> "public-consumer"
    then failwith "approval lost invocation ownership";
    Hooks.Approved in
  (match settle ~tool_approval prompt with Gate.Admit -> () | _ -> failwith "approval was not admitted");
  if not !called then failwith "approval callback was skipped";
  print_endline "Public pre-execution gate consumer: PASS"
