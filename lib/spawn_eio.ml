(** MASC Spawn - Eio Native Agent subprocess management *)

(** Mutex to serialize Sys.chdir + process fork.
    Sys.chdir is process-global; under Eio's fiber concurrency,
    concurrent spawn_agent calls would race on CWD without this. *)
let chdir_mutex = Eio.Mutex.create ()

(** Spawn configuration for an agent *)
type spawn_config = {
  agent_name: string;
  command: string;
  timeout_seconds: int;
  working_dir: string option;
  mcp_tools: string list;
}

(** Spawn result with token tracking *)
type spawn_result = {
  success: bool;
  output: string;
  exit_code: int;
  elapsed_ms: int;
  input_tokens: int option;
  output_tokens: int option;
  cache_creation_tokens: int option;
  cache_read_tokens: int option;
  cost_usd: float option;
}

(** MASC MCP tools available for spawned agents *)
let masc_mcp_tools = [
  "mcp__masc__masc_status";
  "mcp__masc__masc_tasks";
  "mcp__masc__masc_claim";
  "mcp__masc__masc_claim_next";
  "mcp__masc__masc_transition";
  "mcp__masc__masc_release";
  "mcp__masc__masc_task_history";
  "mcp__masc__masc_done";
  "mcp__masc__masc_broadcast";
  "mcp__masc__masc_join";
  "mcp__masc__masc_leave";
  "mcp__masc__masc_who";
  "mcp__masc__masc_agent_update";
  "mcp__masc__masc_add_task";
  "mcp__masc__masc_heartbeat";
  "mcp__masc__masc_messages";
  "mcp__masc__masc_worktree_create";
  "mcp__masc__masc_worktree_remove";
  "mcp__masc__masc_worktree_list";
  "mcp__masc__masc_handover_create";
  "mcp__masc__masc_handover_list";
  "mcp__masc__masc_handover_claim";
  "mcp__masc__masc_handover_get";
  "mcp__masc__masc_memento_mori";
  "mcp__masc__masc_relay_status";
  "mcp__masc__masc_relay_checkpoint";
  "mcp__masc__masc_board_list";
  "mcp__masc__masc_board_post";
  "mcp__masc__masc_board_comment";
  "mcp__masc__masc_board_vote";
  "mcp__masc__masc_board_get";
  "mcp__masc__masc_portal_open";
  "mcp__masc__masc_portal_send";
  "mcp__masc__masc_portal_status";
  "mcp__masc__masc_team_session_start";
  "mcp__masc__masc_team_session_step";
  "mcp__masc__masc_team_session_status";
  "mcp__masc__masc_team_session_turn";
  "mcp__masc__masc_team_session_events";
  "mcp__masc__masc_team_session_finalize";
  "mcp__masc__masc_team_session_stop";
  "mcp__masc__masc_team_session_report";
  "mcp__masc__masc_team_session_prove";
  "mcp__masc__masc_team_session_list";
  "mcp__masc__masc_team_session_compare";
  "mcp__masc__masc_a2a_delegate";
  "mcp__masc__masc_a2a_subscribe";
  "mcp__masc__masc_poll_events";
  "mcp__masc__masc_vote_create";
  "mcp__masc__masc_vote_cast";
  "mcp__masc__masc_vote_status";
  "mcp__masc__masc_run_init";
  "mcp__masc__masc_run_log";
  "mcp__masc__masc_run_deliverable";
  "mcp__masc__masc_run_get";
  "mcp__masc__masc_spawn";
  "mcp__masc__masc_heartbeat_list";
]

let masc_lifecycle_suffix = {| 
--- 
[MASC LIFECYCLE PROTOCOL - Auto-injected] 

You are running as a MASC-managed agent. Follow these rules strictly:

1. **Session Start**: Call `mcp__masc__masc_join` with your agent name
2. **Heartbeat**: Call `mcp__masc__masc_heartbeat` every 2 minutes during long tasks
3. **Context Monitoring**: Periodically call `mcp__masc__masc_memento_mori` with estimated context_ratio:
   - 0.0-0.5: Continue normally
   - 0.5-0.8: Prepare DNA (context summary) - will auto-prepare
   - 0.8+: Auto-handoff to successor agent
4. **Task Completion**: Call `mcp__masc__masc_transition` with action="done" then `mcp__masc__masc_leave`

IMPORTANT: If context_ratio exceeds 0.8, you MUST handoff. Do not ignore this. 
--- 
|}

(** Parse Claude CLI JSON output for token tracking *)
let parse_claude_json output =
  try
    let json = Yojson.Safe.from_string output in
    let open Yojson.Safe.Util in
    let usage = json |> member "usage" in
    let input_tokens = usage |> member "input_tokens" |> to_int_option in
    let output_tokens = usage |> member "output_tokens" |> to_int_option in
    let cache_creation = usage |> member "cache_creation_input_tokens" |> to_int_option in
    let cache_read = usage |> member "cache_read_input_tokens" |> to_int_option in
    let cost_usd = json |> member "total_cost_usd" |> to_float_option in
    let result_text = json |> member "result" |> to_string_option in
    (result_text, input_tokens, output_tokens, cache_creation, cache_read, cost_usd)
  with
  | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ ->
    (Some output, None, None, None, None, None)

(** Parse Gemini output for token tracking
    Format: {"usageMetadata": {"promptTokenCount": N, "candidatesTokenCount": M, "cachedContentTokenCount": C}} *)
let parse_gemini_output output =
  try
    let json = Yojson.Safe.from_string output in
    let open Yojson.Safe.Util in
    let usage = json |> member "usageMetadata" in
    let input_tokens = usage |> member "promptTokenCount" |> to_int_option in
    let output_tokens = usage |> member "candidatesTokenCount" |> to_int_option in
    let cached_tokens = usage |> member "cachedContentTokenCount" |> to_int_option in
    (* Gemini 2.5: cached tokens are 90% cheaper *)
    let cost = match input_tokens, output_tokens, cached_tokens with
      | Some inp, Some out, Some cached ->
          let uncached = inp - cached in
          (* $0.15/1M uncached input, $0.015/1M cached, $0.60/1M output for 2.5 Flash *)
          Some (float_of_int uncached *. 0.00015 /. 1000.0 +.
                float_of_int cached *. 0.000015 /. 1000.0 +.
                float_of_int out *. 0.0006 /. 1000.0)
      | Some inp, Some out, None ->
          Some (float_of_int inp *. 0.00015 /. 1000.0 +. float_of_int out *. 0.0006 /. 1000.0)
      | _ -> None
    in
    (input_tokens, output_tokens, cached_tokens, cost)
  with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ ->
    (None, None, None, None)

(** Parse Ollama output for token tracking
    Format: {"prompt_eval_count": N, "eval_count": M} *)
let parse_ollama_output output =
  try
    let json = Yojson.Safe.from_string output in
    let open Yojson.Safe.Util in
    let input_tokens = json |> member "prompt_eval_count" |> to_int_option in
    let output_tokens = json |> member "eval_count" |> to_int_option in
    (* Local ollama has no cost *)
    (input_tokens, output_tokens, Some 0.0)
  with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ ->
    (None, None, None)

(** Parse Codex JSONL output for token tracking
    Last line format: {"type":"turn.completed","usage":{"input_tokens":N,"output_tokens":M}} *)
let parse_codex_output output =
  try
    (* Find the last line with turn.completed *)
    let lines = String.split_on_char '\n' output in
    let turn_completed = List.find_opt (fun line ->
      String.length line > 0 &&
      match Safe_ops.parse_json_safe ~context:"codex_parse" line with
      | Error _ -> false
      | Ok json ->
        Safe_ops.json_string "type" json = "turn.completed"
    ) (List.rev lines) in
    match turn_completed with
    | Some line ->
        let json = Yojson.Safe.from_string line in
        let open Yojson.Safe.Util in
        let usage = json |> member "usage" in
        let input_tokens = usage |> member "input_tokens" |> to_int_option in
        let output_tokens = usage |> member "output_tokens" |> to_int_option in
        let cached = usage |> member "cached_input_tokens" |> to_int_option in
        (* OpenAI pricing estimate: $15/1M input, $60/1M output *)
        let cost = match input_tokens, output_tokens with
          | Some inp, Some out ->
              Some (float_of_int inp *. 0.015 /. 1000.0 +. float_of_int out *. 0.06 /. 1000.0)
          | _ -> None
        in
        (input_tokens, output_tokens, cached, cost)
    | None -> (None, None, None, None)
  with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ ->
    (None, None, None, None)

(** Parse GLM (Z.ai) output for token tracking - OpenAI-compatible format
    Format: {"choices": [...], "usage": {"prompt_tokens": N, "completion_tokens": M}} *)
let parse_glm_output output =
  try
    let json = Yojson.Safe.from_string output in
    let open Yojson.Safe.Util in
    let usage = json |> member "usage" in
    let input_tokens = usage |> member "prompt_tokens" |> to_int_option in
    let output_tokens = usage |> member "completion_tokens" |> to_int_option in
    (* GLM-4.7: Z.ai Coding Plan pricing is subscription-based, estimate $0 per token *)
    let cost = Some 0.0 in
    (input_tokens, output_tokens, cost)
  with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ ->
    (None, None, None)

let split_csv_nonempty raw =
  raw
  |> String.split_on_char ','
  |> List.map String.trim
  |> List.filter (fun s -> s <> "")

let unique_preserve_order items =
  let rec loop acc = function
    | [] -> List.rev acc
    | x :: xs ->
        if List.mem x acc then loop acc xs
        else loop (x :: acc) xs
  in
  loop [] items

let normalize_glm_model_alias raw =
  let s = raw |> String.trim |> String.lowercase_ascii in
  match s with
  | "" -> None
  | "4.7" -> Some "glm-4.7"
  | "4.7-flash" -> Some "glm-4.7-flash"
  | "4.7-flashx" -> Some "glm-4.7-flashx"
  | "4.6" -> Some "glm-4.6"
  | "4.5" -> Some "glm-4.5"
  | "4.5-flash" -> Some "glm-4.5-flash"
  | "4.5-air" -> Some "glm-4.5-air"
  | "4.5-airx" -> Some "glm-4.5-airx"
  | "4.5v" -> Some "glm-4.5v"
  | "5" -> Some "glm-5"
  | "5-code" | "5-coder" | "glm-5-coder" -> Some "glm-5-code"
  | _ when String.starts_with ~prefix:"glm-" s -> Some s
  | _ -> Some s

let default_glm_spawn_cascade_models =
  [ "glm-4.7"; "glm-4.7-flash"; "glm-4.7-flashx"; "glm-5"; "glm-5-code" ]

let glm_spawn_cascade_models () =
  let configured =
    match Sys.getenv_opt "MASC_GLM_SPAWN_CASCADE" with
    | None -> []
    | Some raw -> split_csv_nonempty raw |> List.filter_map normalize_glm_model_alias
  in
  let base =
    if configured = [] then default_glm_spawn_cascade_models else configured
  in
  let preferred =
    match Sys.getenv_opt "MASC_GLM_DEFAULT_MODEL" with
    | Some raw -> normalize_glm_model_alias raw
    | None -> None
  in
  let merged =
    match preferred with
    | Some m -> m :: base
    | None -> base
  in
  unique_preserve_order merged

let extract_glm_message_text (json : Yojson.Safe.t) =
  let open Yojson.Safe.Util in
  let texts_from_content = function
    | `String s -> Some s
    | `List items ->
        let texts =
          List.filter_map
            (fun item ->
              match item |> member "type" |> to_string_option with
              | Some "text" -> item |> member "text" |> to_string_option
              | _ -> None)
            items
        in
        if texts = [] then None else Some (String.concat "\n" texts)
    | _ -> None
  in
  let from_chat =
    match member "choices" json with
    | `List ((`Assoc _ as first) :: _) ->
        first |> member "message" |> member "content" |> texts_from_content
    | _ -> None
  in
  match from_chat with
  | Some text when String.trim text <> "" -> Some text
  | _ ->
      (match json |> member "result" |> member "content" with
      | `List items ->
          let texts =
            List.filter_map
              (fun item ->
                match item |> member "type" |> to_string_option with
                | Some "text" -> item |> member "text" |> to_string_option
                | _ -> None)
              items
          in
          if texts = [] then None else Some (String.concat "\n" texts)
      | _ -> None)

let glm_error_message output =
  try
    let json = Yojson.Safe.from_string output in
    let open Yojson.Safe.Util in
    match member "error" json with
    | `Null -> None
    | `String s when String.trim s <> "" -> Some s
    | `Assoc _ as e -> Some (Yojson.Safe.to_string e)
    | e -> Some (Yojson.Safe.to_string e)
  with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ ->
    None

let glm_context_tokens model =
  match String.lowercase_ascii (String.trim model) with
  | "glm-5"
  | "glm-5-code"
  | "glm-4.7"
  | "glm-4.7-flash"
  | "glm-4.7-flashx"
  | "glm-4.6"
  | "glm-4.5-flash" -> Some 200_000
  | "glm-4.6v"
  | "glm-4.6v-flash"
  | "glm-4.6v-flashx"
  | "glm-4.5"
  | "glm-4.5-air"
  | "glm-4.5-airx"
  | "glm-4.5v"
  | "glm-4-32b-0414-128k" -> Some 128_000
  | _ -> None

let glm_min_context_tokens () =
  match Sys.getenv_opt "MASC_GLM_MIN_CONTEXT_TOKENS" with
  | None -> 200_000
  | Some raw ->
      let trimmed = String.trim raw in
      (match int_of_string_opt trimmed with
      | Some n when n > 0 -> n
      | _ -> 200_000)

let glm_spawn_cascade_models_for_policy () =
  let min_context = glm_min_context_tokens () in
  let configured = glm_spawn_cascade_models () in
  List.filter
    (fun model ->
      match glm_context_tokens model with
      | Some ctx -> ctx >= min_context
      | None -> false)
    configured

let default_configs = [
  ("claude", {
    agent_name = "claude";
    command = "claude --output-format json -p";
    timeout_seconds = Env_config.Spawn.timeout_seconds;
    working_dir = None;
    mcp_tools = masc_mcp_tools;
  });
  ("gemini", {
    agent_name = "gemini";
    command = "gemini --yolo";
    timeout_seconds = Env_config.Spawn.timeout_seconds;
    working_dir = None;
    mcp_tools = masc_mcp_tools;
  });
  ("codex", {
    agent_name = "codex";
    command = "codex exec --json";
    timeout_seconds = Env_config.Spawn.timeout_seconds;
    working_dir = None;
    mcp_tools = masc_mcp_tools;
  });
  ("ollama", {
    agent_name = "ollama";
    command = Printf.sprintf "ollama run %s" Env_config.Ollama.default_model;
    timeout_seconds = Env_config.Spawn.timeout_seconds;
    working_dir = None;
    mcp_tools = [];
  });
  (* GLM uses Z.ai API directly - no llm-mcp dependency *)
  ("glm", {
    agent_name = "glm";
    (* Direct Z.ai API call - requires ZAI_API_KEY env var *)
    command = "curl -s -X POST https://api.z.ai/api/coding/paas/v4/chat/completions -H 'Content-Type: application/json' -H \"Authorization: Bearer $ZAI_API_KEY\" -d";
    timeout_seconds = Env_config.Spawn.timeout_seconds;
    working_dir = None;
    mcp_tools = [];  (* GLM has no MCP support *)
  });
]

let get_config agent_name = 
  List.assoc_opt agent_name default_configs

(** Build MCP flags as argument list (no shell escaping needed) *)
let build_mcp_args agent_name tools = 
  if tools = [] then []
  else match agent_name with 
  | "claude" -> 
    let tools_str = String.concat "," tools in 
    ["--allowedTools"; tools_str]
  | "gemini" -> 
    ["--allowed-mcp-server-names"; "masc"; "--allowed-tools"] @ tools
  | _ -> []

(** Parse command string into executable and arguments *)
let parse_command cmd =
  let parts = String.split_on_char ' ' cmd in
  List.filter (fun s -> String.length s > 0) parts

type glm_spawn_success = {
  model_used: string;
  response_text: string;
  input_tokens_used: int option;
  output_tokens_used: int option;
  cost_estimate_usd: float option;
}

let call_glm_once ~api_key ~model ~prompt ~timeout_sec : (glm_spawn_success, string) result =
  let body =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("model", `String model);
          ( "messages",
            `List [ `Assoc [ ("role", `String "user"); ("content", `String prompt) ] ] );
          ("stream", `Bool false);
        ])
  in
  try
    let raw =
      Process_eio.run_argv_with_stdin
        ~timeout_sec:(Float.of_int timeout_sec +. 5.0)
        ~stdin_content:body
        [
          "curl";
          "-sS";
          "--max-time";
          string_of_int timeout_sec;
          "-X";
          "POST";
          "https://api.z.ai/api/coding/paas/v4/chat/completions";
          "-H";
          "Content-Type: application/json";
          "-H";
          Printf.sprintf "Authorization: Bearer %s" api_key;
          "-d";
          "@-";
        ]
    in
    match glm_error_message raw with
    | Some msg -> Error msg
    | None -> (
        try
          let json = Yojson.Safe.from_string raw in
          match extract_glm_message_text json with
          | Some text when String.trim text <> "" ->
              let input_tokens, output_tokens, cost_usd = parse_glm_output raw in
              Ok
                {
                  model_used = model;
                  response_text = text;
                  input_tokens_used = input_tokens;
                  output_tokens_used = output_tokens;
                  cost_estimate_usd = cost_usd;
                }
          | _ -> Error "empty glm response content"
        with Yojson.Json_error e -> Error (Printf.sprintf "invalid glm json: %s" e))
  with exn -> Error (Printexc.to_string exn)

let spawn_glm_with_cascade ~prompt ~timeout ~start_time : spawn_result =
  let api_key = Sys.getenv_opt "ZAI_API_KEY" |> Option.value ~default:"" in
  if String.trim api_key = "" then
    {
      success = false;
      output = "Spawn error (GLM): ZAI_API_KEY is not set";
      exit_code = 1;
      elapsed_ms = int_of_float ((Time_compat.now () -. start_time) *. 1000.0);
      input_tokens = None;
      output_tokens = None;
      cache_creation_tokens = None;
      cache_read_tokens = None;
      cost_usd = None;
    }
  else
    let models = glm_spawn_cascade_models_for_policy () in
    if models = [] then
      let configured = glm_spawn_cascade_models () in
      {
        success = false;
        output =
          Printf.sprintf
            "GLM cascade aborted: no models satisfy min context %d tokens (configured=%s)"
            (glm_min_context_tokens ())
            (String.concat "," configured);
        exit_code = 1;
        elapsed_ms = int_of_float ((Time_compat.now () -. start_time) *. 1000.0);
        input_tokens = None;
        output_tokens = None;
        cache_creation_tokens = None;
        cache_read_tokens = None;
        cost_usd = None;
      }
    else
    let deadline = start_time +. float_of_int timeout in
    let rec try_models errors = function
      | [] ->
          let summary =
            errors
            |> List.rev
            |> List.map (fun (m, e) -> Printf.sprintf "%s: %s" m e)
            |> String.concat " | "
          in
          {
            success = false;
            output = Printf.sprintf "GLM cascade failed (%s)" summary;
            exit_code = 1;
            elapsed_ms = int_of_float ((Time_compat.now () -. start_time) *. 1000.0);
            input_tokens = None;
            output_tokens = None;
            cache_creation_tokens = None;
            cache_read_tokens = None;
            cost_usd = None;
          }
      | model :: rest ->
          let raw_remaining = int_of_float (Float.ceil (deadline -. Time_compat.now ())) in
          if raw_remaining <= 0 then
            try_models (("timeout", "overall timeout exceeded") :: errors) []
          else
            let remaining = max 5 raw_remaining in
            match call_glm_once ~api_key ~model ~prompt ~timeout_sec:remaining with
            | Ok ok_resp ->
                {
                  success = true;
                  output = ok_resp.response_text;
                  exit_code = 0;
                  elapsed_ms = int_of_float ((Time_compat.now () -. start_time) *. 1000.0);
                  input_tokens = ok_resp.input_tokens_used;
                  output_tokens = ok_resp.output_tokens_used;
                  cache_creation_tokens = None;
                  cache_read_tokens = None;
                  cost_usd = ok_resp.cost_estimate_usd;
                }
            | Error e -> try_models ((model, e) :: errors) rest
    in
    try_models [] models

(** Spawn an agent using Eio.Process (direct execution, no shell)

    Agent Being Protocol: Cultural Inheritance
    - When room_config is provided, loads institution memory and injects it
    - New agents inherit: mission, values, patterns, onboarding steps
    - This enables multi-generational knowledge transfer
*)
let spawn ~sw ~proc_mgr ~agent_name ~prompt ?timeout_seconds ?working_dir ?room_config () : spawn_result =
  let start_time = Time_compat.now () in

  let config = match get_config agent_name with
    | Some c -> c
    | None -> {
        agent_name;
        command = agent_name;
        timeout_seconds = Option.value timeout_seconds ~default:Env_config.Spawn.timeout_seconds;
        working_dir;
        mcp_tools = [];
      }
  in

  let timeout = Option.value timeout_seconds ~default:config.timeout_seconds in
  let mcp_args = build_mcp_args agent_name config.mcp_tools in

  (* Agent Being Protocol: Inject institution memory for cultural inheritance
     Note: We use synchronous file loading here since spawn is already in Eio context
     Institution file is small (<10KB) so sync read is acceptable *)
  let institution_memory =
    let load_institution_sync base_path =
      let inst_file = Filename.concat (Filename.concat base_path ".masc") "institution.json" in
      if Sys.file_exists inst_file then
        try
          let ic = open_in inst_file in
          let content = Common.protect ~module_name:"spawn_eio" ~finally_label:"finalizer" ~finally:(fun () -> close_in_noerr ic)
            (fun () -> really_input_string ic (in_channel_length ic)) in
          let json = Yojson.Safe.from_string content in
          let inst = Institution_eio.institution_of_json json in
          Institution_eio.format_for_injection inst
        with exn ->
          Eio.traceln "[spawn_eio] Institution load failed: %s" (Printexc.to_string exn);
          ""
      else ""
    in
    match room_config with
    | Some rc -> load_institution_sync rc.Room_utils.base_path
    | None ->
        match working_dir with
        | Some wd -> load_institution_sync wd
        | None -> ""
  in

  let augmented_prompt = prompt ^ institution_memory ^ masc_lifecycle_suffix in

  (* GLM agents use dedicated cascade function (no chdir needed — direct HTTP).
     Non-GLM agents need chdir + fork protected by mutex. *)
  if agent_name = "glm" then
    spawn_glm_with_cascade ~prompt:augmented_prompt ~timeout ~start_time
  else
    (* Build command arguments outside the chdir critical section *)
    let base_args = parse_command config.command in
    let cmd_args = base_args @ mcp_args in
    let full_args = ["timeout"; string_of_int timeout] @ cmd_args in

    (* Serialize chdir + fork under mutex. Sys.chdir is process-global;
       without this, concurrent Eio fibers would race on the CWD. *)
    let (process, output_buf) =
      Eio.Mutex.use_rw ~protect:true chdir_mutex (fun () ->
        let original_dir = Sys.getcwd () in
        (match working_dir with Some d -> Sys.chdir d | None -> ());
        Fun.protect ~finally:(fun () -> Sys.chdir original_dir) (fun () ->
          let buf = Buffer.create 4096 in
          let proc =
            Eio.Process.spawn ~sw proc_mgr
              ~stdin:(Eio.Flow.string_source augmented_prompt)
              ~stdout:(Eio.Flow.buffer_sink buf)
              full_args
          in
          (proc, buf)))
    in

    let result =
      try
        let status = Eio.Process.await process in
        let raw_output = Buffer.contents output_buf in
        let exit_code =
          match status with
          | `Exited code -> code
          | `Signaled _ -> -1
        in

        let output, input_tokens, output_tokens, cache_creation, cache_read, cost_usd =
          match agent_name with
          | "claude" ->
              let result_opt, inp, out, cache_c, cache_r, cost =
                parse_claude_json raw_output
              in
              (Option.value result_opt ~default:raw_output, inp, out, cache_c, cache_r, cost)
          | "gemini" ->
              let inp, out, cached, cost = parse_gemini_output raw_output in
              (raw_output, inp, out, cached, None, cost)
          | "ollama" ->
              let inp, out, cost = parse_ollama_output raw_output in
              (raw_output, inp, out, None, None, cost)
          | "codex" ->
              let inp, out, cached, cost = parse_codex_output raw_output in
              (raw_output, inp, out, cached, None, cost)
          | _ -> (raw_output, None, None, None, None, None)
        in

        {
          success = (exit_code = 0);
          output;
          exit_code;
          elapsed_ms = int_of_float ((Time_compat.now () -. start_time) *. 1000.0);
          input_tokens;
          output_tokens;
          cache_creation_tokens = cache_creation;
          cache_read_tokens = cache_read;
          cost_usd;
        }
      with e ->
        {
          success = false;
          output = Printf.sprintf "Spawn error (Eio): %s" (Printexc.to_string e);
          exit_code = -99;
          elapsed_ms = int_of_float ((Time_compat.now () -. start_time) *. 1000.0);
          input_tokens = None;
          output_tokens = None;
          cache_creation_tokens = None;
          cache_read_tokens = None;
          cost_usd = None;
        }
    in
    result

let result_to_human_string (result : spawn_result) = 
  let token_info = 
    match result.input_tokens, result.output_tokens, result.cost_usd with 
    | Some inp, Some out, Some cost -> 
      let cache = match result.cache_creation_tokens, result.cache_read_tokens with 
        | Some cc, Some cr when cc > 0 || cr > 0 -> Printf.sprintf " (cache: +%d, %d)" cc cr
        | _ -> ""
      in 
      Printf.sprintf "\n📊 Tokens: %d in / %d out%s | Cost: $%.4f" inp out cache cost
    | _ -> ""
  in 
  if result.success then 
    Printf.sprintf "✅ Agent completed in %dms%s\n\n%s"
      result.elapsed_ms token_info result.output
  else 
    Printf.sprintf "❌ Agent failed (exit %d) in %dms%s\n\n%s"
      result.exit_code result.elapsed_ms token_info result.output
