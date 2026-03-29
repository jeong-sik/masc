(** MASC Spawn - Agent subprocess management *)

(** Spawn configuration for an agent *)
type spawn_config = {
  agent_name: string;
  command: string;       (* e.g., "claude -p", "gemini", "codex" *)
  timeout_seconds: int;
  working_dir: string option;
  mcp_tools: string list;  (* MCP tools to allow, e.g., ["mcp__masc__masc_status"] *)
}

(** Spawn result with token tracking *)
type spawn_result = {
  success: bool;
  output: string;
  exit_code: int;
  elapsed_ms: int;
  (* Token tracking (Phase 10) *)
  input_tokens: int option;
  output_tokens: int option;
  cache_creation_tokens: int option;
  cache_read_tokens: int option;
  cost_usd: float option;
}

(** MASC MCP tools available for spawned agents *)
let masc_mcp_tools = Agent_tool_surfaces.spawned_agent_prefixed_tools

(** MASC Lifecycle Protocol - auto-appended to spawned agent prompts *)
let masc_lifecycle_suffix = {|

---
[MASC LIFECYCLE PROTOCOL - Auto-injected]

You are running as a MASC-managed agent. Follow these lifecycle rules:

1. **Session Start**: Call `mcp__masc__masc_join` with your agent name
2. **Heartbeat**: Call `mcp__masc__masc_heartbeat` every 2 minutes during long tasks
3. **Context Monitoring**: Periodically call `mcp__masc__masc_memento_mori` with estimated context_ratio:
   - 0.0-0.5: Continue normally
   - 0.5-0.8: Prepare DNA (context summary) - will auto-prepare
   - 0.8+: Auto-handoff to successor agent
4. **Task Completion**: Call `mcp__masc__masc_transition` with action="done" then `mcp__masc__masc_leave`

Example lifecycle:
```
mcp__masc__masc_join(agent_name="gemini", capabilities=["typescript","react"])
... work ...
mcp__masc__masc_heartbeat(agent_name="gemini")  // every 2 min
... more work ...
mcp__masc__masc_memento_mori(context_ratio=0.6, full_context="summary of work so far")
... continue or handoff ...
mcp__masc__masc_transition(agent_name="gemini", task_id="task-XXX", action="done")
mcp__masc__masc_leave(agent_name="gemini")
```

IMPORTANT: If context_ratio exceeds 0.8, handoff to a successor agent. Do not ignore this.
---
|}

(** Parse Claude JSON output to extract token usage *)
let parse_claude_json output =
  try
    let json = Yojson.Safe.from_string output in
    let usage = Safe_ops.json_member_opt "usage" json |> Option.value ~default:(`Assoc []) in
    let input_tokens = Safe_ops.json_int_opt "input_tokens" usage in
    let output_tokens = Safe_ops.json_int_opt "output_tokens" usage in
    let cache_creation = Safe_ops.json_int_opt "cache_creation_input_tokens" usage in
    let cache_read = Safe_ops.json_int_opt "cache_read_input_tokens" usage in
    let cost_usd = Safe_ops.json_float_opt "total_cost_usd" json in
    let result_text = Safe_ops.json_string_opt "result" json in
    (result_text, input_tokens, output_tokens, cache_creation, cache_read, cost_usd)
  with Yojson.Json_error _ ->
    (* If JSON parsing fails, return raw output with no token info *)
    (Some output, None, None, None, None, None)

(** Extract Gemini CLI response text from JSON output. *)
let extract_gemini_response_text output =
  try
    let json = Yojson.Safe.from_string output in
    Safe_ops.json_string_opt "response" json
  with Yojson.Json_error _ ->
    None

(** Parse Gemini output for token tracking.
    Supports both Gemini API usageMetadata and Gemini CLI JSON stats. *)
let parse_gemini_output output =
  try
    let json = Yojson.Safe.from_string output in
    let usage_opt = Safe_ops.json_member_opt "usageMetadata" json in
    let stats_models_opt =
      match Safe_ops.json_member_opt "stats" json with
      | Some (`Assoc _ as stats) ->
          (match Safe_ops.json_member_opt "models" stats with
           | Some (`Assoc entries) -> Some entries
           | _ -> None)
      | _ -> None
    in
    let input_tokens =
      match Option.bind usage_opt (fun usage -> Safe_ops.json_int_opt "promptTokenCount" usage) with
      | Some _ as value -> value
      | None ->
          (match stats_models_opt with
           | None -> None
           | Some entries ->
               let sum_field field =
                 entries
                 |> List.fold_left (fun acc (_name, item) ->
                        let tokens = Safe_ops.json_member_opt "tokens" item |> Option.value ~default:(`Assoc []) in
                        acc + (Safe_ops.json_int_opt field tokens |> Option.value ~default:0))
                      0
               in
               let input = sum_field "input" in
               let prompt = sum_field "prompt" in
               let chosen = if input > 0 then input else prompt in
               if chosen > 0 then Some chosen else None)
    in
    let output_tokens =
      match Option.bind usage_opt (fun usage -> Safe_ops.json_int_opt "candidatesTokenCount" usage) with
      | Some _ as value -> value
      | None ->
          (match stats_models_opt with
           | None -> None
           | Some entries ->
               let total =
                 entries
                 |> List.fold_left (fun acc (_name, item) ->
                        let tokens = Safe_ops.json_member_opt "tokens" item |> Option.value ~default:(`Assoc []) in
                        acc + (Safe_ops.json_int_opt "candidates" tokens |> Option.value ~default:0))
                      0
               in
               if total > 0 then Some total else None)
    in
    let cached_tokens =
      match Option.bind usage_opt (fun usage -> Safe_ops.json_int_opt "cachedContentTokenCount" usage) with
      | Some _ as value -> value
      | None ->
          (match stats_models_opt with
           | None -> None
           | Some entries ->
               let total =
                 entries
                 |> List.fold_left (fun acc (_name, item) ->
                        let tokens = Safe_ops.json_member_opt "tokens" item |> Option.value ~default:(`Assoc []) in
                        acc + (Safe_ops.json_int_opt "cached" tokens |> Option.value ~default:0))
                      0
               in
               if total > 0 then Some total else None)
    in
    let cost =
      match input_tokens, output_tokens, cached_tokens with
      | Some inp, Some out, Some cached ->
          let uncached = inp - cached in
          Some
            (float_of_int uncached *. 0.00015 /. 1000.0
           +. float_of_int cached *. 0.000015 /. 1000.0
           +. float_of_int out *. 0.0006 /. 1000.0)
      | Some inp, Some out, None ->
          Some
            (float_of_int inp *. 0.00015 /. 1000.0
           +. float_of_int out *. 0.0006 /. 1000.0)
      | _ -> None
    in
    (input_tokens, output_tokens, cached_tokens, cost)
  with Yojson.Json_error _ ->
    (None, None, None, None)

(** Default spawn configs for known agents *)
let default_configs = [
  ("claude", {
    agent_name = "claude";
    command = "claude --output-format json -p";  (* -p must be last before prompt *)
    timeout_seconds = Env_config.Spawn.timeout_seconds;
    working_dir = None;
    mcp_tools = masc_mcp_tools;  (* Claude: --allowedTools flag *)
  });
  ("gemini", {
    agent_name = "gemini";
    command = "gemini --yolo --output-format json";
    timeout_seconds = Env_config.Spawn.timeout_seconds;
    working_dir = None;
    mcp_tools = masc_mcp_tools;  (* Gemini: --allowed-mcp-server-names flag *)
  });
  ("codex", {
    agent_name = "codex";
    command = "codex exec";  (* Non-interactive mode *)
    timeout_seconds = Env_config.Spawn.timeout_seconds;
    working_dir = None;
    mcp_tools = masc_mcp_tools;  (* Codex: uses config.toml MCP servers *)
  });
  ("llama", {
    agent_name = "llama";
    command = "llama:explicit-model-required";
    timeout_seconds = Env_config.Spawn.timeout_seconds;
    working_dir = None;
    mcp_tools = masc_mcp_tools;
  });
]

(** Map CLI tool names and provider aliases to default_configs keys. *)
let spawn_alias_map = [
  ("claude-code", "claude");
  ("claude-api", "claude");
  ("anthropic", "claude");
  ("gemini-cli", "gemini");
  ("gemini-api", "gemini");
  ("google", "gemini");
  ("codex-cli", "codex");
  ("codex-api", "codex");
  ("openai", "codex");
  ("llama.cpp", "llama");
  ("llamacpp", "llama");
]

(** Get spawn config for agent.
    Resolves CLI tool names (e.g. "claude-code") and provider canonical names
    (e.g. "claude-api") to the short keys used in default_configs. *)
let get_config agent_name =
  let normalized = String.lowercase_ascii (String.trim agent_name) in
  match List.assoc_opt normalized default_configs with
  | Some _ as result -> result
  | None ->
    match List.assoc_opt normalized spawn_alias_map with
    | Some key -> List.assoc_opt key default_configs
    | None -> None

(** Build MCP flags as argument list (no shell escaping needed) *)
let build_mcp_args agent_name tools =
  if tools = [] then []
  else
    match Provider_adapter.resolve_direct_canonical_name agent_name |> Option.value ~default:agent_name with
  | "claude" ->
    (* Claude: --allowedTools "tool1,tool2,..." *)
    let tools_str = String.concat "," tools in
    ["--allowedTools"; tools_str]
  | "gemini" ->
    (* Gemini: --allowed-mcp-server-names masc --allowed-tools tool1 tool2 *)
    ["--allowed-mcp-server-names"; "masc"; "--allowed-tools"] @ tools
  | "codex" ->
    (* Codex: Uses config.toml MCP servers automatically, no extra flags needed *)
    []
  | "llama" ->
    []
  | _ -> []

let build_prompt_args agent_name prompt =
  match Provider_adapter.resolve_direct_canonical_name agent_name |> Option.value ~default:agent_name with
  | "gemini" -> ["-p"; prompt]
  | _ -> []

(** Parse command string into executable and arguments *)
let parse_command cmd =
  let parts = String.split_on_char ' ' cmd in
  List.filter (fun s -> String.length s > 0) parts

(** Mutex to serialize Sys.chdir + Unix.create_process.
    Sys.chdir mutates process-global CWD; concurrent spawns without
    serialization cause child processes to inherit the wrong directory. *)
let chdir_mutex = Eio.Mutex.create ()

(** Fork a subprocess with optional CWD change, holding [chdir_mutex]
    only for the chdir-fork-restore window.  Returns (pid, stdout_read_fd). *)
let fork_with_cwd ~cmd_array ~stdin_content ~working_dir ~config_working_dir =
  Eio_guard.with_mutex chdir_mutex (fun () ->
    let original_dir = Sys.getcwd () in
    let target_dir = match working_dir with
      | Some dir -> Some dir
      | None -> config_working_dir
    in
    Option.iter Sys.chdir target_dir;
    Fun.protect
      ~finally:(fun () ->
        if Option.is_some target_dir then Sys.chdir original_dir)
      (fun () ->
        let stdout_read, stdout_write = Unix.pipe () in
        let stdin_read, stdin_write = Unix.pipe () in
        let pid =
          Unix.create_process (Array.get cmd_array 0) cmd_array stdin_read
            stdout_write Unix.stderr
        in
        Unix.close stdout_write;
        Unix.close stdin_read;
        let rec write_all off len =
          if len > 0 then begin
            let written = Unix.write_substring stdin_write stdin_content off len in
            write_all (off + written) (len - written)
          end
        in
        write_all 0 (String.length stdin_content);
        Unix.close stdin_write;
        (pid, stdout_read)))

let add_default_model_arg agent_name argv =
  match Provider_adapter.resolve_direct_adapter agent_name with
  | Some adapter when adapter.canonical_name = "llama" -> (
      match Provider_adapter.explicit_llama_model_id_result () with
      | Ok model_id -> argv @ [ model_id ]
      | Error _ -> argv)
  | _ -> argv

(** Spawn an agent with a prompt/task (direct execution, no shell) *)
let spawn ~agent_name ~prompt ?timeout_seconds ?working_dir () =
  let start_time = Time_compat.now () in
  let normalized_agent = String.lowercase_ascii (String.trim agent_name) in
  if Provider_adapter.is_bare_ollama_label normalized_agent then
    {
      success = false;
      output = Provider_adapter.bare_ollama_migration_message ();
      exit_code = 2;
      elapsed_ms = int_of_float ((Time_compat.now () -. start_time) *. 1000.0);
      input_tokens = None;
      output_tokens = None;
      cache_creation_tokens = None;
      cache_read_tokens = None;
      cost_usd = None;
    }
  else

  (* Get config or use defaults *)
  let config = match get_config agent_name with
    | Some c -> c
    | None -> {
        agent_name;
        command = agent_name;  (* fallback: use agent_name as command *)
        timeout_seconds = Option.value timeout_seconds ~default:Env_config.Spawn.timeout_seconds;
        working_dir;
        mcp_tools = [];
      }
  in

  let timeout = Option.value timeout_seconds ~default:config.timeout_seconds in
  let mcp_args = build_mcp_args agent_name config.mcp_tools in
  (* Auto-append MASC lifecycle protocol to prompt *)
  let augmented_prompt = prompt ^ masc_lifecycle_suffix in
  let prompt_args = build_prompt_args agent_name augmented_prompt in

  (* Build command args - direct execution without shell *)
  let base_args = parse_command config.command |> add_default_model_arg agent_name in
  if base_args = [] then
    {
      success = false;
      output =
        Printf.sprintf "spawn command is empty for agent '%s'" agent_name;
      exit_code = 2;
      elapsed_ms = int_of_float ((Time_compat.now () -. start_time) *. 1000.0);
      input_tokens = None;
      output_tokens = None;
      cache_creation_tokens = None;
      cache_read_tokens = None;
      cost_usd = None;
    }
  else (
    let cmd_args =
      [ "timeout"; string_of_int timeout ] @ base_args @ mcp_args @ prompt_args
    in
    let cmd_array = Array.of_list cmd_args in

    (* Gemini CLI expects prompt via -p; other CLIs still read stdin. *)
    let stdin_content = if agent_name = "gemini" then "" else augmented_prompt in

    try
      (* Fork with chdir mutex to prevent CWD race between concurrent spawns *)
      let (pid, stdout_read) =
        fork_with_cwd ~cmd_array ~stdin_content
          ~working_dir ~config_working_dir:config.working_dir
      in

      (* Read output (outside mutex — only this fiber reads this pipe) *)
      let ic = Unix.in_channel_of_descr stdout_read in
      let raw_output = In_channel.input_all ic in
      In_channel.close ic;

      (* Wait for process *)
      let (_, status) = Unix.waitpid [] pid in

      (* CWD already restored inside fork_with_cwd *)

      let elapsed_ms =
        int_of_float ((Time_compat.now () -. start_time) *. 1000.0)
      in
      let exit_code =
        match status with
        | Unix.WEXITED code -> code
        | Unix.WSIGNALED _ -> -1
        | Unix.WSTOPPED _ -> -2
      in

      (* Extract token usage for Claude (JSON output) *)
      let (output, input_tokens, output_tokens, cache_creation, cache_read, cost_usd)
          =
        if agent_name = "claude" then
          let (result_opt, inp, out, cache_c, cache_r, cost) =
            parse_claude_json raw_output
          in
          ( Option.value result_opt ~default:raw_output,
            inp,
            out,
            cache_c,
            cache_r,
            cost )
        else if agent_name = "gemini" then
          let inp, out, cached, cost = parse_gemini_output raw_output in
          let result_text =
            Option.value (extract_gemini_response_text raw_output)
              ~default:raw_output
          in
          (result_text, inp, out, None, cached, cost)
        else
          (raw_output, None, None, None, None, None)
    in

    {
      success = (exit_code = 0);
      output;
      exit_code;
      elapsed_ms;
      input_tokens;
      output_tokens;
      cache_creation_tokens = cache_creation;
      cache_read_tokens = cache_read;
      cost_usd;
    }
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e ->
    (* CWD already restored inside fork_with_cwd *)
    {
      success = false;
      output = Printf.sprintf "Spawn error: %s" (Printexc.to_string e);
      exit_code = -99;
      elapsed_ms = int_of_float ((Time_compat.now () -. start_time) *. 1000.0);
      input_tokens = None;
      output_tokens = None;
      cache_creation_tokens = None;
      cache_read_tokens = None;
      cost_usd = None;
    })

(** Spawn and wait for result (synchronous) *)
let spawn_sync = spawn

(** Helper for optional int to JSON *)
let int_opt_to_json = function
  | Some n -> `Int n
  | None -> `Null

(** Helper for optional float to JSON *)
let float_opt_to_json = function
  | Some f -> `Float f
  | None -> `Null

(** Result to JSON *)
let result_to_json result =
  `Assoc [
    ("success", `Bool result.success);
    ("output", `String result.output);
    ("exit_code", `Int result.exit_code);
    ("elapsed_ms", `Int result.elapsed_ms);
    ("input_tokens", int_opt_to_json result.input_tokens);
    ("output_tokens", int_opt_to_json result.output_tokens);
    ("cache_creation_tokens", int_opt_to_json result.cache_creation_tokens);
    ("cache_read_tokens", int_opt_to_json result.cache_read_tokens);
    ("cost_usd", float_opt_to_json result.cost_usd);
  ]

(** Format token info for display *)
let format_token_info result =
  match result.input_tokens, result.output_tokens, result.cost_usd with
  | Some inp, Some out, Some cost ->
    let cache_info = match result.cache_creation_tokens, result.cache_read_tokens with
      | Some cc, Some cr when cc > 0 || cr > 0 ->
        Printf.sprintf " (cache: +%d created, %d read)" cc cr
      | _ -> ""
    in
    Printf.sprintf "\n📊 Tokens: %d in / %d out%s | Cost: $%.4f" inp out cache_info cost
  | _ -> ""

(** Result to human-readable string *)
let result_to_string result =
  let token_info = format_token_info result in
  if result.success then
    Printf.sprintf "✅ Agent completed in %dms%s\n\n%s"
      result.elapsed_ms token_info result.output
  else
    Printf.sprintf "❌ Agent failed (exit %d) in %dms%s\n\n%s"
      result.exit_code result.elapsed_ms token_info result.output
