(** MASC Spawn - Agent subprocess management *)

(** Parsed output from a CLI tool's JSON response. *)
type parsed_output = {
  text : string;
  input_tokens : int option;
  output_tokens : int option;
  cache_creation_tokens : int option;
  cache_read_tokens : int option;
  cost_usd : float option;
}

(** How MCP tool list is passed on the CLI. *)
type mcp_flag =
  | Mcp_joined of string    (** Single flag with comma-joined tools: --flag t1,t2 *)
  | Mcp_spread of string    (** Server name + spread tools: --server masc --flag t1 t2 *)
  | Mcp_none                (** No MCP flags emitted *)

(** How the prompt is passed to the CLI. *)
type prompt_flag =
  | Prompt_flag of string   (** Prompt passed via CLI flag: -p <prompt> *)
  | Prompt_stdin             (** Prompt passed via stdin *)

(** Spawn configuration for an agent *)
type spawn_config = {
  agent_name: string;
  command: string;       (* e.g., "claude -p", "gemini", "codex" *)
  timeout_seconds: int;
  working_dir: string option;
  mcp_tools: string list;  (* MCP tools to allow, e.g., ["mcp__masc__masc_status"] *)
  parse_output: string -> parsed_output;
    (** Parse CLI tool's raw output into structured result.
        Each CLI tool has a different JSON schema. *)
  stdin_prompt: bool;
    (** Whether prompt is passed via stdin (true) or CLI flag (false).
        Deprecated: use [prompt_mode] instead. Kept for backward compat. *)
  mcp_mode: mcp_flag;
    (** How MCP tools are passed on the CLI. *)
  prompt_mode: prompt_flag;
    (** How the prompt is delivered to the agent. *)
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
3. **Context Handoff**: If context pressure rises or you are about to stop mid-task,
   write a structured handover with `mcp__masc__masc_handover_create`
4. **Task Completion**: Call `mcp__masc__masc_transition` with action="done" then `mcp__masc__masc_leave`

Example lifecycle:
```
mcp__masc__masc_join(agent_name="gemini", capabilities=["typescript","react"])
... work ...
mcp__masc__masc_heartbeat(agent_name="gemini")  // every 2 min
... more work ...
mcp__masc__masc_handover_create(...)  // when a successor needs your state
mcp__masc__masc_transition(agent_name="gemini", task_id="task-XXX", action="done")
mcp__masc__masc_leave(agent_name="gemini")
```

IMPORTANT: If you cannot finish in one pass, hand off explicitly before leaving.
---
|}

(** Default parser: no structured output, pass through raw text. *)
let parse_raw_output raw =
  { text = raw; input_tokens = None; output_tokens = None;
    cache_creation_tokens = None; cache_read_tokens = None; cost_usd = None }

(** Parse Claude CLI JSON output (--output-format json). *)
let parse_claude_output raw =
  try
    let json = Yojson.Safe.from_string raw in
    let usage = Safe_ops.json_member_opt "usage" json |> Option.value ~default:(`Assoc []) in
    { text = Option.value (Safe_ops.json_string_opt "result" json) ~default:raw;
      input_tokens = Safe_ops.json_int_opt "input_tokens" usage;
      output_tokens = Safe_ops.json_int_opt "output_tokens" usage;
      cache_creation_tokens = Safe_ops.json_int_opt "cache_creation_input_tokens" usage;
      cache_read_tokens = Safe_ops.json_int_opt "cache_read_input_tokens" usage;
      cost_usd = Safe_ops.json_float_opt "total_cost_usd" json }
  with Yojson.Json_error _ ->
    parse_raw_output raw

(** Parse Gemini CLI JSON output (--output-format json).
    Supports both Gemini API usageMetadata and Gemini CLI JSON stats. *)
let parse_gemini_output raw =
  try
    let json = Yojson.Safe.from_string raw in
    let response_text =
      Option.value (Safe_ops.json_string_opt "response" json) ~default:raw in
    let usage_opt = Safe_ops.json_member_opt "usageMetadata" json in
    let stats_models_opt =
      match Safe_ops.json_member_opt "stats" json with
      | Some (`Assoc _ as stats) ->
          (match Safe_ops.json_member_opt "models" stats with
           | Some (`Assoc entries) -> Some entries
           | _ -> None)
      | _ -> None
    in
    let sum_stat_field field entries =
      entries
      |> List.fold_left (fun acc (_name, item) ->
             let tokens = Safe_ops.json_member_opt "tokens" item
                          |> Option.value ~default:(`Assoc []) in
             acc + (Safe_ops.json_int_opt field tokens |> Option.value ~default:0))
           0
    in
    let from_usage key = Option.bind usage_opt (fun u -> Safe_ops.json_int_opt key u) in
    let from_stats_first keys =
      match stats_models_opt with
      | None -> None
      | Some entries ->
          let rec try_keys = function
            | [] -> None
            | k :: rest ->
                let total = sum_stat_field k entries in
                if total > 0 then Some total else try_keys rest
          in
          try_keys keys
    in
    let input_tokens =
      match from_usage "promptTokenCount" with
      | Some _ as v -> v | None -> from_stats_first ["input"; "prompt"] in
    let output_tokens =
      match from_usage "candidatesTokenCount" with
      | Some _ as v -> v | None -> from_stats_first ["candidates"] in
    let cached_tokens =
      match from_usage "cachedContentTokenCount" with
      | Some _ as v -> v | None -> from_stats_first ["cached"] in
    let cost_usd = Safe_ops.json_float_opt "total_cost_usd" json in
    { text = response_text; input_tokens; output_tokens;
      cache_creation_tokens = None; cache_read_tokens = cached_tokens; cost_usd }
  with Yojson.Json_error _ ->
    parse_raw_output raw

(** Default spawn configs for known agents *)
let default_configs = [
  ("claude", {
    agent_name = "claude";
    command = "claude --output-format json -p";
    timeout_seconds = Env_config.Spawn.timeout_seconds;
    working_dir = None;
    mcp_tools = masc_mcp_tools;
    parse_output = parse_claude_output;
    stdin_prompt = true;
    mcp_mode = Mcp_joined "--allowedTools";
    prompt_mode = Prompt_stdin;
  });
  ("gemini", {
    agent_name = "gemini";
    command = "gemini --yolo --output-format json";
    timeout_seconds = Env_config.Spawn.timeout_seconds;
    working_dir = None;
    mcp_tools = masc_mcp_tools;
    parse_output = parse_gemini_output;
    stdin_prompt = false;
    mcp_mode = Mcp_spread "--allowed-tools";
    prompt_mode = Prompt_flag "-p";
  });
  ("codex", {
    agent_name = "codex";
    command = "codex exec";
    timeout_seconds = Env_config.Spawn.timeout_seconds;
    working_dir = None;
    mcp_tools = masc_mcp_tools;
    parse_output = parse_raw_output;
    stdin_prompt = true;
    mcp_mode = Mcp_none;
    prompt_mode = Prompt_stdin;
  });
  ("llama", {
    agent_name = "llama";
    command = Provider_adapter.make_local_label "explicit-model-required";
    timeout_seconds = Env_config.Spawn.timeout_seconds;
    working_dir = None;
    mcp_tools = masc_mcp_tools;
    parse_output = parse_raw_output;
    stdin_prompt = true;
    mcp_mode = Mcp_none;
    prompt_mode = Prompt_stdin;
  });
]

(** Get spawn config for agent.
    Resolves all aliases via Provider_adapter registry (SSOT).
    spawn_alias_map removed — aliases are now in Provider_adapter.direct_adapters. *)
let get_config agent_name =
  let normalized = String.lowercase_ascii (String.trim agent_name) in
  match List.assoc_opt normalized default_configs with
  | Some _ as result -> result
  | None ->
    match Provider_adapter.resolve_spawn_key normalized with
    | Some key -> List.assoc_opt key default_configs
    | None -> None

(** Build MCP flags from config's [mcp_mode] field.
    No agent-name matching — dispatch is config-driven. *)
let build_mcp_args_from_config (config : spawn_config) tools =
  if tools = [] then []
  else
    match config.mcp_mode with
    | Mcp_joined flag ->
      [flag; String.concat "," tools]
    | Mcp_spread flag ->
      ["--allowed-mcp-server-names"; "masc"; flag] @ tools
    | Mcp_none -> []

(** Build prompt flags from config's [prompt_mode] field. *)
let build_prompt_args_from_config (config : spawn_config) prompt =
  match config.prompt_mode with
  | Prompt_flag flag -> [flag; prompt]
  | Prompt_stdin -> []

(** Build MCP flags as argument list (no shell escaping needed).
    Resolves agent config then dispatches via [mcp_mode]. *)
let build_mcp_args agent_name tools =
  if tools = [] then []
  else
    match get_config agent_name with
    | Some config -> build_mcp_args_from_config config tools
    | None -> []

let build_prompt_args agent_name prompt =
  match get_config agent_name with
  | Some config -> build_prompt_args_from_config config prompt
  | None -> []

(** Parse command string into executable and arguments *)
let parse_command cmd =
  let parts = String.split_on_char ' ' cmd in
  List.filter (fun s -> String.length s > 0) parts

let close_quietly fd =
  try Unix.close fd with
  | Unix.Unix_error _ -> ()

let remove_temp_file_quietly path =
  try Sys.remove path with
  | Sys_error _ -> ()

let create_stderr_tempfile () =
  let path = Filename.temp_file "masc_spawn_stderr" ".tmp" in
  let fd =
    Unix.openfile path [ Unix.O_WRONLY; Unix.O_TRUNC; Unix.O_CLOEXEC ] 0o600
  in
  (path, fd)

let read_stderr_capture path =
  try In_channel.with_open_bin path In_channel.input_all with
  | _ ->
    Printf.sprintf
      "(stderr capture error) failed to read captured stderr file %s"
      (Filename.basename path)

let output_for_status ~(status : Unix.process_status) ~(stdout : string)
    ~(stderr : string) : string =
  match status with
  | Unix.WEXITED 0 -> stdout
  | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> (
      match stdout, stderr with
      | "", err -> err
      | out, "" -> out
      | out, err -> out ^ "\n" ^ err)

let fallback_spawn_failure_output ~exit_code =
  Printf.sprintf
    "spawned agent exited with code %d without any stdout/stderr output"
    exit_code

(** Mutex to serialize Sys.chdir + Unix.create_process.
    Sys.chdir mutates process-global CWD; concurrent spawns without
    serialization cause child processes to inherit the wrong directory. *)
let chdir_mutex = Eio.Mutex.create ()

(** Fork a subprocess with optional CWD change, holding [chdir_mutex]
    only for the chdir-fork-restore window.  Returns the child pid, stdout
    pipe, and a private stderr capture path. *)
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
        let stdout_read, stdout_write = Unix.pipe ~cloexec:true () in
        let stdin_read, stdin_write = Unix.pipe ~cloexec:true () in
        let stderr_path, stderr_fd = create_stderr_tempfile () in
        try
          let pid =
            Unix.create_process (Array.get cmd_array 0) cmd_array stdin_read
              stdout_write stderr_fd
          in
          Unix.close stdout_write;
          Unix.close stdin_read;
          Unix.close stderr_fd;
          let rec write_all off len =
            if len > 0 then begin
              let written = Unix.write_substring stdin_write stdin_content off len in
              write_all (off + written) (len - written)
            end
          in
          write_all 0 (String.length stdin_content);
          Unix.close stdin_write;
          (pid, stdout_read, stderr_path)
        with exn ->
          close_quietly stdout_read;
          close_quietly stdout_write;
          close_quietly stdin_read;
          close_quietly stdin_write;
          close_quietly stderr_fd;
          remove_temp_file_quietly stderr_path;
          raise exn))

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
        command = agent_name;
        timeout_seconds = Option.value timeout_seconds ~default:Env_config.Spawn.timeout_seconds;
        working_dir;
        mcp_tools = [];
        parse_output = parse_raw_output;
        stdin_prompt = true;
        mcp_mode = Mcp_none;
        prompt_mode = Prompt_stdin;
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
    (* prompt_args before mcp_args: yargs parses -p <prompt> first,
       preventing --allowed-tools array values from leaking into
       positional query slot. Fixes gemini "Cannot use both a positional
       prompt and the --prompt (-p) flag together" error. (#5975) *)
    let cmd_args =
      [ "timeout"; string_of_int timeout ] @ base_args @ prompt_args @ mcp_args
    in
    let cmd_array = Array.of_list cmd_args in

    let stdin_content = if config.stdin_prompt then augmented_prompt else "" in

    try
      (* Fork with chdir mutex to prevent CWD race between concurrent spawns *)
      let (pid, stdout_read, stderr_path) =
        fork_with_cwd ~cmd_array ~stdin_content
          ~working_dir ~config_working_dir:config.working_dir
      in

      (* Read output + wait in systhread to avoid blocking the Eio event loop.
         Without this, a long-running subprocess (e.g. fire_task) freezes the
         entire server — health endpoint, SSE, all keeper fibers. *)
      let (raw_output, stderr_output, status) =
        Fun.protect
          ~finally:(fun () -> remove_temp_file_quietly stderr_path)
          (fun () ->
            Eio_guard.run_in_systhread (fun () ->
              let ic = Unix.in_channel_of_descr stdout_read in
              let output =
                Fun.protect
                  ~finally:(fun () -> In_channel.close ic)
                  (fun () -> In_channel.input_all ic)
              in
              let rec waitpid_retry () =
                try Unix.waitpid [] pid
                with Unix.Unix_error (Unix.EINTR, _, _) -> waitpid_retry ()
              in
              let (_, status) = waitpid_retry () in
              (output, read_stderr_capture stderr_path, status)))
      in

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

      let parsed = config.parse_output raw_output in
      let input_tokens = parsed.input_tokens in
      let output_tokens = parsed.output_tokens in
      let cache_creation = parsed.cache_creation_tokens in
      let cache_read = parsed.cache_read_tokens in
      let cost_usd = parsed.cost_usd in
      let output =
        if exit_code = 0 then
          parsed.text
        else
          let rendered =
            output_for_status ~status ~stdout:parsed.text ~stderr:stderr_output
          in
          if String.trim rendered = ""
          then fallback_spawn_failure_output ~exit_code
          else rendered
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

let int_opt_to_json = Json_util.int_opt_to_json
let float_opt_to_json = Json_util.float_opt_to_json

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
