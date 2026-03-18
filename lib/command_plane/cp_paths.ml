include Cp_types

let control_plane_dir config =
  Filename.concat (Room.masc_dir config) "control-plane"

let control_plane_root_dir config =
  Filename.concat (Room_utils.masc_root_dir config) "control-plane"

let legacy_control_plane_root_dir config =
  Filename.concat (Filename.concat config.Room.base_path ".masc") "control-plane"

let units_path config =
  Filename.concat (control_plane_dir config) "units.json"

let operations_path config =
  Filename.concat (control_plane_dir config) "operations.json"

let intents_path config =
  Filename.concat (control_plane_dir config) "intents.json"

let events_path config =
  Filename.concat (control_plane_dir config) "events.jsonl"

let detachments_path config =
  Filename.concat (control_plane_dir config) "detachments.json"

let decisions_path config =
  Filename.concat (control_plane_dir config) "decisions.json"

let traces_dir config =
  Filename.concat (control_plane_dir config) "traces"

let operator_dir config =
  Filename.concat (Room.masc_dir config) "operator"

let operator_pending_confirms_path config =
  Filename.concat (operator_dir config) "pending_confirms.json"

let operator_action_log_path config =
  Filename.concat (operator_dir config) "action_log.jsonl"

let swarm_path config =
  Filename.concat config.Room.base_path ".masc/swarm.json"

let swarm_live_dirs config =
  List.sort_uniq String.compare
    [
      Filename.concat (control_plane_root_dir config) "swarm-live";
      Filename.concat (legacy_control_plane_root_dir config) "swarm-live";
    ]

let swarm_live_run_dirs config run_id =
  let normalized =
    let filename = Room_utils.safe_filename run_id in
    let lowered =
      String.lowercase_ascii filename
      |> String.map (fun c -> if c = '.' then '-' else c)
    in
    let rec collapse_dash acc = function
      | [] -> acc
      | '-' :: '-' :: rest -> collapse_dash acc ('-' :: rest)
      | ch :: rest -> collapse_dash (ch :: acc) rest
    in
    let collapsed =
      lowered |> String.to_seq |> List.of_seq |> collapse_dash [] |> List.rev
      |> List.to_seq |> String.of_seq
    in
    let value = String.trim collapsed in
    if value = "" then "auto" else value
  in
  swarm_live_dirs config
  |> List.concat_map (fun dir ->
         [ Filename.concat dir normalized; Filename.concat dir run_id ])
  |> List.sort_uniq String.compare

let primary_swarm_live_run_dir config run_id =
  Filename.concat
    (Filename.concat (control_plane_root_dir config) "swarm-live")
    (Room_utils.safe_filename run_id)

let find_swarm_live_artifact_path config run_id filename =
  swarm_live_run_dirs config run_id
  |> List.find_map (fun dir ->
         let path = Filename.concat dir filename in
         if Sys.file_exists path || Room_utils.path_exists config path then Some path else None)

let swarm_live_resolution_path config run_id =
  Filename.concat (primary_swarm_live_run_dir config run_id) "resolution.json"

let find_swarm_live_artifact_json config run_id filename =
  match find_swarm_live_artifact_path config run_id filename with
  | Some path when Sys.file_exists path -> Some (Room_utils.read_json_local path)
  | Some path -> Room_utils.read_json_opt config path
  | None -> None

let search_stats_path config =
  Filename.concat (control_plane_dir config) "search-stats.json"
