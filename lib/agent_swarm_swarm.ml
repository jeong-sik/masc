(** Multi-agent swarm runner with MASC coordination.

    Runs N Agent SDK instances as Eio fibers.
    Each agent joins a MASC room, executes its goal using LLM + tools,
    then leaves the room. *)

open Agent_sdk

type agent_spec = {
  name: string;
  provider: Provider.config;
  system_prompt: string;
  tools: Tool.t list;
  max_turns: int;
}

type swarm_config = {
  masc_url: string;
  agents: agent_spec list;
}

type agent_result = {
  agent_name: string;
  result: (Types.api_response, string) result;
}

(** Run a single agent: join MASC, run LLM loop, leave MASC.
    [extra_tools] are appended after MASC tools (e.g., dev_tools from Fleet). *)
let run_agent ~sw ~net ~masc_url ?(extra_tools=[]) spec ~goal =
  let masc = Agent_swarm_client.create ~net ~base_url:masc_url ~agent_name:spec.name in
  match Agent_swarm_client.join ~sw masc with
  | Error e ->
    { agent_name = spec.name;
      result = Error (Printf.sprintf "MASC join failed: %s" e) }
  | Ok _ ->
    let masc_tools = Agent_swarm_tools.make_tools masc ~sw in
    let all_tools = spec.tools @ masc_tools @ extra_tools in
    let config = {
      Types.default_config with
      name = spec.name;
      model = Types.Custom spec.provider.model_id;
      system_prompt = Some spec.system_prompt;
      max_turns = spec.max_turns;
    } in
    let agent = Agent.create ~net ~config ~tools:all_tools ~provider:spec.provider () in
    let result = Agent.run ~sw agent goal in
    (match Agent_swarm_client.leave ~sw masc with
     | Ok _ -> ()
     | Error e -> Printf.eprintf "[%s] MASC leave warning: %s\n%!" spec.name e);
    { agent_name = spec.name; result }

(** Run all agents in parallel using Eio fibers.
    A heartbeat daemon fiber runs alongside the agents and sends keepalive pings
    to the MASC room every 30 seconds. The heartbeat fiber is automatically
    cancelled when all agent fibers complete (daemon fibers are cancelled
    when the Switch.run body returns).
    If the coordinator fails to join MASC, heartbeat and post-run
    broadcast/leave are skipped. *)
let run ~sw ~net ~clock config ~goal =
  let masc = Agent_swarm_client.create ~net
    ~base_url:config.masc_url
    ~agent_name:"swarm-coordinator" in
  let coordinator_joined =
    match Agent_swarm_client.join ~sw masc with
    | Ok _ ->
      ignore (Agent_swarm_client.broadcast ~sw masc
        ~message:(Printf.sprintf "Fleet starting: %s" goal));
      true
    | Error e ->
      Printf.eprintf "[swarm-coordinator] MASC join warning: %s\n%!" e;
      false
  in
  let results =
    Eio.Switch.run (fun inner_sw ->
      (* Heartbeat fiber: only started if coordinator joined successfully. *)
      if coordinator_joined then
        Eio.Fiber.fork_daemon ~sw:inner_sw (fun () ->
          let rec loop () =
            Eio.Time.sleep clock 30.0;
            (match Agent_swarm_client.heartbeat ~sw:inner_sw masc with
             | Ok _ -> ()
             | Error e ->
               Printf.eprintf "[swarm-coordinator] heartbeat error: %s\n%!" e);
            loop ()
          in
          (try loop ()
           with
           | Eio.Cancel.Cancelled _ -> `Stop_daemon
           | End_of_file -> `Stop_daemon)
        );
      (* Agent fibers: run all agents in parallel, then inner_sw exits and
         cancels the heartbeat fiber. *)
      Eio.Fiber.List.map (fun spec ->
        run_agent ~sw:inner_sw ~net ~masc_url:config.masc_url spec ~goal
      ) config.agents
    )
  in
  if coordinator_joined then begin
    (match Agent_swarm_client.broadcast ~sw masc ~message:"Fleet complete" with
     | Ok _ -> ()
     | Error e ->
       Printf.eprintf "[swarm-coordinator] broadcast error: %s\n%!" e);
    (match Agent_swarm_client.leave ~sw masc with
     | Ok _ -> ()
     | Error e ->
       Printf.eprintf "[swarm-coordinator] MASC leave warning: %s\n%!" e)
  end;
  results
