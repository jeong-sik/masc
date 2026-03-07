(** Fleet orchestrator: coordinates SDK agents and external CLI agents
    through MASC for heterogeneous agent fleet execution. *)

open Agent_sdk

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

let run_member ~sw ~net ~clock ~proc_mgr ~masc_url member ~goal =
  match member with
  | Sdk_agent spec ->
    let dev_tools = Agent_swarm_dev_tools.make_tools ~proc_mgr ~clock () in
    let resp =
      Agent_swarm_swarm.run_agent ~sw ~net ~masc_url ~extra_tools:dev_tools spec ~goal
    in
    (match resp.result with
     | Ok r -> Ok (extract_text r)
     | Error e -> Error e)
  | Ext_agent config ->
    Agent_swarm_external_agent.run_with_masc ~sw ~proc_mgr ~clock ~net ~masc_url
      config ~goal

let run ~sw ~net ~clock ~proc_mgr config ~goal =
  let leader = Agent_swarm_client.create ~base_url:config.masc_url
    ~agent_name:config.leader_name ~net in
  let _joined = Agent_swarm_client.join ~sw leader in
  Fun.protect ~finally:(fun () ->
    try ignore (Agent_swarm_client.leave ~sw leader) with _ -> ()
  ) (fun () ->
    let names = List.map (fun (m, _) -> member_name m) config.members in
    let _ = Agent_swarm_client.broadcast ~sw leader
      ~message:(Printf.sprintf "Fleet starting: %s (members: %s)"
        goal (String.concat ", " names)) in
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
    let _ = Agent_swarm_client.broadcast ~sw leader
      ~message:(Printf.sprintf "Fleet done:\n%s" summary) in
    results_list
  )
