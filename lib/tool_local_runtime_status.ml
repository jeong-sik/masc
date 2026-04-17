(** Tool_local_runtime_status -- runtime pool status reporting. *)

include Tool_local_runtime_core

let runtime_snapshot_to_yojson ~include_models
    (snapshot : Local_runtime_pool.runtime_snapshot) =
  let endpoint =
    String.trim snapshot.base_url ^ Masc_network_defaults.openai_models_path
  in
  let fetched_models =
    if not include_models then []
    else
      match fetch_models_at snapshot.base_url with
      | Ok (_, models) -> models
      | Error _ -> []
  in
  let base_fields =
    match Local_runtime_pool.snapshot_to_yojson snapshot with
    | `Assoc fields -> fields
    | json -> [ ("snapshot", json) ]
  in
  `Assoc
    (base_fields
    @ [
        ("endpoint", `String endpoint);
        ("models", `List (List.map (fun model -> `String model) fetched_models));
        ("model_count", `Int (List.length fetched_models));
      ])

let runtime_status_json ?(include_models = true) () =
  let runtime_snapshots = Local_runtime_pool.snapshots () in
  let runtime_ports =
    runtime_snapshots
    |> List.filter_map (fun (runtime : Local_runtime_pool.runtime_snapshot) ->
           runtime.port)
  in
  let process_result = discover_processes () in
  let processes =
    match process_result with
    | Ok values -> values
    | Error _ -> []
  in
  let matching_processes =
    List.filter (process_matches_runtime_ports runtime_ports) processes
  in
  let runtime_json =
    runtime_snapshots
    |> List.map (runtime_snapshot_to_yojson ~include_models)
  in
  let models =
    if not include_models then []
    else
      runtime_json
      |> List.concat_map (fun json ->
             match Yojson.Safe.Util.member "models" json with
             | `List items ->
                 List.filter_map
                   (fun item -> Yojson.Safe.Util.to_string_option item)
                   items
             | _ -> [])
      |> unique_preserve_order
  in
  let configured_capacity = Local_runtime_pool.configured_capacity () in
  let allocated_slots = Local_runtime_pool.allocated_slots () in
  let healthy_runtime_count = Local_runtime_pool.healthy_runtime_count () in
  let measured_ceiling = Local_runtime_pool.measured_ceiling () in
  let parse_errors = Local_runtime_pool.parse_errors () in
  let observations =
    []
    |> (fun items ->
         if configured_capacity < 64 then
           Printf.sprintf
             "Configured local llama capacity is %d; local64 needs shard pool capacity >= 64."
             configured_capacity
           :: items
         else items)
    |> (fun items ->
         if matching_processes = [] then
           "No local llama-server process matched the configured runtime pool."
           :: items
         else items)
    |> (fun items ->
         if List.exists (fun (proc : llama_process) -> proc.slots_enabled) matching_processes then
           "Matched llama-server process has --slots enabled."
           :: items
         else items)
    |> (fun items ->
         match parse_errors with
         | [] -> items
         | errors ->
             (Printf.sprintf "Runtime pool config issues: %s"
                (String.concat "; " errors))
             :: items)
    |> List.rev
  in
  `Assoc
    [
      ("server_url", `String Env_config.Llama.server_url);
      ("endpoint",
       `String
         (Env_config.Llama.server_url
          ^ Masc_network_defaults.openai_models_path));
      ("source", `String "llama.cpp runtime");
      ("models", `List (List.map (fun model -> `String model) models));
      ("model_count", `Int (List.length models));
      ("configured_max_concurrent_models", `Int Inference_utils.max_concurrent_models);
      ("available_model_permits", `Int (Inference_utils.model_permits_available ()));
      ("model_permits_in_use", `Int (Inference_utils.model_permits_in_use  ()));
      ("target_parallelism", `Int configured_capacity);
      ("managed_gap_to_target", `Int 0);
      ("runtime_count", `Int (List.length runtime_snapshots));
      ("healthy_runtime_count", `Int healthy_runtime_count);
      ("configured_capacity", `Int configured_capacity);
      ("allocated_slots", `Int allocated_slots);
      ("measured_ceiling", int_opt_to_json measured_ceiling);
      ("process_count", `Int (List.length processes));
      ("matching_process_count", `Int (List.length matching_processes));
      ("runtime_config_errors", `List (List.map (fun item -> `String item) parse_errors));
      ("runtimes", `List runtime_json);
      ( "processes",
        `List (List.map process_to_yojson matching_processes) );
      ("observations", `List (List.map (fun item -> `String item) observations));
    ]
