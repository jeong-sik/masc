module Agent_swarm_live_harness = Masc_mcp.Agent_swarm_live_harness

type cli_args = {
  run_id : string;
  masc_url : string;
  provider_base_url : string;
  model_id : string;
  slot_url : string;
  worker_count : int;
  min_hot_slots : int;
  required_final_markers : int;
  max_turns : int;
  describe_only : bool;
}

let default_args =
  {
    run_id = "swarm-live";
    masc_url = "http://127.0.0.1:8935";
    provider_base_url = "http://127.0.0.1:3034";
    model_id = "qwen3.5-35b-a3b-ud-q8-xl";
    slot_url = "http://127.0.0.1:8085";
    worker_count = 12;
    min_hot_slots = 10;
    required_final_markers = 12;
    max_turns = 8;
    describe_only = false;
  }

let rec parse_args args acc =
  match args with
  | [] -> acc
  | "--run-id" :: value :: rest ->
      parse_args rest { acc with run_id = value }
  | "--masc-url" :: value :: rest ->
      parse_args rest { acc with masc_url = value }
  | "--provider-base-url" :: value :: rest ->
      parse_args rest { acc with provider_base_url = value }
  | "--model-id" :: value :: rest ->
      parse_args rest { acc with model_id = value }
  | "--slot-url" :: value :: rest ->
      parse_args rest { acc with slot_url = value }
  | "--worker-count" :: value :: rest -> (
      match int_of_string_opt value with
      | Some worker_count when worker_count > 0 ->
          parse_args rest { acc with worker_count; required_final_markers = worker_count }
      | _ ->
          failwith (Printf.sprintf "invalid --worker-count: %s" value))
  | "--min-hot-slots" :: value :: rest -> (
      match int_of_string_opt value with
      | Some min_hot_slots when min_hot_slots > 0 ->
          parse_args rest { acc with min_hot_slots }
      | _ ->
          failwith (Printf.sprintf "invalid --min-hot-slots: %s" value))
  | "--required-final-markers" :: value :: rest -> (
      match int_of_string_opt value with
      | Some required_final_markers when required_final_markers >= 0 ->
          parse_args rest { acc with required_final_markers }
      | _ ->
          failwith (Printf.sprintf "invalid --required-final-markers: %s" value))
  | "--max-turns" :: value :: rest -> (
      match int_of_string_opt value with
      | Some max_turns when max_turns > 0 ->
          parse_args rest { acc with max_turns }
      | _ ->
          failwith (Printf.sprintf "invalid --max-turns: %s" value))
  | "--describe" :: rest ->
      parse_args rest { acc with describe_only = true }
  | "--help" :: _ ->
      Printf.eprintf
        "Usage: agent_swarm_harness_cli [--run-id ID] [--masc-url URL] [--provider-base-url URL] [--model-id MODEL] [--slot-url URL] [--worker-count N] [--min-hot-slots N] [--required-final-markers N] [--max-turns N] [--describe]\n";
      exit 0
  | unknown :: _ ->
      failwith (Printf.sprintf "unknown argument: %s" unknown)

let config_of_args args : Agent_swarm_live_harness.config =
  {
    run_id = args.run_id;
    masc_url = args.masc_url;
    provider_base_url = args.provider_base_url;
    model_id = args.model_id;
    slot_url = args.slot_url;
    worker_count = args.worker_count;
    min_hot_slots = args.min_hot_slots;
    required_final_markers = args.required_final_markers;
    max_turns = args.max_turns;
  }

let () =
  let args = parse_args (Array.to_list Sys.argv |> List.tl) default_args in
  let config = config_of_args args in
  if args.describe_only then
    Agent_swarm_live_harness.manifest_json config
    |> Yojson.Safe.pretty_to_string
    |> print_endline
  else
    Eio_main.run @@ fun env ->
    let net = Eio.Stdenv.net env in
    let clock = Eio.Stdenv.clock env in
    Eio.Switch.run @@ fun sw ->
    Agent_swarm_live_harness.run ~sw ~net ~clock config
    |> Yojson.Safe.pretty_to_string
    |> print_endline
