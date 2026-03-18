(** Mitosis_spawn — Agent spawn cascade with circuit breaker,
    readiness checks, and multi-agent fallback.

    Includes Mitosis_helpers for context types and verifier logic. *)

include Mitosis_helpers

(** Normalize agent names for fallback selection *)
let normalize_agent_name agent =
  String.lowercase_ascii (String.trim agent)

let validate_target_agent_label target_agent =
  if Provider_adapter.is_bare_ollama_label target_agent then
    Error (Provider_adapter.bare_ollama_migration_message ())
  else
    Ok (normalize_agent_name target_agent)

let dedup_preserve_order xs =
  let rec loop seen acc = function
    | [] -> List.rev acc
    | x :: rest ->
        if x = "" || List.mem x seen then
          loop seen acc rest
        else
          loop (x :: seen) (x :: acc) rest
  in
  loop [] [] xs

let cascade_agents preferred =
  dedup_preserve_order [
    normalize_agent_name preferred;
    "claude";
    "codex";
    "gemini";
    "llama";
  ]

let spawn_attempts_to_json attempts =
  `List (List.map (fun (agent, result) ->
    `Assoc [
      ("agent", `String agent);
      ("success", `Bool result.Spawn.success);
      ("exit_code", `Int result.Spawn.exit_code);
      ("elapsed_ms", `Int result.Spawn.elapsed_ms);
      ("output", `String (Mitosis.safe_sub result.Spawn.output 0 300));
    ]) attempts)

let now_s () = Time_compat.now ()

let min_attempt_timeout_s = 5
let max_tool_window_s = 120

let failed_spawn_result ~msg ~exit_code : Spawn.spawn_result =
  {
    Spawn.success = false;
    output = msg;
    exit_code;
    elapsed_ms = 0;
    input_tokens = None;
    output_tokens = None;
    cache_creation_tokens = None;
    cache_read_tokens = None;
    cost_usd = None;
  }

let normalized_spawn_reason (result : Spawn.spawn_result) : string =
  let raw = String.trim result.Spawn.output in
  let base =
    if raw = "" then
      "spawn failed"
    else
      Mitosis.safe_sub raw 0 240
  in
  if result.Spawn.exit_code = 124 then
    "spawn timeout: " ^ base
  else
    base

let should_penalize_failure (result : Spawn.spawn_result) : bool =
  (* Long-running CLI agents may timeout while still producing useful output.
     Treat those as soft failures to avoid breaker-open storms in succession loops. *)
  if result.Spawn.success then
    false
  else if result.Spawn.exit_code = 124 && String.trim result.Spawn.output <> "" then
    false
  else
    true

let command_available cmd =
  let path =
    match Sys.getenv_opt "PATH" with Some p -> p | None -> "/usr/bin:/bin"
  in
  let dirs = String.split_on_char ':' path in
  List.exists
    (fun dir ->
      let full_path = Filename.concat dir cmd in
      try
        let stat = Unix.stat full_path in
        stat.Unix.st_kind = Unix.S_REG && stat.Unix.st_perm land 0o111 <> 0
      with Unix.Unix_error _ -> false)
    dirs

let port_listening port =
  try
    let sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
    Fun.protect
      ~finally:(fun () -> (try Unix.close sock with Unix.Unix_error _ -> ()))
      (fun () ->
        Unix.connect sock (Unix.ADDR_INET (Unix.inet_addr_loopback, port));
        true)
  with Unix.Unix_error _ -> false

let readiness_check agent =
  match agent with
  | "claude" ->
      if command_available "claude" then Ok () else Error "claude CLI not found"
  | "codex" ->
      if command_available "codex" then Ok () else Error "codex CLI not found"
  | "gemini" ->
      if command_available "gemini" then Ok () else Error "gemini CLI not found"
  | "llama" ->
      let port = Env_config_runtime.Llama.server_url
        |> Uri.of_string |> Uri.port
        |> Option.value ~default:8085
      in
      if not (port_listening port) then
        Error (Printf.sprintf "llama port %d not listening" port)
      else Ok ()
  | _ -> Ok ()

let breaker_agent_id agent = "spawn:" ^ agent

let spawn_with_cascade ~ctx ~preferred_agent ~total_timeout_seconds ~prompt =
  let agents = cascade_agents preferred_agent in
  let start_ts = now_s () in
  let total_budget = max 1 (min max_tool_window_s total_timeout_seconds) in
  let rec loop attempts remaining_agents = function
    | [] ->
        let fallback_result, selected =
          match attempts with
          | (agent, result) :: _ -> (result, agent)
          | [] ->
              ({ Spawn.success = false;
                 output = "No spawn candidates available";
                 exit_code = 1;
                 elapsed_ms = 0;
                 input_tokens = None;
                 output_tokens = None;
                 cache_creation_tokens = None;
                 cache_read_tokens = None;
                 cost_usd = None }, normalize_agent_name preferred_agent)
        in
        (fallback_result, selected, List.rev attempts)
    | agent :: rest ->
        let attempts_agent_left = max 1 remaining_agents in
        let elapsed = int_of_float (now_s () -. start_ts) in
        let remaining = total_budget - elapsed in
        if remaining <= 0 then
          let fallback_result, selected =
            match attempts with
            | (a, r) :: _ -> (r, a)
            | [] ->
                ({ Spawn.success = false;
                   output = "Cascade timeout budget exhausted";
                   exit_code = 124;
                   elapsed_ms = total_budget * 1000;
                   input_tokens = None;
                   output_tokens = None;
                   cache_creation_tokens = None;
                   cache_read_tokens = None;
                   cost_usd = None }, normalize_agent_name preferred_agent)
          in
          (fallback_result, selected, List.rev attempts)
        else begin
          match Circuit_breaker.check_global ~agent_id:(breaker_agent_id agent) with
          | Error reason ->
              let result = failed_spawn_result ~msg:reason ~exit_code:125 in
              let attempts' = (agent, result) :: attempts in
              loop attempts' (attempts_agent_left - 1) rest
          | Ok () ->
              begin match readiness_check agent with
              | Error reason ->
                  (try ignore (Circuit_breaker.record_failure_global
                    ~agent_id:(breaker_agent_id agent)
                    ~reason)
                   with exn -> Printf.eprintf "[mitosis] circuit_breaker record_failure failed: %s\n%!" (Printexc.to_string exn));
                  let result = failed_spawn_result ~msg:reason ~exit_code:125 in
                  let attempts' = (agent, result) :: attempts in
                  loop attempts' (attempts_agent_left - 1) rest
              | Ok () ->
                  let base_timeout =
                    max min_attempt_timeout_s (remaining / attempts_agent_left)
                  in
                  let per_attempt_timeout =
                    if attempts = [] && agent = normalize_agent_name preferred_agent then
                      (* Give preferred agent the full initial budget before cascading. *)
                      max min_attempt_timeout_s remaining
                    else
                      base_timeout
                  in
                  let spawn_fn =
                    make_spawn_fn ~ctx ~agent_name:agent ~timeout_seconds:per_attempt_timeout
                  in
                  let result = spawn_fn ~prompt in
                  if result.Spawn.success then
                    (try ignore (Circuit_breaker.record_success_global
                      ~agent_id:(breaker_agent_id agent))
                     with exn -> Printf.eprintf "[mitosis] circuit_breaker record_success failed: %s\n%!" (Printexc.to_string exn))
                  else if should_penalize_failure result then
                    (try ignore (Circuit_breaker.record_failure_global
                      ~agent_id:(breaker_agent_id agent)
                      ~reason:(normalized_spawn_reason result))
                     with exn -> Printf.eprintf "[mitosis] circuit_breaker record_failure (spawn) failed: %s\n%!" (Printexc.to_string exn));
                  let attempts' = (agent, result) :: attempts in
                  if result.Spawn.success then
                    (result, agent, List.rev attempts')
                  else
                    loop attempts' (attempts_agent_left - 1) rest
              end
        end
  in
  loop [] (List.length agents) agents

(** {1 Individual Handlers} *)

