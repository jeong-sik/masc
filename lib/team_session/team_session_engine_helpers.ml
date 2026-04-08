(** Eio runtime engine for long-running team sessions. *)

type runtime_state = {
  mutable stop_requested : bool;
  mutable stop_reason : string option;
  mutable finalizing : bool;
  mutable generate_report_on_finalize : bool;
}

let runtimes : (string, runtime_state) Hashtbl.t = Hashtbl.create 16
let runtimes_mutex = Eio.Mutex.create ()
let finalize_mutex = Eio.Mutex.create ()

let with_runtimes_lock f = Eio.Mutex.use_rw ~protect:true runtimes_mutex f
let with_finalize_lock f = Eio.Mutex.use_rw ~protect:true finalize_mutex f

let () = Random.self_init ()

let now_iso () = Types.now_iso ()
let is_cancelled exn = match exn with Eio.Cancel.Cancelled _ -> true | _ -> false

let clamp_int ~min_v ~max_v v = max min_v (min max_v v)

let rec take n xs =
  if n <= 0 then []
  else
    match xs with
    | [] -> []
    | x :: rest -> x :: take (n - 1) rest

let take_last max_items xs =
  if max_items <= 0 then []
  else
    let len = List.length xs in
    if len <= max_items then xs
    else
      let rec drop n ys =
        if n <= 0 then ys
        else
          match ys with
          | [] -> []
          | _ :: rest -> drop (n - 1) rest
      in
      drop (len - max_items) xs

let room_active_agent_names (config : Room.config) =
  Room.get_agents_raw config
  |> List.map (fun (a : Types.agent) -> a.name)
  |> Team_session_types.dedup_strings
  |> List.sort String.compare

let session_live_turn_window_sec = Env_config.InternalTimers.session_live_turn_window_sec

let event_type_of_json json =
  match Yojson.Safe.Util.member "event_type" json with
  | `String value -> Some value
  | _ -> None

let event_detail_actor_of_json json =
  match Yojson.Safe.Util.member "detail" json |> Yojson.Safe.Util.member "actor" with
  | `String actor ->
      let trimmed = String.trim actor in
      if trimmed = "" then None else Some trimmed
  | _ -> None

let event_detail_string key json =
  match Yojson.Safe.Util.member "detail" json |> Yojson.Safe.Util.member key with
  | `String value ->
      let trimmed = String.trim value in
      if trimmed = "" then None else Some trimmed
  | _ -> None

let event_detail_worker_actor_of_json json =
  match event_detail_string "runtime_actor" json with
  | Some _ as actor -> actor
  | None -> event_detail_string "target_agent" json

type worker_run_event_snapshot = {
  requested_ids : string list;
  completed_success_count : int;
  completed_failed_count : int;
  in_flight_ids : string list;
  in_flight_actors : string list;
}

let worker_run_event_snapshot ?events (config : Room.config)
    (session : Team_session_types.session) =
  let requested = Hashtbl.create 16 in
  let completed = Hashtbl.create 16 in
  let events =
    match events with
    | Some rows -> rows
    | None -> Team_session_store.read_events ~max_events:2000 config session.session_id
  in
  List.iter
    (fun json ->
      match event_type_of_json json with
      | Some ("team_step_spawn_requested" | "team_step_delegate_requested") -> (
          match event_detail_string "worker_run_id" json with
          | Some worker_run_id ->
              Hashtbl.replace requested worker_run_id
                (event_detail_worker_actor_of_json json)
          | None -> ())
      | Some ("team_step_spawn" | "team_step_delegate") -> (
          match event_detail_string "worker_run_id" json with
          | Some worker_run_id -> (
              match Yojson.Safe.Util.member "detail" json |> Yojson.Safe.Util.member "success" with
              | `Bool success -> Hashtbl.replace completed worker_run_id success
              | _ -> ())
          | None -> ())
      | _ -> ())
    events;
  let requested_ids =
    Hashtbl.to_seq_keys requested |> List.of_seq |> Team_session_types.dedup_strings
  in
  let completed_success_count, completed_failed_count, completed_ids =
    Hashtbl.fold
      (fun worker_run_id success (ok_count, fail_count, ids) ->
        if success then
          (ok_count + 1, fail_count, worker_run_id :: ids)
        else
          (ok_count, fail_count + 1, worker_run_id :: ids))
      completed (0, 0, [])
  in
  let in_flight_ids =
    requested_ids
    |> List.filter (fun worker_run_id ->
           not (List.mem worker_run_id completed_ids))
  in
  let in_flight_actors =
    in_flight_ids
    |> List.filter_map (fun worker_run_id ->
           Hashtbl.find_opt requested worker_run_id |> Option.join)
    |> Team_session_types.dedup_strings |> List.sort String.compare
  in
  {
    requested_ids;
    completed_success_count;
    completed_failed_count;
    in_flight_ids;
    in_flight_actors;
  }

let event_ts_of_json json =
  match Yojson.Safe.Util.member "ts" json with
  | `Float value -> Some value
  | `Int value -> Some (float_of_int value)
  | `Intlit raw -> float_of_string_opt raw
  | _ -> (
      match Yojson.Safe.Util.member "ts_iso" json with
      | `String iso -> Resilience.Time.parse_iso8601_opt iso
      | _ -> None)

let bootstrap_present_agent_names (config : Room.config)
    (session : Team_session_types.session) ~now =
  let bootstrap_grace =
    float_of_int (session.checkpoint_interval_sec * max 1 session.min_agents)
  in
  if now -. session.started_at >= bootstrap_grace then
    []
  else
    let room_active = room_active_agent_names config in
    Team_session_types.planned_participant_names session
    |> List.filter (fun agent -> List.mem agent room_active)
    |> Team_session_types.dedup_strings
    |> List.sort String.compare

let session_seen_and_live_agent_names ?events (config : Room.config)
    (session : Team_session_types.session) ~now =
  let events =
    match events with
    | Some rows -> rows
    | None -> Team_session_store.read_events ~max_events:2000 config session.session_id
  in
  let seen_agents, live_agents =
    List.fold_left
      (fun (seen_acc, live_acc) json ->
        match (event_type_of_json json, event_detail_actor_of_json json) with
        | Some "team_turn", Some actor -> (
            let seen_acc = actor :: seen_acc in
            match event_ts_of_json json with
            | Some ts when now -. ts <= session_live_turn_window_sec ->
                (seen_acc, actor :: live_acc)
            | _ -> (seen_acc, live_acc))
        | _ -> (seen_acc, live_acc))
      ([], []) events
  in
  let bootstrap_agents = bootstrap_present_agent_names config session ~now in
  let worker_runs = worker_run_event_snapshot ~events config session in
  ( (seen_agents @ bootstrap_agents)
    |> Team_session_types.dedup_strings
    |> List.sort String.compare,
    (live_agents @ bootstrap_agents @ worker_runs.in_flight_actors)
    |> Team_session_types.dedup_strings
    |> List.sort String.compare )

let session_active_agent_names ?events config session ~now =
  session_seen_and_live_agent_names ?events config session ~now |> snd

let bootstrap_grace_seconds (session : Team_session_types.session) =
  float_of_int (session.checkpoint_interval_sec * max 1 session.min_agents)

let session_visible_to_agent ~(agent_name : string)
    (session : Team_session_types.session) =
  String.equal agent_name session.created_by
  || List.exists (String.equal agent_name) session.agent_names

let session_allows_actor ~(actor : string) (session : Team_session_types.session) =
  String.equal actor session.created_by
  || List.exists (String.equal actor) session.agent_names

let increment_broadcast_from_external (config : Room.config) ~(agent_name : string) =
  (* Use update_session for atomic read-modify-write per session to avoid
     TOCTOU races with concurrent writers (session engine loop, other
     broadcasts).  Session counts are typically 0-2 active so the directory
     scan is cheap on the broadcast hot path. *)
  let root =
    Filename.concat (Room_utils.masc_dir config) "team-sessions"
  in
  if Sys.file_exists root then
    Sys.readdir root
    |> Array.iter (fun session_id ->
           ignore
             (Team_session_store.update_session config session_id
                (fun (session : Team_session_types.session) ->
                  match session.status with
                  | Team_session_types.Running
                    when session_allows_actor ~actor:agent_name session ->
                      { session with
                        broadcast_count = session.broadcast_count + 1
                      }
                  | _ -> session)))

let hierarchy_lane_ids = [| "lane-a"; "lane-b"; "lane-c"; "lane-d" |]

let controller_tree_json_of_session (session : Team_session_types.session) =
  match session.control_profile with
  | Team_session_types.Control_flat ->
      `Assoc
        [
          ("profile", `String "flat");
          ("root", `String "ctrl-root");
          ("lanes", `List []);
        ]
  | Team_session_types.Control_hierarchical_quality_v1 ->
      let lanes =
        Array.to_list hierarchy_lane_ids
        |> List.map (fun lane_id ->
               `Assoc
                 [
                   ("lane_id", `String lane_id);
                   ("lane_manager", `String (Printf.sprintf "ctrl-%s" lane_id));
                   ( "quality_manager",
                     `String (Printf.sprintf "ctrl-%s-quality" lane_id) );
                   ( "knowledge_manager",
                     `String (Printf.sprintf "ctrl-%s-knowledge" lane_id) );
                 ])
      in
      `Assoc
        [
          ("profile", `String "hierarchical_quality_v1");
          ("root", `String "ctrl-root");
          ("global_metacog", `String "ctrl-global-metacog");
          ("runtime_warden", `String "ctrl-runtime-warden");
          ("lanes", `List lanes);
        ]

let controller_intervention_counts ?events (config : Room.config) session_id =
  let counts = Hashtbl.create 8 in
  (match events with
  | Some rows -> rows
  | None -> Team_session_store.read_events ~max_events:2000 config session_id)
  |> List.iter (fun json ->
         match Yojson.Safe.Util.member "event_type" json with
         | `String
             ("controller_intervention" | "controller_escalation"
             | "controller_reroute" | "controller_capsule"
             | "controller_handoff" as kind) ->
             let prev = Option.value ~default:0 (Hashtbl.find_opt counts kind) in
             Hashtbl.replace counts kind (prev + 1)
         | _ -> ());
  Hashtbl.fold (fun key value acc -> (key, value) :: acc) counts []
  |> Team_session_types.counts_to_json

let confidence_heatmap_json (session : Team_session_types.session) =
  let fold_lane acc (worker : Team_session_types.planned_worker) =
    match (worker.lane_id, worker.routing_confidence) with
    | Some lane, Some confidence ->
        let total, count =
          match List.assoc_opt lane acc with
          | Some pair -> pair
          | None -> (0.0, 0)
        in
        (lane, (total +. confidence, count + 1))
        :: List.remove_assoc lane acc
    | _ -> acc
  in
  session.planned_workers
  |> List.fold_left fold_lane []
  |> List.map (fun (lane, (total, count)) ->
         let avg = if count = 0 then 0.0 else total /. float_of_int count in
         (lane, `Float avg))
  |> List.sort (fun (a, _) (b, _) -> String.compare a b)
  |> fun fields -> `Assoc fields

let context_pressure_by_lane_json (session : Team_session_types.session) =
  let update lane delta acc =
    let prev = Option.value ~default:0.0 (List.assoc_opt lane acc) in
    (lane, min 1.0 (prev +. delta)) :: List.remove_assoc lane acc
  in
  session.planned_workers
  |> List.fold_left
       (fun acc (worker : Team_session_types.planned_worker) ->
         match worker.lane_id with
         | None -> acc
         | Some lane ->
             let acc =
               if worker.routing_escalated then update lane 0.15 acc else acc
             in
             if Option.is_none worker.runtime_actor then update lane 0.10 acc
             else acc)
       []
  |> List.map (fun (lane, pressure) -> (lane, `Float pressure))
  |> List.sort (fun (a, _) (b, _) -> String.compare a b)
  |> fun fields -> `Assoc fields

let lane_health_json ?events (config : Room.config) (session : Team_session_types.session) =
  let events =
    match events with
    | Some rows -> rows
    | None -> Team_session_store.read_events ~max_events:2000 config session.session_id
  in
  let failed_runtime_actors =
    events
    |> List.filter_map (fun json ->
           match Yojson.Safe.Util.member "event_type" json with
           | `String "team_step_spawn" -> (
               match
                 ( Yojson.Safe.Util.member "detail" json
                   |> Yojson.Safe.Util.member "success",
                   Yojson.Safe.Util.member "detail" json
                   |> Yojson.Safe.Util.member "runtime_actor" )
               with
               | `Bool false, `String actor -> Some actor
               | _ -> None)
           | `String "session_agent_detached" -> (
               match Yojson.Safe.Util.member "detail" json |> Yojson.Safe.Util.member "actor" with
               | `String actor -> Some actor
               | _ -> None)
           | _ -> None)
  in
  let workers_by_lane =
    session.planned_workers
    |> List.fold_left
         (fun acc (worker : Team_session_types.planned_worker) ->
           match worker.lane_id with
           | Some lane ->
               let existing = Option.value ~default:[] (List.assoc_opt lane acc) in
               (lane, worker :: existing) :: List.remove_assoc lane acc
           | None -> acc)
         []
  in
  workers_by_lane
  |> List.map (fun (lane, workers) ->
         let degraded =
           List.exists
             (fun (worker : Team_session_types.planned_worker) ->
               match worker.runtime_actor with
               | Some actor -> List.mem actor failed_runtime_actors
               | None -> false)
             workers
         in
         let status =
           if degraded then "degraded"
           else if
             List.exists
               (fun (worker : Team_session_types.planned_worker) ->
                 worker.routing_escalated)
               workers
           then "warn"
           else "ok"
         in
         ( lane,
           `Assoc
             [
               ("status", `String status);
               ("worker_count", `Int (List.length workers));
             ] ))
  |> List.sort (fun (a, _) (b, _) -> String.compare a b)
  |> fun fields -> `Assoc fields

let session_has_attached_actor ~(config : Room.config) ~(session_id : string)
    ~(actor : string) =
  let open Yojson.Safe.Util in
  Team_session_store.read_events config session_id
  |> List.exists (fun event_json ->
         match event_json |> member "event_type" with
         | `String "session_agent_attached" -> (
             match event_json |> member "detail" |> member "actor" with
             | `String attached -> String.equal attached actor
             | _ -> false)
         | _ -> false)

let validate_operation_attachment ~(config : Room.config) ~(operation_id : string)
    : (unit, string) result =
  let open Yojson.Safe.Util in
  let operations_json = Command_plane_v2.list_operations_json ~operation_id config in
  match operations_json |> member "operations" with
  | `List [] ->
      Error (Printf.sprintf "operation not found: %s" operation_id)
  | `List ((`Assoc _ as row) :: _) -> (
      match
        row |> member "operation" |> member "detachment_session_id"
        |> to_string_option
      with
      | Some session_id when String.trim session_id <> "" ->
          (match Team_session_store.load_session config session_id with
          | Some session when session.status = Team_session_types.Running ->
              Error
                (Printf.sprintf
                   "operation already attached to team session: %s"
                   session_id)
          | _ -> Ok ())
      | _ -> Ok ())
  | _ ->
      Error
        (Printf.sprintf
           "operation lookup failed for attachment: %s"
           operation_id)

let detach_operation_attachment ~(config : Room.config) ~(session : Team_session_types.session) =
  match session.operation_id with
  | None -> ()
  | Some operation_id ->
      ignore
        (Command_plane_v2.update_operation config ~actor:session.created_by
           ~operation_id ~event_type:"team_session_detached"
           ~detail:
             (`Assoc
               [
                 ("session_id", `String session.session_id);
                 ("status",
                   `String
                     (Team_session_types.status_to_string session.status));
               ])
           (fun current ->
             if current.detachment_session_id = Some session.session_id then
               { current with detachment_session_id = None }
             else
               current))

let compute_live_done_delta (config : Room.config)
    (session : Team_session_types.session) =
  let backlog = Room.read_backlog config in
  let current_done = Team_session_types.done_counts_from_backlog backlog in
  (* Include backlog assignee names alongside session agent names.
     Room.join generates nicknames (e.g. "owner-jolly-llama") stored in
     session.agent_names, but task assignees use the raw name ("owner").
     Merging both sets ensures delta counts are not lost to name mismatch. *)
  let agents =
    Team_session_types.dedup_strings
      (session.agent_names
       @ List.map fst current_done
       @ List.map fst session.baseline_done_counts)
  in
  let deltas =
    Team_session_types.done_delta_by_agent ~baseline:session.baseline_done_counts
      ~current:current_done ~agents
  in
  let done_total = List.fold_left (fun acc (_, n) -> acc + n) 0 deltas in
  (deltas, done_total)

let done_delta_metrics (config : Room.config) (session : Team_session_types.session)
    : (string * int) list * int =
  match (session.final_done_delta_by_agent, session.final_done_delta_total) with
  | Some deltas, Some total -> (deltas, total)
  | Some deltas, None ->
      (deltas, List.fold_left (fun acc (_, n) -> acc + n) 0 deltas)
  | None, Some total ->
      let deltas, _ = compute_live_done_delta config session in
      (deltas, total)
  | None, None -> compute_live_done_delta config session

let policy_violations_add violations entry =
  Team_session_types.dedup_strings (violations @ [ entry ])
  |> take_last 64

let parse_summary_int key (json : Yojson.Safe.t) =
  match Yojson.Safe.Util.member key json with
  | `Int n -> n
  | `Intlit s -> (Option.value ~default:0 (int_of_string_opt s))
  | `Float v -> int_of_float v
  | _ -> 0

let parse_summary_float key (json : Yojson.Safe.t) =
  match Yojson.Safe.Util.member key json with
  | `Float v -> v
  | `Int n -> float_of_int n
  | `Intlit s -> (try float_of_string s with Failure _ -> 0.0)
  | _ -> 0.0

let team_health_json (session : Team_session_types.session) active_agents =
  let active_count = List.length active_agents in
  let required = max 1 session.min_agents in
  let coverage_ratio = min 1.0 (float_of_int active_count /. float_of_int required) in
  let health =
    if active_count >= required then
      "healthy"
    else if active_count >= max 1 (required / 2) then
      "degraded"
    else
      "critical"
  in
  `Assoc
    [
      ("status", `String health);
      ("active_agents_count", `Int active_count);
      ("required_agents", `Int required);
      ("coverage_ratio", `Float coverage_ratio);
      ("min_agents_violation_streak", `Int session.min_agents_violation_streak);
    ]

let communication_metrics_json (session : Team_session_types.session) =
  `Assoc
    [
      ( "mode",
        `String
          (Team_session_types.communication_mode_to_string
             session.communication_mode) );
      ("broadcast_count", `Int session.broadcast_count);
      ("portal_count", `Int session.portal_count);
      ("total", `Int (session.broadcast_count + session.portal_count));
    ]

let orchestration_state_json (session : Team_session_types.session) =
  `Assoc
    [
      ( "mode",
        `String
          (Team_session_types.orchestration_mode_to_string
             session.orchestration_mode) );
      ( "instruction_profile",
        `String
          (Team_session_types.instruction_profile_to_string
             session.instruction_profile) );
      ( "fallback_policy",
        `String
          (Team_session_types.fallback_policy_to_string
             session.fallback_policy) );
      ( "policy_violations",
        `List (List.map (fun v -> `String v) session.policy_violations) );
    ]

let cascade_metrics_json (session : Team_session_types.session) =
  let attempted = max 0 session.cascade_attempted in
  let success = max 0 session.cascade_success in
  let success_rate =
    if attempted = 0 then
      0.0
    else
      float_of_int success /. float_of_int attempted
  in
  `Assoc
    [
      ("model_cascade", `List (List.map (fun m -> `String m) session.model_cascade));
      ("attempted", `Int attempted);
      ("success", `Int success);
      ("failed", `Int (max 0 session.cascade_failed));
      ("success_rate", `Float success_rate);
      ("fallback_task_created", `Int (max 0 session.fallback_task_created));
    ]
