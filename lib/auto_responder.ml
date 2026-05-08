(** Auto-Responder Daemon - Automatic @mention response

    When a broadcast message contains an @mention, optionally:
    - Spawn the mentioned CLI agent to respond (Spawn mode)
    - Use direct MODEL call + in-process MASC tool calls to respond (Model mode)

    Enable with: MASC_AUTO_RESPOND=true|spawn|model

    Design:
    - No shell execution (argv-only)
    - Non-blocking: work runs in an Eio fiber forked from the server switch
    - Rate-limited to prevent runaway mention loops
*)

open Yojson.Safe.Util

type mode = Disabled | Spawn | Model

let get_mode () =
  match Env_config_core.auto_respond_opt () with
  | Some "true" | Some "1" | Some "yes" | Some "spawn" -> Spawn
  | Some "model" | Some "fast" -> Model
  | _ -> Disabled

let is_enabled () = get_mode () <> Disabled

let activity_log_file () =
  match Env_config.base_path_opt () with
  | Some root -> Filename.concat (Common.masc_dir_from_base_path ~base_path:root) (Filename.concat "logs" "auto-responder.log")
  | None -> "/tmp/auto-responder.log"

let debug_log msg =
  let line = Printf.sprintf "[%f] %s\n" (Time_compat.now ()) msg in
  try Fs_compat.append_file "/tmp/auto_debug.log" line
  with Sys_error _ | Unix.Unix_error _ -> ()

let activity_log ~mode ~from_agent ~mention ~status ~detail =
  let log_file = activity_log_file () in
  let time = Unix.localtime (Time_compat.now ()) in
  let timestamp =
    Printf.sprintf "%04d-%02d-%02d %02d:%02d:%02d"
      (time.Unix.tm_year + 1900)
      (time.Unix.tm_mon + 1)
      time.Unix.tm_mday
      time.Unix.tm_hour
      time.Unix.tm_min
      time.Unix.tm_sec
  in
  let mode_str = match mode with Disabled -> "OFF" | Spawn -> "SPAWN" | Model -> "MODEL" in
  let line = Printf.sprintf "[%s] [%s] %s → @%s | %s | %s\n"
    timestamp mode_str from_agent mention status detail in
  try Fs_compat.append_file log_file line
  with Sys_error _ | Unix.Unix_error _ -> ()

(* --- Loop prevention / throttling --- *)

(** Per-agent-type timestamp list for rate limiting.
    Key = agent_type, Value = recent response timestamps (newest first).
    O(1) lookup per agent_type — no string prefix scanning.

    [should_throttle] does read-filter-write on [response_times].
    [maybe_respond] is invoked from the broadcast path for every message
    and can run concurrently for different mentions; without a mutex the
    throttle counter silently loses updates.  [Stdlib.Mutex] because the
    broadcast handler may cross a domain boundary. *)
let response_times : (string, float list) Hashtbl.t = Hashtbl.create 8
let response_times_mu = Stdlib.Mutex.create ()
let chain_limit = 3
let chain_window_sec = 60.0

let with_throttle_lock f =
  Stdlib.Mutex.lock response_times_mu;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock response_times_mu)
    f

let should_throttle ~agent_type =
  let now = Time_compat.now () in
  with_throttle_lock (fun () ->
    let recent =
      (match Hashtbl.find_opt response_times agent_type with
       | None -> []
       | Some times -> List.filter (fun ts -> now -. ts < chain_window_sec) times)
    in
    if List.length recent >= chain_limit then (
      debug_log (Printf.sprintf "THROTTLE: %s has %d responses in last %.0fs"
        agent_type (List.length recent) chain_window_sec);
      Hashtbl.replace response_times agent_type recent;
      true
    ) else (
      Hashtbl.replace response_times agent_type (now :: recent);
      false
    ))

(* --- Mention helpers (re-export) --- *)

let agent_type_of_mention = Mention.agent_type_of_mention

let is_spawnable mention =
  let base = agent_type_of_mention mention in
  Provider_adapter.resolve_spawn_key base <> None

(* --- CLI spawn (Spawn mode) --- *)

let build_response_prompt ~from_agent ~content ~mention =
  Printf.sprintf {|You received a mention in the MASC room from %s.

Message: "%s"

Quick response protocol:
1. Call mcp__masc__masc_join(agent_name="%s")
   → Read the response to get your assigned nickname (e.g., "gemini-rare-beaver")
2. Call mcp__masc__masc_broadcast using YOUR ASSIGNED NICKNAME from step 1:
   mcp__masc__masc_broadcast(agent_name="<your-assigned-nickname>", message="[your concise response]")
   IMPORTANT: Do NOT use "%s" - use the full nickname from the join response!
3. Call mcp__masc__masc_leave()

Respond in 1-2 sentences. Be helpful and concise.|}
    from_agent content mention mention

let cli_argv_of_agent_type (agent_type : string) : string list =
  match Spawn.get_config agent_type with
  | Some config ->
    String.split_on_char ' ' config.command
    |> List.filter (fun s -> s <> "")
  | None -> [agent_type]

let run_cli_agent ~agent_type ~prompt =
  if Provider_adapter.is_bare_ollama_label agent_type then
    debug_log (Provider_adapter.bare_ollama_migration_message ())
  else
    let base = cli_argv_of_agent_type agent_type in
    let argv = base in
    let raw_source = String.concat " " (List.map Filename.quote argv) in
    debug_log (Printf.sprintf "SPAWN argv=%s" (String.concat " " (List.map Filename.quote argv)));
    let (status, output) =
      Masc_exec.Exec_gate.run_argv_with_stdin_and_status
        ~actor:"system/auto_responder"
        ~raw_source
        ~summary:"auto responder cli spawn"
        ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Auto_responder ())
        ~stdin_content:prompt
        argv
    in
    let status_s = match status with
      | Unix.WEXITED n -> Printf.sprintf "exit=%d" n
      | Unix.WSIGNALED n -> Printf.sprintf "signaled=%d" n
      | Unix.WSTOPPED n -> Printf.sprintf "stopped=%d" n
    in
    let preview =
      let s = String.trim output in
      String_util.utf8_safe ~max_bytes:203 ~suffix:"..." s |> String_util.to_string
    in
    debug_log (Printf.sprintf "SPAWN_DONE %s output=%s" status_s preview)

(* --- MODEL mode: shared cascade + in-process MASC HTTP tools/call --- *)

let cascade_name_for_agent_type _agent_type =
  Keeper_cascade_profile.cascade_name_for_use
    Keeper_cascade_profile.Auto_responder

(** Validate model response using structural fields, not text heuristics.
    Guardrail principle: accept unless there is a clear structural reason to reject.
    Permissive by default: any non-empty content with any stop_reason is valid.
    Invariant: API errors are caught upstream by Oas_worker.run_named returning Error;
    the accept callback only receives responses where the API call succeeded. *)
let model_response_is_valid (resp : Agent_sdk_response.api_response) =
  let text = String.trim (Agent_sdk_response.text_of_response resp) in
  String.length text > 0
  && (match resp.stop_reason with
      | Agent_sdk.Types.EndTurn | Agent_sdk.Types.MaxTokens
      | Agent_sdk.Types.StopSequence | Agent_sdk.Types.StopToolUse
      | Agent_sdk.Types.Unknown _ -> true)

let call_model_direct_sync ~agent_type ~prompt =
  let cascade_name = cascade_name_for_agent_type agent_type in
  try
    match
      Masc_oas_bridge.run_with_caller
        ~caller:Env_config_oas_bridge.Auto_responder (fun () ->
        Oas_worker.run_named ~cascade_name
          ~goal:prompt ~max_turns:1
          ~accept:model_response_is_valid ~max_tokens:500
          ~approval:Approval_callbacks.auto_approve
          ()
      )
    with
    | Ok result ->
        let resp = result.Oas_worker.response in
        let text = Agent_sdk_response.text_of_response resp in
        debug_log
          (Printf.sprintf "MODEL_USED %s for agent_type=%s"
             resp.model agent_type);
        if String.trim text = "" then "no response" else text
    | Error err ->
        Log.AutoResponder.error "MODEL cascade failed: %s" (Agent_sdk.Error.to_string err);
        "no response"
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.AutoResponder.error "MODEL call failed: %s" (Printexc.to_string exn);
    "no response"

let masc_call ~sw:_ ~tool_name ~(args : Yojson.Safe.t) : (string, string) result =
  let uri = Uri.of_string (Env_config.masc_http_base_url () ^ "/mcp") in
  let body =
    `Assoc [
      ("jsonrpc", `String "2.0");
      ("method", `String "tools/call");
      ("id", `Int 1);
      ("params", `Assoc [
        ("name", `String tool_name);
        ("arguments", args);
      ]);
    ]
    |> Yojson.Safe.to_string
  in
  match Eio_context.get_net_opt () with
  | None -> Error "Eio net not initialized"
  | Some net ->
      let headers = [
        ("Content-Type", "application/json");
        ("Accept", "application/json, text/event-stream");
      ] in
      (match Masc_http_client.post_sync ~net ~url:(Uri.to_string uri)
          ~headers ~body () with
      | Error e -> Error e
      | Ok (code, body_str) ->
        if not (Cohttp.Code.is_success code) then
          Error (Printf.sprintf "MASC HTTP %d" code)
        else
          (* Extract MCP tool text: result.content[0].text *)
          try
            let json = Yojson.Safe.from_string body_str in
            match json |> member "result" |> member "content" |> to_list with
            | item :: _ -> Ok (item |> member "text" |> to_string)
            | [] -> Error "empty content list"
          with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn ->
            Log.Misc.warn "auto_responder: MCP response parse failed: %s" (Printexc.to_string exn);
            Ok body_str)

let extract_nickname (response_text : string) : string option =
  let prefix = "Nickname:" in
  let lines = String.split_on_char '\n' response_text in
  let rec find = function
    | [] -> None
    | line :: rest ->
        let trimmed = String.trim line in
        if String.starts_with trimmed ~prefix
        then
          Some
            (String.trim
               (String.sub trimmed (String.length prefix)
                  (String.length trimmed - String.length prefix)))
        else find rest
  in
  find lines

let call_model_and_broadcast ~sw ~agent_type ~prompt ~mention =
  let response = call_model_direct_sync ~agent_type ~prompt in
  debug_log (Printf.sprintf "MODEL_RESPONSE: %s"
    (String_util.utf8_safe ~max_bytes:103 ~suffix:"..." response |> String_util.to_string));
  if response = "" || response = "no response" then
    Log.AutoResponder.info "MODEL returned empty response"
  else begin
    let join_args =
      `Assoc [
        ("agent_name", `String agent_type);
        ("capabilities", `List [`String "model-auto-responder"]);
      ]
    in
    match
      masc_call ~sw
        ~tool_name:(Tool_name.Masc.to_string Tool_name.Masc.Join)
        ~args:join_args
    with
    | Error e ->
        debug_log (Printf.sprintf "MASC_JOIN_FAILED: %s" e);
        Log.AutoResponder.error "Failed to join MASC (%s)" e
    | Ok join_resp -> (
        debug_log (Printf.sprintf "MASC_JOIN: %s"
          (String_util.utf8_safe ~max_bytes:203 ~suffix:"..." join_resp |> String_util.to_string));
        match extract_nickname join_resp with
        | None ->
            debug_log "MASC_JOIN_FAILED: Could not extract nickname";
            Log.AutoResponder.error "Failed to join MASC (no nickname)"
        | Some nickname ->
            let msg = Printf.sprintf "@%s %s" mention response in
            let broadcast_args = `Assoc [("agent_name", `String nickname); ("message", `String msg)] in
            (try
               ignore
                 (masc_call ~sw
                    ~tool_name:(Tool_name.Masc.to_string Tool_name.Masc.Broadcast)
                    ~args:broadcast_args)
             with
             | Eio.Cancel.Cancelled _ as e -> raise e
             | exn -> Log.AutoResponder.error "broadcast failed: %s" (Printexc.to_string exn));
            let leave_args = `Assoc [("agent_name", `String nickname)] in
            (try
               ignore
                 (masc_call ~sw
                    ~tool_name:(Tool_name.Masc.to_string Tool_name.Masc.Leave)
                    ~args:leave_args)
             with
             | Eio.Cancel.Cancelled _ as e -> raise e
             | exn -> Log.AutoResponder.error "leave failed: %s" (Printexc.to_string exn));
            let short_resp = String_util.utf8_safe ~max_bytes:53 ~suffix:"..." response |> String_util.to_string in
            Log.AutoResponder.info "%s: %s" nickname short_resp
      )
  end

(* --- Public API --- *)

let maybe_respond ~sw ~base_path:_ ~from_agent ~content ~mention =
  let mode = get_mode () in
  let mode_str = match mode with Disabled -> "Disabled" | Spawn -> "Spawn" | Model -> "Model" in
  debug_log (Printf.sprintf "CALLED: from=%s mention=%s mode=%s enabled=%b"
    from_agent (match mention with Some m -> m | None -> "NONE") mode_str (is_enabled ()));
  match mention with
  | None ->
      debug_log "EXIT: No mention";
      None
  | Some _ when not (is_enabled ()) ->
      let env_val = match Env_config_core.auto_respond_opt () with Some v -> v | None -> "not set" in
      debug_log (Printf.sprintf "EXIT: Disabled (env=%s)" env_val);
      Log.AutoResponder.info "Disabled (MASC_AUTO_RESPOND=%s)" env_val;
      None
  | Some m ->
      let from_base = agent_type_of_mention from_agent in
      let mention_base = agent_type_of_mention m in
      debug_log (Printf.sprintf "CHECK: from_base=%s mention_base=%s spawnable=%b" from_base mention_base (is_spawnable m));
      if from_base = mention_base then (
        debug_log "EXIT: Self-mention";
        Log.AutoResponder.info "Skip self-mention @%s from %s" m from_agent;
        None
      ) else if not (is_spawnable m) then (
        debug_log "EXIT: Not spawnable";
        activity_log ~mode ~from_agent ~mention:m ~status:"SKIP" ~detail:"Not spawnable agent type";
        Log.AutoResponder.info "@%s not spawnable" m;
        None
      ) else if should_throttle ~agent_type:mention_base then (
        debug_log "EXIT: Throttled";
        activity_log ~mode ~from_agent ~mention:m ~status:"THROTTLE"
          ~detail:(Printf.sprintf "Max %d responses per %.0fs" chain_limit chain_window_sec);
        Log.AutoResponder.info "Throttled @%s (chain limit)" m;
        None
      ) else (
        let task_id =
          Printf.sprintf "auto-respond-%s-%d" mention_base
            (int_of_float (Time_compat.now () *. 1000.) mod 10000)
        in
        debug_log (Printf.sprintf "DISPATCH: mode=%s task_id=%s" mode_str task_id);
        activity_log ~mode ~from_agent ~mention:m
          ~status:(match mode with Spawn -> "SPAWN" | Model -> "MODEL" | Disabled -> "OFF")
          ~detail:task_id;
        Eio.Fiber.fork ~sw (fun () ->
          try
            match mode with
            | Disabled -> ()
            | Model ->
                Log.AutoResponder.info "Calling %s for @%s" mention_base m;
                call_model_and_broadcast ~sw ~agent_type:mention_base ~prompt:content ~mention:from_agent
            | Spawn ->
                let prompt = build_response_prompt ~from_agent ~content ~mention:m in
                Log.AutoResponder.info "Spawning %s for @%s from %s" mention_base m from_agent;
                run_cli_agent ~agent_type:mention_base ~prompt
          with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn ->
            debug_log (Printf.sprintf "ERROR: %s" (Printexc.to_string exn))
        );
        Some task_id
      )
