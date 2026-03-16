(** Fleet orchestrator: coordinates SDK agents and external CLI agents
    through MASC for heterogeneous agent fleet execution. *)

module Masc_log = Log
open Agent_sdk
module Log = Masc_log

type fleet_member =
  | Sdk_agent of Agent_swarm_swarm.agent_spec
  | Ext_agent of Agent_swarm_external_agent.cli_config

type capability = Code | Research | Review | General

type fleet_config = {
  masc_url : string;
  leader_name : string;
  members : (fleet_member * capability list) list;
}

type fleet_result = {
  member_name : string;
  capability : capability;
  result : (string, string) result;
}

type run_full_plan = {
  planner_spec : Agent_swarm_swarm.agent_spec;
  worker_specs : Agent_swarm_swarm.agent_spec list;
}

let member_name = function
  | Sdk_agent spec -> spec.Agent_swarm_swarm.name
  | Ext_agent config -> config.Agent_swarm_external_agent.name

let select_members config cap =
  config.members
  |> List.filter (fun (_, caps) -> List.mem cap caps)
  |> List.map fst

let extract_text (resp : Types.api_response) =
  resp.content
  |> List.filter_map (function Types.Text s -> Some s | _ -> None)
  |> String.concat "\n"

let planner_spec ~provider ~goal =
  {
    Agent_swarm_swarm.name = "fleet-planner";
    provider;
    system_prompt = Agent_swarm_prompts.fleet_planner ~goal;
    tools = [];
    max_tokens = Some 16384;
    max_turns = 10;
    temperature = Some 1.0;
    include_masc_tools = true;
    managed_task = None;
    expected_final_marker = None;
  }

let worker_specs ~provider ~num_members ~workdir ~max_turns =
  List.init num_members (fun i ->
      let name = Printf.sprintf "fleet-worker-%d" (i + 1) in
      {
        Agent_swarm_swarm.name = name;
        provider;
        system_prompt = Agent_swarm_prompts.fleet_worker ~name ~workdir;
        tools = [];
        max_tokens = Some 8192;
        max_turns;
        temperature = Some 0.6;
        include_masc_tools = true;
        managed_task = None;
        expected_final_marker = None;
      })

let build_run_full_plan ~provider ~goal ~num_members ~workdir ~max_turns =
  if num_members <= 0 then invalid_arg "num_members must be positive";
  { planner_spec = planner_spec ~provider ~goal;
    worker_specs = worker_specs ~provider ~num_members ~workdir ~max_turns }

let run_member ~sw ~net ~clock ~proc_mgr ~masc_url member ~goal =
  match member with
  | Sdk_agent spec ->
    let dev_tools = Agent_swarm_dev_tools.make_tools ~proc_mgr ~clock () in
    let resp =
      Agent_swarm_swarm.run_agent ~sw ~net ~clock ~masc_url ~extra_tools:dev_tools spec ~goal
    in
    (match resp.result with
     | Ok r -> Ok (extract_text r.response)
     | Error e -> Error e)
  | Ext_agent config ->
    Agent_swarm_external_agent.run_with_masc ~sw ~proc_mgr ~clock ~net ~masc_url
      config ~goal

let run ~sw ~net ~clock ~proc_mgr config ~goal =
  let leader = Agent_swarm_client.create_managed ~base_url:config.masc_url
    ~agent_name:config.leader_name ~net in
  let _joined = Agent_swarm_client.join ~sw leader in
  Fun.protect ~finally:(fun () ->
    (try match Agent_swarm_client.leave ~sw leader with
      | Ok _ -> ()
      | Error msg -> Log.Misc.error "[swarm] leader leave failed: %s" msg
    with
     | Eio.Cancel.Cancelled _ as ex -> raise ex
     | exn -> Log.Misc.error "[swarm] leader leave error: %s" (Printexc.to_string exn))
  ) (fun () ->
    let names = List.map (fun (m, _) -> member_name m) config.members in
    (match Agent_swarm_client.broadcast ~sw leader
      ~message:(Printf.sprintf "Fleet starting: %s (members: %s)"
        goal (String.concat ", " names)) with
     | Ok _ -> () | Error msg -> Log.Misc.error "[swarm] broadcast failed: %s" msg);
    let n = List.length config.members in
    let results = Array.make n
      { member_name = ""; capability = General; result = Error "pending" } in
    Eio.Fiber.all (List.mapi (fun i (member, caps) ->
      fun () ->
        let cap = match caps with c :: _ -> c | [] -> General in
        let name = member_name member in
        let r = run_member ~sw ~net ~clock ~proc_mgr
          ~masc_url:config.masc_url member ~goal in
        results.(i) <- { member_name = name; capability = cap; result = r }
    ) config.members);
    let results_list = Array.to_list results in
    let summary = results_list |> List.map (fun r ->
      Printf.sprintf "- %s: %s" r.member_name
        (match r.result with Ok _ -> "OK" | Error e -> "Error: " ^ e)
    ) |> String.concat "\n" in
    (match Agent_swarm_client.broadcast ~sw leader
      ~message:(Printf.sprintf "Fleet done:\n%s" summary) with
     | Ok _ -> () | Error msg -> Log.Misc.error "[swarm] broadcast failed: %s" msg);
    results_list
  )

let run_full ~sw ~net ~clock ~proc_mgr ~masc_url ~provider
    ~goal ~num_members ?workdir ~max_turns () =
  if num_members <= 0 then invalid_arg "num_members must be positive";
  let coordinator =
    Agent_swarm_client.create_managed ~net ~base_url:masc_url
      ~agent_name:"fleet-coordinator"
  in
  let _joined = Agent_swarm_client.join ~sw coordinator in
  Fun.protect
    ~finally:(fun () ->
      (try match Agent_swarm_client.leave ~sw coordinator with
        | Ok _ -> ()
        | Error msg -> Log.Misc.error "[swarm] coordinator leave failed: %s" msg
      with exn -> Log.Misc.error "[swarm] coordinator leave error: %s" (Printexc.to_string exn)))
    (fun () ->
      (match Agent_swarm_client.broadcast ~sw coordinator
          ~message:
            (Printf.sprintf "Fleet run_full: %s (members: %d)" goal num_members) with
       | Ok _ -> () | Error msg -> Log.Misc.error "[swarm] broadcast failed: %s" msg);
      let workdir = match workdir with Some path -> path | None -> Sys.getcwd () in
      let plan =
        build_run_full_plan ~provider ~goal ~num_members ~workdir ~max_turns
      in
      let planner_result =
        Agent_swarm_swarm.run_agent ~sw ~net ~clock ~masc_url plan.planner_spec
          ~goal:(Printf.sprintf "Decompose this goal into tasks: %s" goal)
      in
      match planner_result.result with
      | Error e ->
        let _ =
          Agent_swarm_client.broadcast ~sw coordinator
            ~message:(Printf.sprintf "Planning failed: %s" e)
        in
        [planner_result]
      | Ok _ ->
        let _ =
          Agent_swarm_client.broadcast ~sw coordinator
            ~message:"Planning complete, launching workers"
        in
        let dev_tools =
          Agent_swarm_dev_tools.make_tools ~proc_mgr ~clock ~workdir ()
        in
        let results =
          Array.make (List.length plan.worker_specs)
            { Agent_swarm_swarm.agent_name = ""; result = Error "pending" }
        in
        Eio.Fiber.all
          (List.mapi
             (fun i spec () ->
               let result =
                 try
                   Agent_swarm_swarm.run_agent ~sw ~net ~clock ~masc_url
                     ~extra_tools:dev_tools spec
                     ~goal:"Claim and complete available tasks"
                 with exn ->
                   { Agent_swarm_swarm.agent_name = spec.name;
                     result =
                       Error
                         (Printf.sprintf "worker exception: %s"
                            (Printexc.to_string exn)) }
               in
               results.(i) <- result)
             plan.worker_specs);
        let worker_results = Array.to_list results in
        let summary =
          worker_results
          |> List.map (fun (result : Agent_swarm_swarm.agent_result) ->
                 Printf.sprintf "- %s: %s" result.agent_name
                   (match result.result with
                    | Ok _ -> "OK"
                    | Error e -> "Error: " ^ e))
          |> String.concat "\n"
        in
        let _ =
          Agent_swarm_client.broadcast ~sw coordinator
            ~message:(Printf.sprintf "Fleet done:\n%s" summary)
        in
        planner_result :: worker_results)
