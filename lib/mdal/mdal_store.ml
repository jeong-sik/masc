open Room_utils

let loops_dir config =
  Filename.concat (masc_dir config) "mdal"

let loop_path config loop_id =
  Filename.concat (loops_dir config) (safe_filename loop_id ^ ".json")

let latest_path config =
  Filename.concat (loops_dir config) "latest.json"

let persistence_backend config =
  match config.backend with
  | Memory _ -> "memory"
  | FileSystem _ -> "filesystem"
  | PostgresNative _ -> "postgres"

let durability config =
  if String.equal (persistence_backend config) "memory" then
    "memory_only"
  else
    "persistent_backend"

let comparison_to_json (comparison : Bounded.comparison) =
  match comparison with
  | Bounded.Eq value ->
      `Assoc [ ("kind", `String "eq"); ("value", value) ]
  | Bounded.Neq value ->
      `Assoc [ ("kind", `String "neq"); ("value", value) ]
  | Bounded.Lt value ->
      `Assoc [ ("kind", `String "lt"); ("value", `Float value) ]
  | Bounded.Lte value ->
      `Assoc [ ("kind", `String "lte"); ("value", `Float value) ]
  | Bounded.Gt value ->
      `Assoc [ ("kind", `String "gt"); ("value", `Float value) ]
  | Bounded.Gte value ->
      `Assoc [ ("kind", `String "gte"); ("value", `Float value) ]
  | Bounded.Between (low, high) ->
      `Assoc [ ("kind", `String "between"); ("low", `Float low); ("high", `Float high) ]
  | Bounded.In values ->
      `Assoc [ ("kind", `String "in"); ("values", `List values) ]

let comparison_of_json json =
  let open Yojson.Safe.Util in
  match json |> member "kind" |> to_string_option with
  | Some "eq" -> Ok (Bounded.Eq (json |> member "value"))
  | Some "neq" -> Ok (Bounded.Neq (json |> member "value"))
  | Some "lt" -> Ok (Bounded.Lt (json |> member "value" |> to_float))
  | Some "lte" -> Ok (Bounded.Lte (json |> member "value" |> to_float))
  | Some "gt" -> Ok (Bounded.Gt (json |> member "value" |> to_float))
  | Some "gte" -> Ok (Bounded.Gte (json |> member "value" |> to_float))
  | Some "between" ->
      Ok
        (Bounded.Between
           (json |> member "low" |> to_float, json |> member "high" |> to_float))
  | Some "in" -> Ok (Bounded.In (json |> member "values" |> to_list))
  | Some kind -> Error (Printf.sprintf "unknown MDAL comparison kind: %s" kind)
  | None -> Error "missing MDAL comparison kind"

let goal_to_json (goal : Bounded.goal) =
  `Assoc
    [
      ("path", `String goal.path);
      ("condition", comparison_to_json goal.condition);
    ]

let goal_of_json json =
  let open Yojson.Safe.Util in
  match comparison_of_json (json |> member "condition") with
  | Error _ as e -> e
  | Ok condition ->
      Ok
        {
          Bounded.path = json |> member "path" |> to_string;
          condition;
        }

let profile_to_json (profile : Mdal.profile) =
  `Assoc
    [
      ("name", `String profile.name);
      ("metric_fn", `String profile.metric_fn);
      ("goal", goal_to_json profile.goal);
      ("target", `String profile.target);
      ("reference", Json_util.string_opt_to_json profile.reference);
      ("agent", `String profile.agent);
      ("max_iterations", `Int profile.max_iterations);
      ("max_time_seconds", Json_util.float_opt_to_json profile.max_time_seconds);
      ("stagnation_threshold", `Float profile.stagnation_threshold);
      ("stagnation_count", `Int profile.stagnation_count);
      ("heuristics", `String profile.heuristics);
      ("tools_allow", `List (List.map (fun item -> `String item) profile.tools_allow));
      ("tools_deny", `List (List.map (fun item -> `String item) profile.tools_deny));
    ]

let profile_of_json json =
  let open Yojson.Safe.Util in
  match goal_of_json (json |> member "goal") with
  | Error _ as e -> e
  | Ok goal ->
      Ok
        {
          Mdal.name = json |> member "name" |> to_string;
          metric_fn = json |> member "metric_fn" |> to_string;
          goal;
          target = json |> member "target" |> to_string;
          reference = json |> member "reference" |> to_string_option;
          agent = json |> member "agent" |> to_string;
          max_iterations = json |> member "max_iterations" |> to_int;
          max_time_seconds = json |> member "max_time_seconds" |> to_number_option;
          stagnation_threshold = json |> member "stagnation_threshold" |> to_float;
          stagnation_count = json |> member "stagnation_count" |> to_int;
          heuristics = json |> member "heuristics" |> to_string;
          tools_allow = json |> member "tools_allow" |> to_list |> List.map to_string;
          tools_deny = json |> member "tools_deny" |> to_list |> List.map to_string;
        }

let iteration_to_json (record : Mdal.iteration_record) =
  let evidence_json =
    match record.evidence with
    | None -> `Null
    | Some evidence ->
        `Assoc
          [
            ("engine", `String (Mdal.worker_engine_to_string evidence.engine));
            ("model_used", `String evidence.model_used);
            ("tool_call_count", `Int evidence.tool_call_count);
            ("tool_names", `List (List.map (fun item -> `String item) evidence.tool_names));
            ("session_id", `String evidence.session_id);
            ("status", `String (Mdal.evidence_status_to_string evidence.status));
          ]
  in
  `Assoc
    [
      ("iteration", `Int record.iteration);
      ("metric_before", `Float record.metric_before);
      ("metric_after", `Float record.metric_after);
      ("delta", `Float record.delta);
      ("changes", `String record.changes);
      ("failed_attempts", `String record.failed_attempts);
      ("next_suggestion", `String record.next_suggestion);
      ("elapsed_ms", `Int record.elapsed_ms);
      ("cost_usd", Json_util.float_opt_to_json record.cost_usd);
      ("evidence", evidence_json);
    ]

let iteration_of_json json =
  let open Yojson.Safe.Util in
  let evidence =
    let evidence_json = json |> member "evidence" in
    match evidence_json with
    | `Null -> None
    | _ -> (
        match
          Mdal.worker_engine_of_string (evidence_json |> member "engine" |> to_string),
          Mdal.evidence_status_of_string (evidence_json |> member "status" |> to_string)
        with
        | Some engine, Some status ->
            Some
              {
                Mdal.engine;
                model_used = evidence_json |> member "model_used" |> to_string;
                tool_call_count = evidence_json |> member "tool_call_count" |> to_int;
                tool_names =
                  evidence_json |> member "tool_names" |> to_list |> List.map to_string;
                session_id = evidence_json |> member "session_id" |> to_string;
                status;
              }
        | _ -> None)
  in
  {
    Mdal.iteration = json |> member "iteration" |> to_int;
    metric_before = json |> member "metric_before" |> to_float;
    metric_after = json |> member "metric_after" |> to_float;
    delta = json |> member "delta" |> to_float;
    changes = json |> member "changes" |> to_string;
    failed_attempts = json |> member "failed_attempts" |> to_string;
    next_suggestion = json |> member "next_suggestion" |> to_string;
    elapsed_ms = json |> member "elapsed_ms" |> to_int;
    cost_usd = json |> member "cost_usd" |> to_float_option;
    evidence;
  }

let loop_to_json (state : Mdal.loop_state) =
  `Assoc
    [
      ("loop_id", `String state.loop_id);
      ("profile", profile_to_json state.profile);
      ("strict_mode", `Bool state.strict_mode);
      ("status", `String (Mdal.status_to_string state.status));
      ("error_message", Json_util.string_opt_to_json state.error_message);
      ("stop_reason", Json_util.string_opt_to_json state.stop_reason);
      ("current_iteration", `Int state.current_iteration);
      ("history", `List (List.map iteration_to_json state.history));
      ("stagnation_streak", `Int state.stagnation_streak);
      ("baseline_metric", `Float state.baseline_metric);
      ("start_time", `Float state.start_time);
      ("updated_at", `Float state.updated_at);
      ("stopped_at", Json_util.float_opt_to_json state.stopped_at);
      ("execution_mode", `String (Mdal.execution_mode_to_string state.execution_mode));
      ("worker_engine",
       Json_util.option_to_yojson
         (fun engine -> `String (Mdal.worker_engine_to_string engine))
         state.worker_engine);
      ("worker_model", Json_util.string_opt_to_json state.worker_model);
    ]

let loop_of_json json =
  let open Yojson.Safe.Util in
  match profile_of_json (json |> member "profile") with
  | Error _ as e -> e
  | Ok profile -> (
      match Mdal.status_of_string (json |> member "status" |> to_string) with
      | None -> Error "invalid MDAL status"
      | Some status -> (
          match
            Mdal.execution_mode_of_string
              (json |> member "execution_mode" |> to_string)
          with
          | None -> Error "invalid MDAL execution_mode"
          | Some execution_mode ->
              Ok
                {
                  Mdal.loop_id = json |> member "loop_id" |> to_string;
                  profile;
                  strict_mode =
                    json |> member "strict_mode" |> to_bool_option
                    |> Option.value ~default:false;
                  status;
                  error_message = json |> member "error_message" |> to_string_option;
                  stop_reason = json |> member "stop_reason" |> to_string_option;
                  current_iteration = json |> member "current_iteration" |> to_int;
                  history =
                    json |> member "history" |> to_list |> List.map iteration_of_json;
                  stagnation_streak = json |> member "stagnation_streak" |> to_int;
                  baseline_metric = json |> member "baseline_metric" |> to_float;
                  start_time = json |> member "start_time" |> to_float;
                  updated_at = json |> member "updated_at" |> to_float;
                  stopped_at = json |> member "stopped_at" |> to_float_option;
                  execution_mode;
                  worker_engine =
                    (match json |> member "worker_engine" |> to_string_option with
                     | Some value -> Mdal.worker_engine_of_string value
                     | None -> None);
                  worker_model = json |> member "worker_model" |> to_string_option;
                }))

let save_loop config (state : Mdal.loop_state) =
  let path = loop_path config state.loop_id in
  with_file_lock config path (fun () -> write_json config path (loop_to_json state))

let load_loop config loop_id =
  let path = loop_path config loop_id in
  if not (path_exists config path) then
    None
  else
    with_file_lock config path (fun () ->
        match loop_of_json (read_json config path) with
        | Ok state -> Some state
        | Error _ -> None)

let save_latest_loop_id config loop_id =
  let path = latest_path config in
  with_file_lock config path (fun () ->
      write_json config path
        (`Assoc
          [
            ("loop_id", `String loop_id);
            ("updated_at", `Float (Time_compat.now ()));
          ]))

let load_latest_loop_id config =
  let path = latest_path config in
  if not (path_exists config path) then
    None
  else
    with_file_lock config path (fun () ->
        let json = read_json config path in
        Yojson.Safe.Util.(json |> member "loop_id" |> to_string_option))

let list_loop_ids config =
  let names =
    match config.backend with
    | FileSystem _ ->
        let dir = loops_dir config in
        if Sys.file_exists dir && Sys.is_directory dir then
          Sys.readdir dir |> Array.to_list
        else
          []
    | Memory _ | PostgresNative _ -> list_dir config (loops_dir config)
  in
  names
  |> List.filter (fun name ->
         Filename.check_suffix name ".json" && not (String.equal name "latest.json"))
  |> List.map (fun name ->
         match String.rindex_opt name '.' with
         | Some index -> String.sub name 0 index
         | None -> name)
  |> List.sort_uniq String.compare

let list_loops config =
  list_loop_ids config |> List.filter_map (load_loop config)

let clear_all config =
  let dir = loops_dir config in
  List.iter
    (fun loop_id -> delete_path config (loop_path config loop_id))
    (list_loop_ids config);
  if path_exists config (latest_path config) then
    delete_path config (latest_path config);
  match config.backend with
  | FileSystem _ ->
      if Sys.file_exists dir && Sys.is_directory dir then
        (try Unix.rmdir dir with Unix.Unix_error _ -> ())
  | Memory _ | PostgresNative _ -> ()
