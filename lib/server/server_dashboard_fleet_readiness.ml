(* Fleet work-discovery readiness JSON.

   - [keeper_activation_readiness_json]: per-keeper readiness shape
     served by the dashboard composite endpoint.
   - [task_is_unclaimed_todo] / [unclaimed_todo_count]: derive
     unclaimed backlog count from [Coord.read_backlog].
   - [fleet_work_discovery_readiness_json]: roll up "is there a keeper
     that can pick up the unclaimed backlog right now?" into one wire
     payload with per-keeper rows + an aggregate ok/hint/blocker.

   Extracted from [Server_dashboard_http] (godfile decomp). Pure
   projection over [Keeper_registry.registry_entry] +
   [Coord.read_backlog]. *)

let keeper_activation_readiness_json (meta : Keeper_types.keeper_meta) =
  Keeper_activation_readiness.(of_meta meta |> to_yojson)
;;

let task_is_unclaimed_todo (task : Masc_domain.task) =
  match task.task_status with
  | Todo -> true
  | Claimed _ | InProgress _ | AwaitingVerification _ | Done _ | Cancelled _ -> false
;;

let unclaimed_todo_count ~(config : Coord.config) =
  try
    Coord.read_backlog config
    |> fun backlog ->
    List.fold_left
      (fun count task -> if task_is_unclaimed_todo task then count + 1 else count)
      0
      backlog.tasks
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Dashboard.warn
      "dashboard_fleet_composite_json failed to read backlog for work discovery \
       readiness: %s"
      (Printexc.to_string exn);
    0
;;

let fleet_work_discovery_readiness_json
      ~(todo_unclaimed_count : int)
      (entries : Keeper_registry.registry_entry list)
  =
  let rows =
    List.map
      (fun (entry : Keeper_registry.registry_entry) ->
         let meta = entry.meta in
         let readiness = Keeper_activation_readiness.of_meta meta in
         let autonomous_activation =
           readiness.Keeper_activation_readiness.autonomous_activation
         in
         let work_discovery_activation =
           readiness.Keeper_activation_readiness.work_discovery_activation
         in
         `Assoc
           [ "keeper", `String entry.name
           ; "ready_for_unclaimed_backlog", `Bool readiness.ready_for_unclaimed_backlog
           ; ( "autonomous_blocker"
             , Json_util.string_opt_to_json autonomous_activation.blocker )
           ; ( "work_discovery_blocker"
             , Json_util.string_opt_to_json work_discovery_activation.blocker )
           ; "paused", `Bool autonomous_activation.paused
           ; "autoboot_enabled", `Bool autonomous_activation.autoboot_enabled
           ; "proactive_enabled", `Bool autonomous_activation.proactive_enabled
           ; ( "work_discovery_enabled"
             , Json_util.bool_opt_to_json
                 work_discovery_activation.work_discovery_enabled )
           ; ( "current_task_id"
             , Json_util.string_opt_to_json work_discovery_activation.current_task_id )
           ])
      entries
  in
  let ready_keeper_count =
    List.fold_left
      (fun count (entry : Keeper_registry.registry_entry) ->
         if Keeper_activation_readiness.ready_for_unclaimed_backlog entry.meta
         then count + 1
         else count)
      0
      entries
  in
  let ok = todo_unclaimed_count = 0 || ready_keeper_count > 0 in
  `Assoc
    [ "ok", `Bool ok
    ; "todo_unclaimed_count", `Int todo_unclaimed_count
    ; "ready_keeper_count", `Int ready_keeper_count
    ; "keeper_count", `Int (List.length entries)
    ; ( "blocker"
      , Json_util.string_opt_to_json
          (if ok then None else Some "no_ready_work_discovery_keeper") )
    ; ( "hint"
      , Json_util.string_opt_to_json
          (if ok
           then None
           else
             Some
               "enable autoboot, proactive, and work_discovery on at least one \
                keeper before expecting todo backlog fan-out") )
    ; "keepers", `List rows
    ]
;;
