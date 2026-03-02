(** Auto-Responder Daemon - Automatic @mention response

    When a broadcast message contains an @mention, optionally:
    - Spawn the mentioned CLI agent to respond (Spawn mode)
    - Use direct LLM call + in-process MASC tool calls to respond (Llm mode)

    Enable with: MASC_AUTO_RESPOND=true|spawn|llm

    Design:
    - No shell execution (argv-only)
    - Non-blocking: work runs in an Eio fiber forked from the server switch
    - Rate-limited to prevent runaway mention loops
*)

open Yojson.Safe.Util

type mode = Disabled | Spawn | Llm

let get_mode () =
  match Sys.getenv_opt "MASC_AUTO_RESPOND" with
  | Some "true" | Some "1" | Some "yes" | Some "spawn" -> Spawn
  | Some "llm" | Some "fast" -> Llm
  | _ -> Disabled

let is_enabled () = get_mode () <> Disabled

let activity_log_file () =
  match Sys.getenv_opt "ME_ROOT" with
  | Some root -> root ^ "/logs/auto-responder.log"
  | None -> "/tmp/auto-responder.log"

let debug_log msg =
  let oc = open_out_gen [Open_creat; Open_append; Open_text] 0o644 "/tmp/auto_debug.log" in
  Common.protect ~module_name:"auto_responder" ~finally_label:"finalizer"
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> Printf.fprintf oc "[%f] %s\n%!" (Time_compat.now ()) msg)

let activity_log ~mode ~from_agent ~mention ~status ~detail =
  let log_file = activity_log_file () in
  let oc = open_out_gen [Open_creat; Open_append; Open_text] 0o644 log_file in
  Common.protect ~module_name:"auto_responder" ~finally_label:"finalizer"
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
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
      let mode_str = match mode with Disabled -> "OFF" | Spawn -> "SPAWN" | Llm -> "LLM" in
      Printf.fprintf oc "[%s] [%s] %s → @%s | %s | %s\n%!"
        timestamp mode_str from_agent mention status detail)

(* --- Loop prevention / throttling --- *)

let recent_responses : (string, float) Hashtbl.t = Hashtbl.create 16
let chain_limit = 3
let chain_window = 60.0

let should_throttle ~agent_type =
  let now = Time_compat.now () in
  Hashtbl.filter_map_inplace (fun _ ts -> if now -. ts < chain_window then Some ts else None) recent_responses;
  let count =
    Hashtbl.fold (fun k _ acc ->
      if String.length k >= String.length agent_type
         && String.sub k 0 (String.length agent_type) = agent_type
      then acc + 1 else acc
    ) recent_responses 0
  in
  if count >= chain_limit then (
    debug_log (Printf.sprintf "THROTTLE: %s has %d responses in last %.0fs" agent_type count chain_window);
    true
  ) else (
    Hashtbl.add recent_responses (Printf.sprintf "%s-%f" agent_type now) now;
    false
  )

(* --- Mention helpers (re-export) --- *)

let spawnable_agents = Mention.spawnable_agents
let agent_type_of_mention = Mention.agent_type_of_mention
let is_spawnable = Mention.is_spawnable

(* --- CLI spawn (Spawn mode) --- *)

let has_timeout =
  lazy (String.trim (Process_eio.run_argv ~timeout_sec:2.0 ["which"; "timeout"]) <> "")

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
  match agent_type with
  | "claude" -> ["claude"; "-p"; "--allowedTools"; "mcp__masc__*"]
  | "gemini" -> ["gemini"; "--yolo"]
  | "codex" -> ["codex"; "exec"]
  | "ollama" -> ["ollama"; "run"; Env_config.Ollama.default_model]
  | other -> [other]

let run_cli_agent ~agent_type ~prompt =
  let base = cli_argv_of_agent_type agent_type in
  let argv = if Lazy.force has_timeout then ["timeout"; "120"] @ base else base in
  debug_log (Printf.sprintf "SPAWN argv=%s" (String.concat " " (List.map Filename.quote argv)));
  let (status, output) =
    Process_eio.run_argv_with_stdin_and_status
      ~timeout_sec:140.0
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
    if String.length s > 200 then String.sub s 0 200 ^ "..." else s
  in
  debug_log (Printf.sprintf "SPAWN_DONE %s output=%s" status_s preview)

(* --- LLM mode: direct call + in-process MASC HTTP tools/call --- *)

let call_llm_direct_sync ~agent_type ~prompt =
  let tool_name =
    match agent_type with
    | "gemini" -> "glm" (* Gemini not directly supported, use GLM *)
    | "claude" -> "claude-cli"
    | "codex" -> "ollama" (* Codex not directly supported, use Ollama *)
    | "glm" -> "glm"
    | _ -> "ollama"
  in
  let model =
    match tool_name with
    | "glm" -> "glm-4.7"
    | "ollama" -> Env_config.Ollama.default_model
    | "claude-cli" -> "claude-sonnet-4-20250514"
    | _ -> "glm-4-flash"
  in
  try
    let response =
      Llm_direct.dispatch ~tool_name ~model ~prompt ~timeout_sec:30 ~max_chars:500 ()
    in
    if response = "" then "no response" else response
  with exn ->
    Printf.eprintf "[auto_responder] LLM call failed: %s\n%!" (Printexc.to_string exn);
    "no response"

let masc_call ~sw ~tool_name ~(args : Yojson.Safe.t) : (string, string) result =
  let masc_port = match Sys.getenv_opt "MASC_HTTP_PORT" with Some p -> p | None -> "8935" in
  let uri = Uri.of_string (Printf.sprintf "http://127.0.0.1:%s/mcp" masc_port) in
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
      let client = Cohttp_eio.Client.make ~https:None net in
      let headers = Cohttp.Header.of_list [
        ("Content-Type", "application/json");
        ("Accept", "application/json, text/event-stream");
      ] in
      let body_content = Eio.Flow.string_source body in
      try
        let resp, resp_body = Cohttp_eio.Client.post client ~sw uri ~headers ~body:body_content in
        let status = Cohttp.Response.status resp |> Cohttp.Code.code_of_status in
        let body_str = Eio.Buf_read.(parse_exn take_all) resp_body ~max_size:(8 * 1024 * 1024) in
        if not (Cohttp.Code.is_success status) then
          Error (Printf.sprintf "MASC HTTP %d" status)
        else
          (* Extract MCP tool text: result.content[0].text *)
          try
            let json = Yojson.Safe.from_string body_str in
            let txt =
              json |> member "result" |> member "content" |> to_list |> List.hd
                  |> member "text" |> to_string
            in
            Ok txt
          with _ ->
            Ok body_str
      with exn ->
        Error (Printexc.to_string exn)

let extract_nickname (response_text : string) : string option =
  let lines = String.split_on_char '\n' response_text in
  let rec find = function
    | [] -> None
    | line :: rest ->
        if String.length line > 12 && String.sub line 0 10 = "  Nickname:" then
          Some (String.trim (String.sub line 10 (String.length line - 10)))
        else find rest
  in
  find lines

let call_llm_and_broadcast ~sw ~agent_type ~prompt ~mention =
  let response = call_llm_direct_sync ~agent_type ~prompt in
  debug_log (Printf.sprintf "LLM_RESPONSE: %s"
    (if String.length response > 100 then String.sub response 0 100 ^ "..." else response));
  if response = "" || response = "no response" then
    Printf.eprintf "[Auto-Responder/LLM] LLM returned empty response\n%!"
  else begin
    let join_args =
      `Assoc [
        ("agent_name", `String agent_type);
        ("capabilities", `List [`String "llm-auto-responder"]);
      ]
    in
    match masc_call ~sw ~tool_name:"masc_join" ~args:join_args with
    | Error e ->
        debug_log (Printf.sprintf "MASC_JOIN_FAILED: %s" e);
        Printf.eprintf "[Auto-Responder/LLM] Failed to join MASC (%s)\n%!" e
    | Ok join_resp -> (
        debug_log (Printf.sprintf "MASC_JOIN: %s"
          (if String.length join_resp > 200 then String.sub join_resp 0 200 ^ "..." else join_resp));
        match extract_nickname join_resp with
        | None ->
            debug_log "MASC_JOIN_FAILED: Could not extract nickname";
            Printf.eprintf "[Auto-Responder/LLM] Failed to join MASC (no nickname)\n%!"
        | Some nickname ->
            let msg = Printf.sprintf "@%s %s" mention response in
            let broadcast_args = `Assoc [("agent_name", `String nickname); ("message", `String msg)] in
            (try ignore (masc_call ~sw ~tool_name:"masc_broadcast" ~args:broadcast_args)
             with exn -> Printf.eprintf "[auto-responder] broadcast failed: %s\n%!" (Printexc.to_string exn));
            let leave_args = `Assoc [("agent_name", `String nickname)] in
            (try ignore (masc_call ~sw ~tool_name:"masc_leave" ~args:leave_args)
             with exn -> Printf.eprintf "[auto-responder] leave failed: %s\n%!" (Printexc.to_string exn));
            let short_resp = if String.length response > 50 then String.sub response 0 50 ^ "..." else response in
            Printf.eprintf "[Auto-Responder/LLM] %s: %s\n%!" nickname short_resp
      )
  end

(* --- Public API --- *)

let maybe_respond ~sw ~base_path:_ ~from_agent ~content ~mention =
  let mode = get_mode () in
  let mode_str = match mode with Disabled -> "Disabled" | Spawn -> "Spawn" | Llm -> "Llm" in
  debug_log (Printf.sprintf "CALLED: from=%s mention=%s mode=%s enabled=%b"
    from_agent (match mention with Some m -> m | None -> "NONE") mode_str (is_enabled ()));
  match mention with
  | None ->
      debug_log "EXIT: No mention";
      None
  | Some _ when not (is_enabled ()) ->
      let env_val = match Sys.getenv_opt "MASC_AUTO_RESPOND" with Some v -> v | None -> "not set" in
      debug_log (Printf.sprintf "EXIT: Disabled (env=%s)" env_val);
      Printf.eprintf "[Auto-Responder] Disabled (MASC_AUTO_RESPOND=%s)\n%!" env_val;
      None
  | Some m ->
      let from_base = agent_type_of_mention from_agent in
      let mention_base = agent_type_of_mention m in
      debug_log (Printf.sprintf "CHECK: from_base=%s mention_base=%s spawnable=%b" from_base mention_base (is_spawnable m));
      if from_base = mention_base then (
        debug_log "EXIT: Self-mention";
        Printf.eprintf "[Auto-Responder] Skip self-mention @%s from %s\n%!" m from_agent;
        None
      ) else if not (is_spawnable m) then (
        debug_log "EXIT: Not spawnable";
        activity_log ~mode ~from_agent ~mention:m ~status:"SKIP" ~detail:"Not spawnable agent type";
        Printf.eprintf "[Auto-Responder] @%s not spawnable\n%!" m;
        None
      ) else if should_throttle ~agent_type:mention_base then (
        debug_log "EXIT: Throttled";
        activity_log ~mode ~from_agent ~mention:m ~status:"THROTTLE"
          ~detail:(Printf.sprintf "Max %d responses per %.0fs" chain_limit chain_window);
        Printf.eprintf "[Auto-Responder] Throttled @%s (chain limit)\n%!" m;
        None
      ) else (
        let task_id =
          Printf.sprintf "auto-respond-%s-%d" mention_base
            (int_of_float (Time_compat.now () *. 1000.) mod 10000)
        in
        debug_log (Printf.sprintf "DISPATCH: mode=%s task_id=%s" mode_str task_id);
        activity_log ~mode ~from_agent ~mention:m
          ~status:(match mode with Spawn -> "SPAWN" | Llm -> "LLM" | Disabled -> "OFF")
          ~detail:task_id;
        Eio.Fiber.fork ~sw (fun () ->
          try
            match mode with
            | Disabled -> ()
            | Llm ->
                Printf.eprintf "[Auto-Responder/LLM] Calling %s for @%s\n%!" mention_base m;
                call_llm_and_broadcast ~sw ~agent_type:mention_base ~prompt:content ~mention:from_agent
            | Spawn ->
                if mention_base = "glm" then (
                  (* No CLI for glm; use LLM mode path. *)
                  Printf.eprintf "[Auto-Responder/LLM-GLM] Calling glm for @%s\n%!" m;
                  call_llm_and_broadcast ~sw ~agent_type:"glm" ~prompt:content ~mention:from_agent
                ) else (
                  let prompt = build_response_prompt ~from_agent ~content ~mention:m in
                  Printf.eprintf "[Auto-Responder/Spawn] Spawning %s for @%s from %s\n%!" mention_base m from_agent;
                  run_cli_agent ~agent_type:mention_base ~prompt
                )
          with exn ->
            debug_log (Printf.sprintf "ERROR: %s" (Printexc.to_string exn))
        );
        Some task_id
      )

