(** Fleet Runner configuration, arg parsing, and execution modes.

    Provides Solo mode (single agent with dev tools) and Fleet mode
    (MASC-coordinated multi-agent). All arg parsing is pure — no I/O. *)

module Masc_log = Log
open Agent_sdk
module Log = Masc_log

type runner_config = {
  goal : string;
  provider_name : string;
  workdir : string;
  max_turns : int;
  fleet_mode : bool;
  num_members : int;
  masc_url : string;
  verbose : bool;
}

let default_config = {
  goal = "";
  provider_name = "local-qwen";
  workdir = ".";
  max_turns = 10;
  fleet_mode = false;
  num_members = 3;
  masc_url =
    (match Sys.getenv_opt "MASC_HTTP_BASE_URL" with
     | Some value when String.trim value <> "" -> String.trim value
     | _ -> "");
  verbose = false;
}

let local_qwen_config () : Provider.config =
  { provider = Local { base_url = Env_config_runtime.Llama.server_url };
    model_id = Env_config_runtime.Llama.default_model;
    api_key_env = "DUMMY_KEY" }

let local_mlx_config () : Provider.config =
  { provider = Local { base_url = "http://127.0.0.1:3033" };
    model_id = "qwen3.5";
    api_key_env = "DUMMY_KEY" }
let resolve_provider name =
  match name with
  | "local-qwen" -> Some (local_qwen_config ())
  | "local-mlx" -> Some (local_mlx_config ())
  | "sonnet" -> Some (Provider.anthropic_sonnet ())
  | "haiku" -> Some (Provider.anthropic_haiku ())
  | "opus" -> Some (Provider.anthropic_opus ())
  | "llama" -> Some (local_qwen_config ())
  | "openrouter" -> Some (Provider.openrouter ())
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
      | "--members" when i + 1 < len ->
        (match int_of_string_opt argv.(i + 1) with
         | Some n when n > 0 -> loop (i + 2) { acc with num_members = n }
         | _ -> Error (Printf.sprintf "Invalid --members: %s" argv.(i + 1)))
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
    | Some p -> p | None -> local_qwen_config () in
  let base_url = match provider_cfg.provider with
    | Provider.Local { base_url } -> base_url
    | Provider.Anthropic -> Api.default_base_url
    | Provider.OpenAICompat { base_url; _ } -> base_url
    | Provider.Custom_registered { name } ->
      (match Provider.find_provider name with
       | Some impl ->
         (match impl.resolve provider_cfg with
          | Ok (url, _, _) -> url
          | Error _ -> "http://127.0.0.1:8080")
       | None -> "http://127.0.0.1:8080") in
  let dev_tools =
    Agent_swarm_dev_tools.make_tools ~proc_mgr ~clock ~workdir:config.workdir ()
  in
  let hooks = if config.verbose then
    { Hooks.empty with
      pre_tool_use = Some (fun event -> match event with
        | Hooks.PreToolUse { tool_name; input; _ } ->
          Log.Swarm.debug "tool: %s %s" tool_name
            (Yojson.Safe.to_string input);
          Hooks.Continue
        | _ -> Hooks.Continue) }
  else Hooks.empty in
  let tool_names =
    List.map (fun (tool : Tool.t) -> tool.schema.name) dev_tools
  in
  let builder =
    Builder.create ~net ~model:provider_cfg.model_id
    |> Builder.with_max_turns config.max_turns
    |> Builder.with_system_prompt
         (Agent_swarm_prompts.solo_developer ~goal:config.goal)
    |> Builder.with_base_url base_url
    |> Builder.with_provider provider_cfg
    |> Builder.with_tools dev_tools
    |> Builder.with_hooks hooks
    |> Builder.with_guardrails
         {
           Guardrails.tool_filter = AllowList tool_names;
           max_tool_calls_per_turn = Some 12;
         }
  in
  match Builder.build_safe builder with
  | Error err -> Error err
  | Ok agent -> Agent.run ~sw agent config.goal

let run_fleet ~sw ~net ~clock ~proc_mgr config =
  let provider_cfg = match resolve_provider config.provider_name with
    | Some p -> p | None -> local_qwen_config () in
  let workdir = if config.workdir = "." then None else Some config.workdir in
  Agent_swarm_fleet.run_full ~sw ~net ~clock ~proc_mgr
    ~masc_url:config.masc_url
    ~provider:provider_cfg
    ~goal:config.goal
    ~num_members:config.num_members
    ?workdir
    ~max_turns:config.max_turns
    ()
