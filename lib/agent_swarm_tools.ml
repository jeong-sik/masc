(** Wrap MASC client operations as Agent SDK tools.

    masc_join/masc_leave are lifecycle functions, not exposed as tools.
    Agents should not arbitrarily leave the room. *)

(** Create 5 MASC tools that close over the client and switch. *)
let make_tools (client : Agent_swarm_client.t) ~sw : Agent_sdk.Tool.t list =
  let open Agent_sdk.Tool in

  let masc_list_tasks = create
    ~name:"masc_list_tasks"
    ~description:"List all tasks in the MASC room"
    ~parameters:[]
    (fun _input ->
       match Agent_swarm_client.list_tasks ~sw client with
       | Ok json -> Ok (Agent_swarm_tool_input.json_to_string json)
       | Error e -> Error e)
  in

  let masc_claim_task = create
    ~name:"masc_claim_task"
    ~description:"Claim a task by ID so this agent owns it"
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
         match Agent_swarm_client.claim ~sw client ~task_id with
         | Ok json -> Ok (Agent_swarm_tool_input.json_to_string json)
         | Error e -> Error e)
  in

  let masc_set_current_task = create
    ~name:"masc_set_current_task"
    ~description:"Bind the current planning task for this agent after claiming it. Use immediately after masc_claim_task."
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
         match Agent_swarm_client.set_current_task ~sw client ~task_id with
         | Ok json -> Ok (Agent_swarm_tool_input.json_to_string json)
         | Error e -> Error e)
  in

  let masc_broadcast = create
    ~name:"masc_broadcast"
    ~description:"Broadcast a message to all agents in the room"
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
         match Agent_swarm_client.broadcast ~sw client ~message with
         | Ok json -> Ok (Agent_swarm_tool_input.json_to_string json)
         | Error e -> Error e)
  in

  let masc_complete_task = create
    ~name:"masc_complete_task"
    ~description:"Mark a task as done"
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
         match Agent_swarm_client.done_task ~sw client ~task_id with
         | Ok json -> Ok (Agent_swarm_tool_input.json_to_string json)
         | Error e -> Error e)
  in

  let masc_room_status = create
    ~name:"masc_room_status"
    ~description:"Get the current MASC room status including agents and tasks"
    ~parameters:[]
    (fun _input ->
       match Agent_swarm_client.status ~sw client with
       | Ok json -> Ok (Agent_swarm_tool_input.json_to_string json)
       | Error e -> Error e)
  in

  let masc_heartbeat = create
    ~name:"masc_heartbeat"
    ~description:"Send an immediate heartbeat to keep this agent fresh in MASC visibility."
    ~parameters:[]
    (fun _input ->
       match Agent_swarm_client.heartbeat ~sw client with
       | Ok json -> Ok (Agent_swarm_tool_input.json_to_string json)
       | Error e -> Error e)
  in

  let masc_add_task = create
    ~name:"masc_add_task"
    ~description:"Create a new task in the MASC room"
    ~parameters:[
      { name = "title"; description = "Task title"; param_type = Agent_sdk.Types.String; required = true };
      { name = "description"; description = "Task description"; param_type = Agent_sdk.Types.String; required = true };
    ]
    (fun input ->
       match Agent_swarm_tool_input.extract_string "title" input,
             Agent_swarm_tool_input.extract_string "description" input with
       | Error e, _ | _, Error e -> Error e
       | Ok title, Ok desc ->
         match Agent_swarm_client.add_task ~sw client ~title ~description:desc with
         | Ok json -> Ok (Agent_swarm_tool_input.json_to_string json)
         | Error e -> Error e)
  in

  let masc_send_direct = create
    ~name:"masc_send_direct"
    ~description:"Send a direct message to a specific agent by name. Unlike masc_broadcast (room-wide), this is private 1:1 delivery. Use when you need to communicate with a single specific agent rather than all agents."
    ~parameters:[
      { name = "target"; description = "Name of the target agent to send the message to"; param_type = Agent_sdk.Types.String; required = true };
      { name = "message"; description = "The message content to send"; param_type = Agent_sdk.Types.String; required = true };
    ]
    (fun input ->
       match Agent_swarm_tool_input.extract_string "target" input,
             Agent_swarm_tool_input.extract_string "message" input with
       | Error e, _ | _, Error e -> Error e
       | Ok target, Ok message ->
         match Agent_swarm_client.send_direct ~sw client ~target ~message with
         | Ok json -> Ok (Agent_swarm_tool_input.json_to_string json)
         | Error e -> Error e)
  in

  [
    masc_list_tasks;
    masc_claim_task;
    masc_set_current_task;
    masc_add_task;
    masc_broadcast;
    masc_complete_task;
    masc_room_status;
    masc_send_direct;
    masc_heartbeat;
  ]
