(** Wrap MASC client operations as Agent SDK tools.

    masc_join/masc_leave are lifecycle functions, not exposed as tools.
    Agents should not arbitrarily leave the room.

    The tool surface stays close to current MASC task semantics:
    - claim and current_task binding are distinct
    - claim_next/batch_add_tasks enable planner->worker fleet flows
    - release/cancel are explicit escape hatches for blocked tasks *)

let make_tools (client : Agent_swarm_client.t) ~sw : Agent_sdk.Tool.t list =
  let open Agent_sdk.Tool in

  let masc_list_tasks = create
    ~name:"masc_list_tasks"
    ~description:"List all tasks in the MASC room."
    ~parameters:[]
    (fun _input ->
      match Agent_swarm_client.list_tasks ~sw client with
      | Ok json -> Ok (Agent_swarm_tool_input.json_to_string json)
      | Error e -> Error e)
  in

  let masc_room_status = create
    ~name:"masc_room_status"
    ~description:"Get the current MASC room status including agents and tasks."
    ~parameters:[]
    (fun _input ->
      match Agent_swarm_client.status ~sw client with
      | Ok json -> Ok (Agent_swarm_tool_input.json_to_string json)
      | Error e -> Error e)
  in

  let masc_add_task = create
    ~name:"masc_add_task"
    ~description:"Create a single new task in the MASC room."
    ~parameters:[
      { name = "title"; description = "Task title"; param_type = Agent_sdk.Types.String; required = true };
      { name = "description"; description = "Task description"; param_type = Agent_sdk.Types.String; required = true };
    ]
    (fun input ->
      match
        ( Agent_swarm_tool_input.extract_string "title" input,
          Agent_swarm_tool_input.extract_string "description" input )
      with
      | Error e, _ | _, Error e -> Error e
      | Ok title, Ok description ->
        (match Agent_swarm_client.add_task ~sw client ~title ~description with
         | Ok json -> Ok (Agent_swarm_tool_input.json_to_string json)
         | Error e -> Error e))
  in

  let masc_batch_add_tasks = create
    ~name:"masc_batch_add_tasks"
    ~description:"Create multiple tasks at once for planner-driven decomposition."
    ~parameters:[
      { name = "tasks";
        description = "Array of {title, description} task objects";
        param_type = Agent_sdk.Types.String;
        required = true };
    ]
    (fun input ->
      match Agent_swarm_tool_input.extract_tasks_array input with
      | Error e -> Error e
      | Ok tasks ->
        (match Agent_swarm_client.batch_add_tasks ~sw client ~tasks with
         | Ok json -> Ok (Agent_swarm_tool_input.json_to_string json)
         | Error e -> Error e))
  in

  let masc_claim_task = create
    ~name:"masc_claim_task"
    ~description:"Claim a specific task by task_id."
    ~parameters:[{
      name = "task_id";
      description = "The task ID to claim";
      param_type = Agent_sdk.Types.String;
      required = true;
    }]
    (fun input ->
      match Agent_swarm_tool_input.extract_string "task_id" input with
      | Error e -> Error e
      | Ok task_id ->
        (match Agent_swarm_client.claim ~sw client ~task_id with
         | Ok json -> Ok (Agent_swarm_tool_input.json_to_string json)
         | Error e -> Error e))
  in

  let masc_claim_next = create
    ~name:"masc_claim_next"
    ~description:"Claim the next available task automatically."
    ~parameters:[]
    (fun _input ->
      match Agent_swarm_client.claim_next ~sw client with
      | Ok json -> Ok (Agent_swarm_tool_input.json_to_string json)
      | Error e -> Error e)
  in

  let masc_set_current_task = create
    ~name:"masc_set_current_task"
    ~description:"Bind the claimed task as current_task after a claim step."
    ~parameters:[{
      name = "task_id";
      description = "The claimed task ID to bind as the current planning task";
      param_type = Agent_sdk.Types.String;
      required = true;
    }]
    (fun input ->
      match Agent_swarm_tool_input.extract_string "task_id" input with
      | Error e -> Error e
      | Ok task_id ->
        (match Agent_swarm_client.set_current_task ~sw client ~task_id with
         | Ok json -> Ok (Agent_swarm_tool_input.json_to_string json)
         | Error e -> Error e))
  in

  let masc_complete_task = create
    ~name:"masc_complete_task"
    ~description:"Mark a task as done after finishing the work."
    ~parameters:[{
      name = "task_id";
      description = "The task ID to mark as completed";
      param_type = Agent_sdk.Types.String;
      required = true;
    }]
    (fun input ->
      match Agent_swarm_tool_input.extract_string "task_id" input with
      | Error e -> Error e
      | Ok task_id ->
        (match Agent_swarm_client.done_task ~sw client ~task_id with
         | Ok json -> Ok (Agent_swarm_tool_input.json_to_string json)
         | Error e -> Error e))
  in

  let masc_release_task = create
    ~name:"masc_release_task"
    ~description:"Release a claimed task back to pending for another worker."
    ~parameters:[{
      name = "task_id";
      description = "The task ID to release";
      param_type = Agent_sdk.Types.String;
      required = true;
    }]
    (fun input ->
      match Agent_swarm_tool_input.extract_string "task_id" input with
      | Error e -> Error e
      | Ok task_id ->
        (match Agent_swarm_client.release_task ~sw client ~task_id with
         | Ok json -> Ok (Agent_swarm_tool_input.json_to_string json)
         | Error e -> Error e))
  in

  let masc_cancel_task = create
    ~name:"masc_cancel_task"
    ~description:"Cancel a task permanently when it should not be retried."
    ~parameters:[
      { name = "task_id"; description = "The task ID to cancel"; param_type = Agent_sdk.Types.String; required = true };
      { name = "reason"; description = "Optional cancellation reason"; param_type = Agent_sdk.Types.String; required = false };
    ]
    (fun input ->
      match
        ( Agent_swarm_tool_input.extract_string "task_id" input,
          Agent_swarm_tool_input.extract_optional_string "reason" input )
      with
      | Error e, _ | _, Error e -> Error e
      | Ok task_id, Ok reason ->
        let reason = Option.value ~default:"" reason in
        (match Agent_swarm_client.cancel_task ~sw client ~task_id ~reason with
         | Ok json -> Ok (Agent_swarm_tool_input.json_to_string json)
         | Error e -> Error e))
  in

  let masc_broadcast = create
    ~name:"masc_broadcast"
    ~description:"Broadcast a message to all agents in the room."
    ~parameters:[{
      name = "message";
      description = "The message to broadcast";
      param_type = Agent_sdk.Types.String;
      required = true;
    }]
    (fun input ->
      match Agent_swarm_tool_input.extract_string "message" input with
      | Error e -> Error e
      | Ok message ->
        (match Agent_swarm_client.broadcast ~sw client ~message with
         | Ok json -> Ok (Agent_swarm_tool_input.json_to_string json)
         | Error e -> Error e))
  in

  let masc_send_direct = create
    ~name:"masc_send_direct"
    ~description:"Send a direct message to a specific agent by name."
    ~parameters:[
      { name = "target"; description = "Name of the target agent"; param_type = Agent_sdk.Types.String; required = true };
      { name = "message"; description = "The message content"; param_type = Agent_sdk.Types.String; required = true };
    ]
    (fun input ->
      match
        ( Agent_swarm_tool_input.extract_string "target" input,
          Agent_swarm_tool_input.extract_string "message" input )
      with
      | Error e, _ | _, Error e -> Error e
      | Ok target, Ok message ->
        (match Agent_swarm_client.send_direct ~sw client ~target ~message with
         | Ok json -> Ok (Agent_swarm_tool_input.json_to_string json)
         | Error e -> Error e))
  in

  let masc_heartbeat = create
    ~name:"masc_heartbeat"
    ~description:"Send an immediate heartbeat so this agent stays fresh in MASC visibility."
    ~parameters:[]
    (fun _input ->
      match Agent_swarm_client.heartbeat ~sw client with
      | Ok json -> Ok (Agent_swarm_tool_input.json_to_string json)
      | Error e -> Error e)
  in

  [
    masc_list_tasks;
    masc_room_status;
    masc_add_task;
    masc_batch_add_tasks;
    masc_claim_task;
    masc_claim_next;
    masc_set_current_task;
    masc_complete_task;
    masc_release_task;
    masc_cancel_task;
    masc_broadcast;
    masc_send_direct;
    masc_heartbeat;
  ]
