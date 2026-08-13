module Core = Keeper_agent_core_execution_inventory_core
module Identity = Keeper_agent_core_execution_identity

let expect_identity = function
  | Ok identity -> identity
  | Error error -> failwith (Identity.error_to_string error)
;;

let operation_id =
  Identity.create
    ~keeper_name:"inventory-test"
    ~trace_id:"trace-inventory"
    ~keeper_turn_id:7
    ~runtime_id:"glm.coding-plan"
    ~candidate_index:0
    ~context_shrink_attempt:0
    ~context_capacity_bytes:4096
    ~thinking_override:None
  |> expect_identity
  |> Identity.operation_id
;;

let retired =
  { Agent_core.Agent.outcome = Agent_core.Agent.Terminal_succeeded
  ; recovery = Agent_core.Agent.Retire
  }
;;

let repair_required =
  { Agent_core.Agent.outcome = Agent_core.Agent.Terminal_failed
  ; recovery =
      Agent_core.Agent.Operator_repair_required
        Agent_core.Agent.Effect_outcome_unknown
  }
;;

let assert_state label expected actual =
  if expected <> actual then failwith (label ^ " produced the wrong typed state")
;;

let contains haystack needle =
  let haystack_length = String.length haystack in
  let needle_length = String.length needle in
  let rec loop offset =
    if offset + needle_length > haystack_length
    then false
    else if String.sub haystack offset needle_length = needle
    then true
    else loop (offset + 1)
  in
  needle_length = 0 || loop 0
;;

let () =
  assert_state
    "active"
    Core.Active
    (Core.classify ~locator:Core.Locator_valid ~terminal:Core.Terminal_missing);
  assert_state
    "terminal"
    (Core.Terminal retired)
    (Core.classify
       ~locator:Core.Locator_missing
       ~terminal:(Core.Terminal_valid retired));
  assert_state
    "repair required"
    (Core.Operator_repair_required repair_required)
    (Core.classify
       ~locator:Core.Locator_valid
       ~terminal:(Core.Terminal_valid repair_required));
  assert_state
    "retire interrupted"
    (Core.Ambiguous Core.Retired_terminal_with_locator)
    (Core.classify
       ~locator:Core.Locator_valid
       ~terminal:(Core.Terminal_valid retired));
  assert_state
    "repair locator missing"
    (Core.Ambiguous Core.Repair_terminal_without_locator)
    (Core.classify
       ~locator:Core.Locator_missing
       ~terminal:(Core.Terminal_valid repair_required));
  assert_state
    "both records corrupt"
    (Core.Corrupt Core.Both_records_invalid)
    (Core.classify ~locator:Core.Locator_invalid ~terminal:Core.Terminal_invalid);
  let secret_entry_name = "raw-prompt-hidden-CoT-secret" in
  let projection =
    Core.create
      [ Core.operation_entry operation_id Core.Active
      ; Core.unrecognized_entry ~entry_name:secret_entry_name
      ]
    |> Core.to_yojson
    |> Yojson.Safe.to_string
  in
  if contains projection secret_entry_name
  then failwith "operator projection exposed an unrecognized raw entry name";
  if contains projection "prompt" || contains projection "CoT"
  then failwith "operator projection exposed forbidden reasoning or payload data";
  print_endline "test_keeper_agent_core_execution_inventory_core: OK"
;;
