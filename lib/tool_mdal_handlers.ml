(** Tool_mdal_handlers — MDAL tool handler implementations (start, iterate, stop, swarm). *)

include Tool_mdal_schemas

let assoc_with_fields json fields =
  match json with
  | `Assoc base -> `Assoc (base @ fields)
  | other -> other

let config_persistence_backend config =
  Mdal_store.persistence_backend config

let config_durability config =
  Mdal_store.durability config

let remember_loop (state : Mdal.loop_state) =
  Hashtbl.replace active_loops state.loop_id state;
  latest_loop_id := Some state.loop_id

let persist_loop config (state : Mdal.loop_state) =
  state.updated_at <- Time_compat.now ();
  Mdal_store.save_loop config state;
  Mdal_store.save_latest_loop_id config state.loop_id;
  remember_loop state

let resolve_loop_id (ctx : context) args =
  let open Yojson.Safe.Util in
  match args |> member "loop_id" |> to_string_option with
  | Some id -> Some id
  | None -> (
      match !latest_loop_id with
      | Some id -> Some id
      | None -> (
          match ctx.config with
          | Some config -> Mdal_store.load_latest_loop_id config
          | None -> None))

let iter_record_to_json (r : Mdal.iteration_record) : Yojson.Safe.t =
  let evidence_json =
    match r.evidence with
    | None -> `Null
    | Some evidence ->
        `Assoc
          [
            ("worker_engine", `String (Mdal.worker_engine_to_string evidence.engine));
            ("worker_model", `String evidence.model_used);
            ("tool_call_count", `Int evidence.tool_call_count);
            ("tool_names", `List (List.map (fun item -> `String item) evidence.tool_names));
            ("session_id", `String evidence.session_id);
            ("evidence_status", `String (Mdal.evidence_status_to_string evidence.status));
          ]
  in
  `Assoc [
    ("iteration", `Int r.iteration);
    ("metric_before", `Float r.metric_before);
    ("metric_after", `Float r.metric_after);
    ("delta", `Float r.delta);
    ("changes", `String r.changes);
    ("failed_attempts", `String r.failed_attempts);
    ("next_suggestion", `String r.next_suggestion);
    ("elapsed_ms", `Int r.elapsed_ms);
    ("cost_usd", Json_util.float_opt_to_json r.cost_usd);
    ("evidence", evidence_json);
  ]

let runtime_worker_available (ctx : context) =
  match ctx.worker_runner with
  | Some _ -> true
  | None -> Mdal_worker.runtime_available ~sw:ctx.sw ~config:ctx.config

let truncate_preview ?(limit = 240) text =
  let trimmed = String.trim text in
  if String.length trimmed <= limit then
    trimmed
  else
    String.sub trimmed 0 limit ^ "..."

let missing_metric_message profile_name =
  let profile_hint =
    match profile_name with
    | "ssim" ->
        "Example: a script that compares a reference image and prints SSIM as a single float."
    | "coverage" ->
        "Example: a coverage command that prints one numeric percentage such as `make coverage-summary | ...`."
    | "lint" ->
        "Example: a lint command that prints one numeric error count."
    | "review" ->
        "Provide a deterministic review scoring command or evaluator that prints a single float."
    | "docs" ->
        "Provide a deterministic documentation coverage command or evaluator that prints a single float."
    | other ->
        Printf.sprintf "Provide metric_fn explicitly for profile `%s`." other
  in
  Printf.sprintf
    "Profile `%s` has no trustworthy built-in metric command in this workspace. Pass `metric_fn` explicitly. %s"
    profile_name profile_hint

let resolve_metric_fn ~profile_name ~base_profile args =
  let open Yojson.Safe.Util in
  match args |> member "metric_fn" |> to_string_option |> Option.map String.trim with
  | Some metric_fn when metric_fn <> "" -> Ok metric_fn
  | _ ->
      let inherited = String.trim base_profile.Mdal.metric_fn in
      if inherited <> "" then Ok inherited
      else Error (missing_metric_message profile_name)

let resolve_worker_model_arg args =
  match args |> Yojson.Safe.Util.member "worker_model"
        |> Yojson.Safe.Util.to_string_option with
  | Some value ->
      let trimmed = String.trim value in
      if trimmed = "" then None else Some trimmed
  | None -> None

let validate_strict_iterate_args args =
  let open Yojson.Safe.Util in
  let manual_fields =
    [ "changes"; "failed_attempts"; "next_suggestion" ]
    |> List.filter (fun field ->
           match args |> member field with
           | `Null -> false
           | _ -> true)
  in
  match manual_fields with
  | [] -> Ok ()
  | fields ->
      Error
        (Printf.sprintf
           "Strict MDAL does not accept manual iteration fields (%s). Start a new strict loop and let the worker produce auditable tool evidence."
           (String.concat ", " fields))

let current_metric_of_state (state : Mdal.loop_state) =
  Mdal.current_metric state

let total_delta_of_state (state : Mdal.loop_state) =
  Mdal.total_delta state

let hydrate_loaded_loop config (state : Mdal.loop_state) =
  match state.status with
  | `Running ->
      state.status <- `Interrupted;
      state.stop_reason <- Some "server_restart";
      state.error_message <- None;
      state.stopped_at <- None;
      persist_loop config state;
      state
  | _ ->
      remember_loop state;
      state

let find_loop ?config loop_id =
  match Hashtbl.find_opt active_loops loop_id with
  | Some state -> Some state
  | None -> (
      match config with
      | Some cfg -> (
          match Mdal_store.load_loop cfg loop_id with
          | Some state -> Some (hydrate_loaded_loop cfg state)
          | None -> None)
      | None -> None)

let list_loops ?config () =
  match config with
  | None ->
      Hashtbl.fold (fun _ state acc -> state :: acc) active_loops []
  | Some cfg ->
      let ids =
        Mdal_store.list_loop_ids cfg
        @ Hashtbl.fold (fun id _ acc -> id :: acc) active_loops []
        |> List.sort_uniq String.compare
      in
      List.filter_map (find_loop ~config:cfg) ids

let state_to_json ?config (state : Mdal.loop_state) =
  let persistence_backend, durability =
    match config with
    | Some cfg -> (config_persistence_backend cfg, config_durability cfg)
    | None -> ("memory", "memory_only")
  in
  let latest_evidence = Mdal.latest_evidence state in
  let latest_tool_call_count, latest_tool_names, latest_session_id, evidence_status =
    match latest_evidence with
    | Some evidence ->
        ( evidence.tool_call_count,
          evidence.tool_names,
          Some evidence.session_id,
          Some evidence.status )
    | None ->
        ( 0,
          [],
          None,
          Mdal.current_evidence_status state )
  in
  let stopped_at = Json_util.float_opt_to_json state.stopped_at in
  `Assoc
    [
      ("loop_id", `String state.loop_id);
      ("status", `String (Mdal.status_to_string state.status));
      ("strict_mode", `Bool state.strict_mode);
      ("error_message", Json_util.string_opt_to_json state.error_message);
      ("error_reason", Json_util.string_opt_to_json state.error_message);
      ("stop_reason", Json_util.string_opt_to_json state.stop_reason);
      ("profile", `String state.profile.name);
      ("current_iteration", `Int state.current_iteration);
      ("max_iterations", `Int state.profile.max_iterations);
      ("baseline_metric", `Float state.baseline_metric);
      ("current_metric", `Float (current_metric_of_state state));
      ("target", `String state.profile.target);
      ("stagnation_streak", `Int state.stagnation_streak);
      ("stagnation_limit", `Int state.profile.stagnation_count);
      ("elapsed_seconds", `Float (Time_compat.now () -. state.start_time));
      ("start_time", `Float state.start_time);
      ("updated_at", `Float state.updated_at);
      ("stopped_at", stopped_at);
      ("execution_mode", `String (Mdal.execution_mode_to_string state.execution_mode));
      ("worker_engine",
       Json_util.option_to_yojson
         (fun engine -> `String (Mdal.worker_engine_to_string engine))
         state.worker_engine);
      ("worker_model", Json_util.string_opt_to_json state.worker_model);
      ("evidence_policy", if state.strict_mode then `String "hard" else `String "legacy");
      ("latest_tool_call_count", `Int latest_tool_call_count);
      ("latest_tool_names", `List (List.map (fun item -> `String item) latest_tool_names));
      ("session_id", Json_util.string_opt_to_json latest_session_id);
      ("evidence_status",
       Json_util.option_to_yojson
         (fun status -> `String (Mdal.evidence_status_to_string status))
         evidence_status);
      ("durability", `String durability);
      ("persistence_backend", `String persistence_backend);
      ("recoverable", `Bool (Mdal.recoverable state));
      ("history", `List (List.map iter_record_to_json state.history));
    ]

let post_final_summary (state : Mdal.loop_state) =
  try
    ignore
      (Board_dispatch.create_post
         ~author:"mdal"
         ~content:(Mdal.format_final_post state)
         ~post_kind:Board.System_post
         ~meta_json:(`Assoc [ ("source", `String "mdal_final") ])
         ~visibility:Board.Internal
         ~ttl_hours:24
         ~hearth:(Mdal.state_hearth state.loop_id)
         ())
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Log.Misc.warn "tool_mdal: final board post failed: %s" (Printexc.to_string exn)

let terminal_response ?config (state : Mdal.loop_state) ~reason ~error_message =
  assoc_with_fields (state_to_json ?config state)
    [
      ("error", `String error_message);
      ("reason", `String reason);
      ("total_iterations", `Int state.current_iteration);
      ("final_metric", `Float (current_metric_of_state state));
      ("total_delta", `Float (total_delta_of_state state));
      ("final_state", `String (Mdal.format_final_post state));
    ]

let emit_stop_event (state : Mdal.loop_state) ~reason =
  let final_metric = current_metric_of_state state in
  try
    Sse.broadcast
      (`Assoc
        [
          ("type", `String "mdal_stopped");
          ("loop_id", `String state.loop_id);
          ("status", `String (Mdal.status_to_string state.status));
          ("reason", `String reason);
          ("final_metric", `Float final_metric);
          ("iterations", `Int state.current_iteration);
        ])
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Log.Misc.warn "tool_mdal: emit_stop_event SSE failed: %s" (Printexc.to_string exn)

let emit_completed_event ~loop_id ~final_metric ~iterations =
  try
    Sse.broadcast
      (`Assoc
        [
          ("type", `String "mdal_completed");
          ("loop_id", `String loop_id);
          ("final_metric", `Float final_metric);
          ("iterations", `Int iterations);
        ])
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Log.Misc.warn "tool_mdal: emit_completed_event SSE failed: %s" (Printexc.to_string exn)

let run_worker_iteration (ctx : context) (config : Room.config)
    (state : Mdal.loop_state) current_metric =
  match ctx.worker_runner with
  | Some runner -> runner ~config state ~current_metric
  | None -> (
      match ctx.sw with
      | None ->
          Error
            (Mdal_worker.Worker_unavailable
               "Strict MDAL worker runtime requires an active Eio switch.")
      | Some sw -> Mdal_worker.run ~sw ~config state ~current_metric)

let require_config ctx =
  match ctx.config with
  | Some config -> Ok config
  | None -> Error "MDAL requires room config for backend-backed persistence"

let set_non_terminal_state (state : Mdal.loop_state) status =
  state.status <- status;
  state.error_message <- None;
  state.stop_reason <- None;
  state.stopped_at <- None

let set_interrupted_state (state : Mdal.loop_state) ~reason ~error_message =
  let now = Time_compat.now () in
  state.status <- `Interrupted;
  state.stop_reason <- Some reason;
  state.error_message <- error_message;
  state.updated_at <- now;
  state.stopped_at <- Some now

let set_terminal_state (state : Mdal.loop_state) ~status ~reason ~error_message =
  let now = Time_compat.now () in
  state.status <- status;
  state.stop_reason <- Some reason;
  state.error_message <- error_message;
  state.updated_at <- now;
  state.stopped_at <- Some now

let stop_for_reason config (state : Mdal.loop_state) ~reason ~message =
  set_terminal_state state ~status:`Stopped ~reason ~error_message:None;
  persist_loop config state;
  post_final_summary state;
  emit_stop_event state ~reason;
  terminal_response ~config state ~reason ~error_message:message

let fail_loop config (state : Mdal.loop_state) ~reason ~message =
  set_terminal_state state ~status:`Error ~reason ~error_message:(Some message);
  persist_loop config state;
  post_final_summary state;
  emit_stop_event state ~reason;
  terminal_response ~config state ~reason ~error_message:message

let interrupt_loop config (state : Mdal.loop_state) ~reason ~message =
  set_interrupted_state state ~reason ~error_message:(Some message);
  persist_loop config state;
  post_final_summary state;
  emit_stop_event state ~reason;
  terminal_response ~config state ~reason ~error_message:message

let reject_iteration ?config (state : Mdal.loop_state) ~message =
  assoc_with_fields (state_to_json ?config state) [ ("error", `String message) ]

(* ================================================================ *)
(* Swarm parsing helpers                                             *)
(* ================================================================ *)

let parse_aggregate_strategy s =
  match String.lowercase_ascii s with
  | "all" -> Mdal_swarm.All
  | "any" -> Mdal_swarm.Any
  | _ -> Mdal_swarm.Average

let parse_worker_spec (json : Yojson.Safe.t) : (Mdal_swarm.worker_spec, string) result =
  try
    let open Yojson.Safe.Util in
    Ok {
      worker_id = json |> member "worker_id" |> to_string;
      label = json |> member "label" |> to_string_option |> Option.value ~default:"";
      metric_fn = json |> member "metric_fn" |> to_string;
      goal_expr = json |> member "goal_expr" |> to_string;
      agent = json |> member "agent" |> to_string_option |> Option.value ~default:"default";
      max_iterations = json |> member "max_iterations" |> to_int_option |> Option.value ~default:10;
    }
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Error (Printf.sprintf "Invalid worker spec: %s" (Printexc.to_string exn))

let parse_all_workers workers_json =
  let rec aux acc = function
    | [] -> Ok (List.rev acc)
    | json :: rest ->
        match parse_worker_spec json with
        | Ok w -> aux (w :: acc) rest
        | Error e -> Error e
  in
  aux [] workers_json
