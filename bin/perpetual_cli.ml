(** Perpetual CLI — Standalone perpetual agent runner.

    Runs a perpetual agent outside of the MASC MCP server.
    Useful for testing and standalone deployment.

    Usage:
      ./perpetual_cli --goal "Task description" --models "glm:glm-4.7,gemini:gemini-2.5-pro"
      ./perpetual_cli --status
      ./perpetual_cli --goal "Count to 10" --models "glm:glm-4.7" --no-verify

    @since 2.61.0 *)

open Masc_mcp
open Printf

(* ================================================================ *)
(* Event Logger                                                     *)
(* ================================================================ *)

let log_event = function
  | Perpetual_loop.TurnStart n ->
    eprintf "[turn %d] Starting...\n%!" n
  | Perpetual_loop.TurnEnd { turn; tokens_used; cost } ->
    eprintf "[turn %d] Done: %d tokens, $%.4f\n%!" turn tokens_used cost
  | Perpetual_loop.Compacted { before_tokens; after_tokens } ->
    eprintf "[compact] %d → %d tokens (%.0f%% reduction)\n%!"
      before_tokens after_tokens
      (100.0 *. (1.0 -. float_of_int after_tokens /. float_of_int (max 1 before_tokens)))
  | Perpetual_loop.Prepared { dna_size } ->
    eprintf "[prepare] DNA extracted: %d bytes\n%!" dna_size
  | Perpetual_loop.Handoff { to_model; generation } ->
    eprintf "[handoff] → %s (generation %d)\n%!" to_model generation
  | Perpetual_loop.Verified { action; verdict } ->
    eprintf "[verify] %s → %s\n%!" action verdict
  | Perpetual_loop.Heartbeat { turn; context_pct } ->
    eprintf "[heartbeat] turn=%d, context=%.1f%%\n%!" turn context_pct
  | Perpetual_loop.Error msg ->
    eprintf "[ERROR] %s\n%!" msg
  | Perpetual_loop.IdleDetected n ->
    eprintf "[idle] %d consecutive idle turns\n%!" n
  | Perpetual_loop.Terminated reason ->
    eprintf "[terminated] %s\n%!" reason
  | Perpetual_loop.CodingSpawn { agent; exit_code; elapsed_ms } ->
    eprintf "[coding] agent=%s exit=%d elapsed=%dms\n%!" agent exit_code elapsed_ms
  | Perpetual_loop.TaskClaimed { task_id; title; priority } ->
    eprintf "[auto-claim] Claimed [P%d] %s: %s\n%!" priority task_id title
  | Perpetual_loop.TaskCompleted { task_id } ->
    eprintf "[auto-claim] Completed: %s\n%!" task_id
  | Perpetual_loop.ClaimSkipped reason ->
    eprintf "[auto-claim] Skipped: %s\n%!" reason

(* ================================================================ *)
(* CLI Argument Parsing (simple, no cmdliner dependency)            *)
(* ================================================================ *)

type cli_args = {
  goal : string;
  model_strs : string list;
  verify : bool;
  verifier_str : string option;
  heartbeat : float;
  max_idle : int;
  max_context : int option;
  compact_at : float;
  handoff_at : float;
  room_path : string option;
  agent_name : string;
}

let default_args = {
  goal = "";
  model_strs = [];
  verify = true;
  verifier_str = None;
  heartbeat = 30.0;
  max_idle = 5;
  max_context = None;
  compact_at = 0.5;
  handoff_at = 0.85;
  room_path = None;
  agent_name = "perpetual-cli";
}

let rec parse_args args acc =
  match args with
  | [] -> acc
  | "--goal" :: g :: rest ->
    parse_args rest { acc with goal = g }
  | "--models" :: m :: rest ->
    parse_args rest { acc with model_strs = String.split_on_char ',' m }
  | "--no-verify" :: rest ->
    parse_args rest { acc with verify = false }
  | "--verify-with" :: v :: rest ->
    parse_args rest { acc with verifier_str = Some v }
  | "--heartbeat" :: h :: rest ->
    parse_args rest { acc with heartbeat = float_of_string h }
  | "--max-idle" :: n :: rest ->
    parse_args rest { acc with max_idle = int_of_string n }
  | "--max-context" :: n :: rest ->
    parse_args rest { acc with max_context = Some (int_of_string n) }
  | "--compact-at" :: f :: rest ->
    parse_args rest { acc with compact_at = float_of_string f }
  | "--handoff-at" :: f :: rest ->
    parse_args rest { acc with handoff_at = float_of_string f }
  | "--room-path" :: p :: rest ->
    parse_args rest { acc with room_path = Some p }
  | "--agent-name" :: n :: rest ->
    parse_args rest { acc with agent_name = n }
  | "--help" :: _ ->
    eprintf "Usage: perpetual_cli --goal GOAL --models MODEL1,MODEL2 [OPTIONS]\n\n\
Options:\n\
  --goal GOAL           Goal for the agent\n\
  --models M1,M2,...    Model cascade ('default' or provider:model)\n\
  --no-verify           Disable action verification\n\
  --verify-with MODEL   Verifier model (default: provider-aware auto selection)\n\
  --heartbeat SECS      Heartbeat interval (default: 30)\n\
  --max-idle N          Max idle turns (default: 5)\n\
  --max-context N       Override max context tokens\n\
  --compact-at F        Compact threshold 0.0-1.0 (default: 0.5)\n\
  --handoff-at F        Handoff threshold 0.0-1.0 (default: 0.85)\n";
    exit 0
  | unknown :: rest ->
    eprintf "Warning: unknown argument '%s'\n%!" unknown;
    parse_args rest acc

(* ================================================================ *)
(* Main                                                             *)
(* ================================================================ *)

let () =
  let argv = Array.to_list Sys.argv |> List.tl in  (* Drop program name *)
  let args = parse_args argv default_args in

  if args.goal = "" then begin
    eprintf "Error: --goal is required\n%!";
    exit 1
  end;

  if args.model_strs = [] then begin
    eprintf "Error: --models is required\n%!";
    exit 1
  end;

  (* Parse model specs *)
  let models = List.filter_map (fun s ->
    match Llm_client.model_spec_of_string s with
    | Ok m ->
      (* Apply max_context override if specified *)
      let m = match args.max_context with
        | Some n -> { m with max_context = n }
        | None -> m
      in
      Some m
    | Error e ->
      eprintf "Bad model spec '%s': %s\n%!" s e;
      None
  ) args.model_strs in

  if models = [] then begin
    eprintf "Error: no valid models\n%!";
    exit 1
  end;

  let verifier =
    match args.verifier_str with
    | Some s -> (
        match Llm_client.model_spec_of_string s with
        | Ok m -> Some m
        | Error e ->
            eprintf "Bad verifier spec '%s': %s\n%!" s e;
            None)
    | None -> None
  in

  let room_config = match args.room_path with
    | Some path -> Some (Room.default_config path)
    | None -> None
  in

  let config = Perpetual_loop.default_config ~goal:args.goal ~models
    ?verifier () in
  let config = { config with
    feedback_enabled = args.verify;
    heartbeat_interval_s = args.heartbeat;
    max_idle_turns = args.max_idle;
    compact_threshold = args.compact_at;
    handoff_threshold = args.handoff_at;
    on_event = log_event;
    room_config;
    agent_name = args.agent_name;
  } in

  eprintf "Perpetual Agent CLI\n%!";
  eprintf "Goal: %s\n%!" args.goal;
  eprintf "Models: %s\n%!" (String.concat ", "
    (List.map (fun (m : Llm_client.model_spec) ->
      sprintf "%s:%s" (Llm_client.string_of_provider m.provider) m.model_id
    ) models));
  eprintf "Verify: %b (model: %s)\n%!" args.verify config.verifier_model.model_id;
  eprintf "Thresholds: compact=%.0f%%, handoff=%.0f%%\n%!"
    (args.compact_at *. 100.0) (args.handoff_at *. 100.0);
  eprintf "---\n%!";

  (* Run inside Eio runtime — required for Eio.Semaphore (llm_client)
     and Process_eio subprocess management *)
  Eio_main.run @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let fs = Eio.Stdenv.fs env in
  let cwd = Eio.Path.(fs / Sys.getcwd ()) in
  Process_eio.init ~cwd_default:cwd ~proc_mgr ~clock;

  let state = Perpetual_loop.create_state config in
  Perpetual_loop.run ~config ~state;

  (* Print final status *)
  let status_json = Perpetual_loop.status ~config state in
  printf "%s\n" (Yojson.Safe.pretty_to_string status_json)
