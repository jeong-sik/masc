(** Fleet Runner configuration, arg parsing, and execution modes.

    Provides Solo mode (single agent with dev tools) and Fleet mode
    (MASC-coordinated multi-agent). All arg parsing is pure — no I/O. *)

open Agent_sdk

type runner_config = {
  goal : string;
  provider_name : string;
  workdir : string;
  max_turns : int;
  fleet_mode : bool;
  masc_url : string;
  verbose : bool;
}

let default_config = {
  goal = "";
  provider_name = "local-qwen";
  workdir = ".";
  max_turns = 10;
  fleet_mode = false;
  masc_url = "http://127.0.0.1:8935";
  verbose = false;
}

let resolve_provider name =
  match name with
  | "local-qwen" -> Some (Provider.local_qwen ())
  | "local-mlx" -> Some (Provider.local_mlx ())
  | "sonnet" -> Some (Provider.anthropic_sonnet ())
  | "haiku" -> Some (Provider.anthropic_haiku ())
  | "opus" -> Some (Provider.anthropic_opus ())
  | _ -> None

let parse_args argv =
  let len = Array.length argv in
  let rec loop i acc =
    if i >= len then
      if acc.goal = "" then Error "Missing required --goal argument"
      else Ok acc
    else
      match argv.(i) with
      | "--goal" when i + 1 < len ->
        loop (i + 2) { acc with goal = argv.(i + 1) }
      | "--provider" when i + 1 < len ->
        loop (i + 2) { acc with provider_name = argv.(i + 1) }
      | "--workdir" when i + 1 < len ->
        loop (i + 2) { acc with workdir = argv.(i + 1) }
      | "--max-turns" when i + 1 < len ->
        (match int_of_string_opt argv.(i + 1) with
         | Some n when n > 0 -> loop (i + 2) { acc with max_turns = n }
         | _ -> Error (Printf.sprintf "Invalid --max-turns: %s" argv.(i + 1)))
      | "--fleet" ->
        loop (i + 1) { acc with fleet_mode = true }
      | "--masc-url" when i + 1 < len ->
        loop (i + 2) { acc with masc_url = argv.(i + 1) }
      | "--verbose" | "-v" ->
        loop (i + 1) { acc with verbose = true }
      | arg ->
        Error (Printf.sprintf "Unknown argument: %s" arg)
  in
  loop 1 default_config

let run_solo ~sw ~net ~clock ~proc_mgr config =
  let provider_cfg = match resolve_provider config.provider_name with
    | Some p -> p | None -> Provider.local_qwen () in
  let base_url = match provider_cfg.provider with
    | Provider.Local { base_url } -> base_url
    | Provider.Anthropic -> Api.default_base_url
    | Provider.OpenAICompat { base_url; _ } -> base_url in
  let dev_tools =
    Agent_swarm_dev_tools.make_tools ~proc_mgr ~clock ~workdir:config.workdir ()
  in
  let agent_config = { Types.default_config with
    model = Types.Custom provider_cfg.model_id;
    max_turns = config.max_turns;
    system_prompt = Some (Agent_swarm_prompts.solo_developer ~goal:config.goal);
  } in
  let hooks = if config.verbose then
    { Hooks.empty with
      pre_tool_use = Some (fun event -> match event with
        | Hooks.PreToolUse { tool_name; input } ->
          Format.eprintf "[tool] %s %s@." tool_name
            (Yojson.Safe.to_string input);
          Hooks.Continue
        | _ -> Hooks.Continue) }
  else Hooks.empty in
  let agent = Agent.create ~net ~config:agent_config ~tools:dev_tools
    ~base_url ~provider:provider_cfg ~hooks () in
  Agent.run ~sw agent config.goal

let run_fleet ~sw ~net ~clock ~proc_mgr config =
  let provider_cfg = match resolve_provider config.provider_name with
    | Some p -> p | None -> Provider.local_qwen () in
  let leader_spec : Agent_swarm_fleet.fleet_member =
    Agent_swarm_fleet.Sdk_agent {
      Agent_swarm_swarm.name = "fleet-leader";
      provider = provider_cfg;
      system_prompt =
        Agent_swarm_prompts.worker ~specialization:"autonomous development";
      tools = [];
      max_tokens = None;
      max_turns = config.max_turns;
      include_masc_tools = true;
      managed_task = None;
      expected_final_marker = None;
    } in
  let fleet_config : Agent_swarm_fleet.fleet_config = {
    masc_url = config.masc_url;
    leader_name = "fleet-runner";
    members = [(leader_spec, [Agent_swarm_fleet.Code; Agent_swarm_fleet.General])];
  } in
  Agent_swarm_fleet.run ~sw ~net ~clock ~proc_mgr fleet_config ~goal:config.goal
