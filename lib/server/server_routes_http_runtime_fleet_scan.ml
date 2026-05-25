(* Server_routes_http_runtime_fleet_scan — keeper fleet scan,
   paused-keeper diagnostics, phase counts, and fleet safety health.

   Extracted from server_routes_http_runtime.ml during godfile decomposition.
   Depends on: Keeper_types, Keeper_types_profile, Keeper_meta_store, etc. *)

open Server_utils
open Server_routes_http_common

type paused_keeper_scan = {
  names : string list;
  autoboot_enabled_names : string list;
  details : Yojson.Safe.t list;
  read_errors : (string * string) list;
}

let empty_paused_keeper_scan =
  { names = []; autoboot_enabled_names = []; details = []; read_errors = [] }

let sorted_unique_strings values = List.sort_uniq String.compare values

let json_float_opt = function
  | Some value -> `Float value
  | None -> `Null

let json_string_opt = function
  | Some value -> `String value
  | None -> `Null

let effective_autoboot_enabled name (meta : Keeper_types.keeper_meta) =
  match (Keeper_types_profile.load_keeper_profile_defaults name).autoboot_enabled with
  | Some value -> value
  | None -> meta.autoboot_enabled

let blocker_class_string (info : Keeper_types.blocker_info option) =
  match info with
  | Some info ->
      let surface =
        Keeper_status_bridge.runtime_blocker_surface_of_typed_class
          ~summary:info.detail info.klass
      in
      Some surface.blocker_class
  | None -> None

let blocker_detail (info : Keeper_types.blocker_info option) =
  match info with
  | Some { detail; _ } when String.trim detail <> "" -> Some detail
  | Some _ | None -> None

let pause_elapsed_sec now (meta : Keeper_types.keeper_meta) =
  match Coord_resilience.Time.parse_iso8601_opt meta.updated_at with
  | Some updated_ts when updated_ts > 0.0 -> Some (max 0.0 (now -. updated_ts))
  | Some _ | None -> None

let pause_kind (meta : Keeper_types.keeper_meta) =
  if Keeper_supervisor_types.paused_meta_requires_reconcile_recovery meta then
    "reconcile_gated"
  else
    match meta.auto_resume_after_sec with
    | Some _ -> "auto_recoverable"
    | None -> "operator_paused"

let pause_auto_resume_source (meta : Keeper_types.keeper_meta) =
  match meta.auto_resume_after_sec with
  | Some _ -> Some "explicit"
  | None -> None

let paused_keeper_detail_json ~now ~name ~(autoboot_enabled : bool)
    (meta : Keeper_types.keeper_meta) =
  let elapsed = pause_elapsed_sec now meta in
  let remaining =
    match (meta.auto_resume_after_sec, elapsed) with
    | Some resume_after, Some elapsed -> Some (max 0.0 (resume_after -. elapsed))
    | Some resume_after, None -> Some resume_after
    | None, _ -> None
  in
  let last_blocker = meta.runtime.last_blocker in
  `Assoc [
    ("name", `String name);
    ("autoboot_enabled", `Bool autoboot_enabled);
    ("pause_kind", `String (pause_kind meta));
    ("auto_resume_after_sec", json_float_opt meta.auto_resume_after_sec);
    ( "persisted_auto_resume_after_sec"
    , json_float_opt meta.auto_resume_after_sec );
    ("auto_resume_source", json_string_opt (pause_auto_resume_source meta));
    ("paused_elapsed_sec", json_float_opt elapsed);
    ("auto_resume_remaining_sec", json_float_opt remaining);
    ("last_blocker_class", json_string_opt (blocker_class_string last_blocker));
    ("last_blocker_detail", json_string_opt (blocker_detail last_blocker));
    ( "missing_pause_root_cause",
      `Bool
        (Option.is_some meta.auto_resume_after_sec
         && Option.is_none meta.runtime.last_blocker) );
  ]

let running_paused_keeper_names () =
  Keeper_registry.all ()
  |> List.filter_map (fun (e : Keeper_registry.registry_entry) ->
       if e.meta.paused then Some e.name else None)
  |> sorted_unique_strings

let durable_paused_keeper_scan ?(include_details = true) config =
  (* NDT-OK: HTTP health snapshots report wall-clock pause age; state transitions remain ledger-driven. *)
  let now = Unix.gettimeofday () in
  Keeper_types.keeper_names config
  |> List.fold_left
       (fun acc name ->
         match Keeper_types.read_meta config name with
         | Ok (Some meta) when meta.paused ->
             let autoboot_enabled = effective_autoboot_enabled name meta in
             {
               acc with
               names = meta.name :: acc.names;
               autoboot_enabled_names =
                 (if autoboot_enabled then meta.name :: acc.autoboot_enabled_names
                  else acc.autoboot_enabled_names);
               details =
                 (if include_details
                  then
                    paused_keeper_detail_json
                      ~now
                      ~name:meta.name
                      ~autoboot_enabled
                      meta
                    :: acc.details
                  else acc.details);
             }
         | Ok (Some _) | Ok None -> acc
         | Error err ->
             { acc with read_errors = (name, err) :: acc.read_errors })
       empty_paused_keeper_scan
  |> fun scan ->
  {
    names = sorted_unique_strings scan.names;
    autoboot_enabled_names = sorted_unique_strings scan.autoboot_enabled_names;
    details =
      List.sort
        (fun left right ->
          let name = function
            | `Assoc fields -> (
              match List.assoc_opt "name" fields with
              | Some (`String value) -> value
              | _ -> "" )
            | _ -> ""
          in
          String.compare (name left) (name right))
        scan.details;
    read_errors = List.sort (fun (a, _) (b, _) -> String.compare a b) scan.read_errors;
  }

let paused_keepers_health_json_of_scan ~running_names durable_scan =
  let names = sorted_unique_strings (running_names @ durable_scan.names) in
  `Assoc [
    ("count", `Int (List.length names));
    ("names", `List (List.map (fun name -> `String name) names));
    ("running_count", `Int (List.length running_names));
    ("running_names", `List (List.map (fun name -> `String name) running_names));
    ("durable_count", `Int (List.length durable_scan.names));
    ("durable_names", `List (List.map (fun name -> `String name) durable_scan.names));
    ( "autoboot_enabled_count",
      `Int (List.length durable_scan.autoboot_enabled_names) );
    ( "autoboot_enabled_names",
      `List (List.map (fun name -> `String name) durable_scan.autoboot_enabled_names) );
    ("details", `List durable_scan.details);
    ("read_error_count", `Int (List.length durable_scan.read_errors));
    ( "read_errors",
      `List
        (List.map
           (fun (keeper, error) ->
             `Assoc [ ("keeper", `String keeper); ("error", `String error) ])
           durable_scan.read_errors) );
  ]

let paused_keepers_health_json () =
  let running_names = running_paused_keeper_names () in
  let durable_scan =
    match current_server_state_opt () with
    | Some state -> durable_paused_keeper_scan state.Mcp_server.room_config
    | None -> empty_paused_keeper_scan
  in
  paused_keepers_health_json_of_scan ~running_names durable_scan

type autoboot_keeper_scan = {
  autoboot_names : string list;
  read_errors : (string * string) list;
}

let empty_autoboot_keeper_scan = { autoboot_names = []; read_errors = [] }

type keeper_fleet_meta_scan = {
  paused_scan : paused_keeper_scan;
  autoboot_scan : autoboot_keeper_scan;
  bootable_names : string list;
}

let sort_paused_keeper_details details =
  List.sort
    (fun left right ->
      let name = function
        | `Assoc fields -> (
          match List.assoc_opt "name" fields with
          | Some (`String value) -> value
          | _ -> "" )
        | _ -> ""
      in
      String.compare (name left) (name right))
    details

let keeper_fleet_meta_scan ?(include_paused_details = true) config =
  (* The dashboard light shell needs fleet counts on every header refresh.
     Keep this as a single pass over keeper meta so it does not repeat the
     paused, autoboot, and bootable scans on the hot path. *)
  (* NDT-OK: request-boundary wall clock only for dashboard pause-age display. *)
  let now = Unix.gettimeofday () in
  let configured_names = Keeper_types.configured_keeper_names config in
  let all_names =
    sorted_unique_strings (configured_names @ Keeper_types.keeper_names config)
  in
  let is_configured name = List.exists (String.equal name) configured_names in
  let scan =
    all_names
    |> List.fold_left
         (fun acc name ->
           let add_autoboot acc name =
             {
               acc with
               autoboot_scan =
                 {
                   acc.autoboot_scan with
                   autoboot_names = name :: acc.autoboot_scan.autoboot_names;
                 };
             }
           in
           let add_bootable acc name =
             if is_configured name then { acc with bootable_names = name :: acc.bootable_names }
             else acc
           in
           match Keeper_types.read_meta config name with
           | Ok (Some meta) ->
             let autoboot_enabled = effective_autoboot_enabled name meta in
             let acc = if autoboot_enabled then add_autoboot acc meta.name else acc in
             let acc =
               if (not meta.paused) && autoboot_enabled
               then add_bootable acc meta.name
               else acc
             in
             if meta.paused
             then
               {
                 acc with
                 paused_scan =
                   {
                     acc.paused_scan with
                     names = meta.name :: acc.paused_scan.names;
                     autoboot_enabled_names =
                       (if autoboot_enabled
                        then meta.name :: acc.paused_scan.autoboot_enabled_names
                        else acc.paused_scan.autoboot_enabled_names);
                     details =
                       (if include_paused_details
                        then
                          paused_keeper_detail_json
                            ~now
                            ~name:meta.name
                            ~autoboot_enabled
                            meta
                          :: acc.paused_scan.details
                        else acc.paused_scan.details);
                   };
               }
             else acc
           | Ok None ->
             if Keeper_meta_store.declarative_autoboot_enabled_by_default name
             then add_autoboot acc name |> fun acc -> add_bootable acc name
             else acc
           | Error err ->
             (* Preserve the existing conservative behavior: unreadable meta is
                still counted as autoboot/bootable so the operator sees a
                degraded fleet instead of a silently shrinking target. *)
             let acc = add_autoboot acc name |> fun acc -> add_bootable acc name in
             {
               acc with
               paused_scan =
                 {
                   acc.paused_scan with
                   read_errors = (name, err) :: acc.paused_scan.read_errors;
                 };
               autoboot_scan =
                 {
                   acc.autoboot_scan with
                   read_errors = (name, err) :: acc.autoboot_scan.read_errors;
                 };
             })
         {
           paused_scan = empty_paused_keeper_scan;
           autoboot_scan = empty_autoboot_keeper_scan;
           bootable_names = [];
         }
  in
  {
    paused_scan =
      {
        names = sorted_unique_strings scan.paused_scan.names;
        autoboot_enabled_names =
          sorted_unique_strings scan.paused_scan.autoboot_enabled_names;
        details = sort_paused_keeper_details scan.paused_scan.details;
        read_errors =
          List.sort
            (fun (a, _) (b, _) -> String.compare a b)
            scan.paused_scan.read_errors;
      };
    autoboot_scan =
      {
        autoboot_names = sorted_unique_strings scan.autoboot_scan.autoboot_names;
        read_errors =
          List.sort
            (fun (a, _) (b, _) -> String.compare a b)
            scan.autoboot_scan.read_errors;
      };
    bootable_names = sorted_unique_strings scan.bootable_names;
  }

let autoboot_enabled_keeper_scan config =
  sorted_unique_strings (Keeper_types.configured_keeper_names config @ Keeper_types.keeper_names config)
  |> List.fold_left
       (fun acc name ->
         match Keeper_types.read_meta config name with
         | Ok (Some meta) ->
             if effective_autoboot_enabled name meta then
               { acc with autoboot_names = meta.name :: acc.autoboot_names }
             else acc
         | Ok None ->
             if Keeper_meta_store.declarative_autoboot_enabled_by_default name then
               { acc with autoboot_names = name :: acc.autoboot_names }
             else acc
         | Error err ->
             {
               autoboot_names = name :: acc.autoboot_names;
               read_errors = (name, err) :: acc.read_errors;
             })
       empty_autoboot_keeper_scan
  |> fun scan ->
  {
    autoboot_names = sorted_unique_strings scan.autoboot_names;
    read_errors = List.sort (fun (a, _) (b, _) -> String.compare a b) scan.read_errors;
  }

type keeper_phase_counts =
  { running : int
  ; failing : int
  ; recovering : int
  ; executable : int
  }

let keeper_phase_counts ?base_path () =
  Keeper_registry.all ?base_path ()
  |> List.fold_left
       (fun acc (entry : Keeper_registry.registry_entry) ->
          let executable =
            if Keeper_state_machine.can_execute_turn entry.phase then acc.executable + 1
            else acc.executable
          in
          (* Keepers in Failing phase with restart budget remaining are
             expected to recover on the next heartbeat cycle — count them
             separately so fleet safety does not report a spurious shortfall
             during transient failures (issue #17218). *)
          let recovering =
            match entry.phase with
            | Keeper_state_machine.Failing
              when entry.conditions.restart_budget_remaining ->
              acc.recovering + 1
            | _ -> acc.recovering
          in
          match entry.phase with
          | Keeper_state_machine.Running ->
            { acc with running = acc.running + 1; executable }
          | Keeper_state_machine.Failing ->
            { acc with failing = acc.failing + 1; recovering; executable }
          | Keeper_state_machine.Offline
          | Keeper_state_machine.Overflowed
          | Keeper_state_machine.Compacting
          | Keeper_state_machine.HandingOff
          | Keeper_state_machine.Draining
          | Keeper_state_machine.Paused
          | Keeper_state_machine.Stopped
          | Keeper_state_machine.Crashed
          | Keeper_state_machine.Restarting
          | Keeper_state_machine.Dead
          | Keeper_state_machine.Zombie -> { acc with executable })
       { running = 0; failing = 0; recovering = 0; executable = 0 }

let keeper_fleet_safety_health_json
    ?bootable_names:bootable_names_override
    ?autoboot_scan:autoboot_scan_override
    ~phase_counts
    ~paused_keepers_json
    () =
  let bootable_names, autoboot_scan =
    match (bootable_names_override, autoboot_scan_override) with
    | Some bootable_names, Some autoboot_scan -> (bootable_names, autoboot_scan)
    | _ -> (
      match current_server_state_opt () with
      | Some state ->
        (try
           ( Keeper_runtime.bootable_keeper_names state.Mcp_server.room_config
           , autoboot_enabled_keeper_scan state.Mcp_server.room_config )
         with
         | Eio.Cancel.Cancelled _ as exn -> raise exn
         | exn ->
           Log.Keeper.warn
             "health: failed to compute bootable keeper names: %s"
             (Printexc.to_string exn);
           ([], empty_autoboot_keeper_scan))
      | None -> ([], empty_autoboot_keeper_scan))
  in
  let bootable_count = List.length bootable_names in
  let target_count = List.length autoboot_scan.autoboot_names in
  let minimum_running_fibers =
    if target_count <= 1 then target_count else 2
  in
  let no_running_fibers = target_count > 0 && phase_counts.running = 0 in
  let no_executable_keeper_fibers = target_count > 0 && phase_counts.executable = 0 in
  let low_running_fiber_margin =
    target_count > 1 && phase_counts.running < minimum_running_fibers
  in
  let reaction_capacity_shortfall_count =
    max 0 (target_count - phase_counts.running - phase_counts.recovering)
  in
  let reaction_capacity_below_target =
    target_count > 0 && reaction_capacity_shortfall_count > 0
  in
  let executable_reaction_capacity_shortfall_count =
    max 0 (target_count - phase_counts.executable)
  in
  let executable_reaction_capacity_below_target =
    target_count > 0 && executable_reaction_capacity_shortfall_count > 0
  in
  let status =
    if no_executable_keeper_fibers then "blocked"
    else if no_running_fibers then "degraded"
    else if low_running_fiber_margin then "degraded"
    else if reaction_capacity_below_target then "degraded"
    else "ok"
  in
  let paused_total_count =
    match paused_keepers_json with
    | `Assoc fields ->
        (match List.assoc_opt "count" fields with
       | Some (`Int count) -> count
       | _ -> 0)
    | _ -> 0
  in
  let paused_autoboot_count =
    match paused_keepers_json with
    | `Assoc fields ->
        (match List.assoc_opt "autoboot_enabled_count" fields with
         | Some (`Int count) -> count
         | _ -> 0)
    | _ -> 0
  in
  let blocked_count =
    if no_executable_keeper_fibers then executable_reaction_capacity_shortfall_count
    else if no_running_fibers || low_running_fiber_margin || reaction_capacity_below_target
    then
      reaction_capacity_shortfall_count
    else 0
  in
  let blocker =
    if no_executable_keeper_fibers then Some "no_executable_keeper_fibers"
    else if no_running_fibers then Some "no_healthy_running_keeper_fibers"
    else if low_running_fiber_margin then Some "low_running_fiber_margin"
    else if reaction_capacity_below_target then Some "reaction_capacity_below_target"
    else if paused_autoboot_count > 0 then Some "durable_paused_autoboot_enabled"
    else None
  in
  `Assoc
    [ "status", `String status
    ; ("blocker", json_string_opt blocker)
    ; "bootable_keeper_count", `Int bootable_count
    ; ( "bootable_keeper_names"
      , `List (List.map (fun name -> `String name) bootable_names) )
    ; "autoboot_enabled_keeper_count", `Int target_count
    ; ( "autoboot_enabled_keeper_names"
      , `List (List.map (fun name -> `String name) autoboot_scan.autoboot_names) )
    ; "autoboot_enabled_read_error_count", `Int (List.length autoboot_scan.read_errors)
    ; ( "autoboot_enabled_read_errors"
      , `List
          (List.map
             (fun (keeper, error) ->
               `Assoc [ ("keeper", `String keeper); ("error", `String error) ])
             autoboot_scan.read_errors) )
    ; "running_keeper_fiber_count", `Int phase_counts.running
    ; "healthy_running_keeper_fiber_count", `Int phase_counts.running
    ; "failing_keeper_fiber_count", `Int phase_counts.failing
    ; "recovering_keeper_fiber_count", `Int phase_counts.recovering
    ; "executable_keeper_fiber_count", `Int phase_counts.executable
    ; "effective_reaction_capacity_count", `Int phase_counts.running
    ; "executable_reaction_capacity_count", `Int phase_counts.executable
    ; "target_reaction_capacity_count", `Int target_count
    ; "minimum_running_fibers", `Int minimum_running_fibers
    ; "no_running_fibers", `Bool no_running_fibers
    ; "no_executable_keeper_fibers", `Bool no_executable_keeper_fibers
    ; "low_running_fiber_margin", `Bool low_running_fiber_margin
    ; "reaction_capacity_below_target", `Bool reaction_capacity_below_target
    ; "reaction_capacity_shortfall_count", `Int reaction_capacity_shortfall_count
    ; ( "executable_reaction_capacity_below_target"
      , `Bool executable_reaction_capacity_below_target )
    ; ( "executable_reaction_capacity_shortfall_count"
      , `Int executable_reaction_capacity_shortfall_count )
    ; "paused_keeper_count", `Int paused_total_count
    ; "paused_autoboot_enabled_keeper_count", `Int paused_autoboot_count
    ; "blocked_count", `Int blocked_count
    ; "blocked_keepers", `Int blocked_count
    ; ( "operator_action_required"
      , `Bool
          (no_executable_keeper_fibers
           || no_running_fibers
           || low_running_fiber_margin
           || reaction_capacity_below_target) )
    ; "autoboot_throttle_limit"
    , `Int Keeper_keepalive.effective_turn_throttle_limit
    ; ( "autoboot_throttle_source"
      , `String (Config_boot_overrides.source "MASC_KEEPER_AUTOBOOT_MAX") )
    ]
