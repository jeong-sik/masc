type lane =
  | Direct
  | Autonomous of Keeper_world_observation.keeper_cycle_channel

type terminal =
  | Completed
  | Checkpointed
  | Input_required

type t =
  { lane : lane
  ; result : Keeper_agent_run.run_result
  ; terminal : terminal
  }

let terminal_of_stop_reason = function
  | Runtime_agent.Completed -> Completed
  | Runtime_agent.Yielded_to_operation_queued _
  | Runtime_agent.Yielded_to_durable_stimulus _
  | Runtime_agent.Yielded_after_repeated_tool_call _
  | Runtime_agent.Yielded_after_repeated_assistant_text _ ->
    Checkpointed
  | Runtime_agent.InputRequired _ -> Input_required
;;

let create ~lane result =
  { lane; terminal = terminal_of_stop_reason result.Keeper_agent_run.stop_reason; result }
;;

let lane t = t.lane
let result t = t.result
let response_text t = t.result.Keeper_agent_run.response_text
let completion_contract_result t =
  t.result.Keeper_agent_run.completion_contract_result
;;


let terminal t = t.terminal

let is_autonomous t =
  match t.lane with
  | Direct -> false
  | Autonomous _ -> true
;;

let metrics_channel t =
  match t.lane with
  | Direct -> Keeper_world_observation.Reactive
  | Autonomous channel -> channel
;;
