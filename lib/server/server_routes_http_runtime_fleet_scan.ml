(* Server_routes_http_runtime_fleet_scan — keeper fleet scan,
   paused-keeper diagnostics, phase counts, and fleet safety health.

   Extracted from server_routes_http_runtime.ml during godfile decomposition.
   Depends on: Keeper_types, Keeper_types_profile, Keeper_meta_store, etc. *)

open Server_routes_http_common

module String_set = Set.Make (String)

type paused_keeper_scan = {
  names : string list;
  autoboot_enabled_names : string list;
  details : Yojson.Safe.t list;
  read_errors : (string * string) list;
}

let empty_paused_keeper_scan =
  { names = []; autoboot_enabled_names = []; details = []; read_errors = [] }

let sorted_unique_strings values = List.sort_uniq String.compare values

let effective_autoboot_enabled = Keeper_meta_store.effective_autoboot_enabled

let pause_elapsed_sec now (meta : Keeper_meta_contract.keeper_meta) =
  match Workspace_resilience.Time.parse_iso8601_opt meta.updated_at with
  | Some updated_ts when updated_ts > 0.0 -> Some (max 0.0 (now -. updated_ts))
  | Some _ | None -> None

type pause_kind = Keeper_activation_readiness.pause_kind =
  | Active
  | Operator_paused
  | Unclassified_paused

let pause_kind = Keeper_activation_readiness.pause_kind
let pause_kind_to_wire = Keeper_activation_readiness.pause_kind_to_wire

let paused_keeper_detail_json ~now ~name ~(autoboot_enabled : bool)
    (meta : Keeper_meta_contract.keeper_meta) =
  let elapsed = pause_elapsed_sec now meta in
  `Assoc [
    ("name", `String name);
    ("autoboot_enabled", `Bool autoboot_enabled);
    ("pause_kind", `String (pause_kind_to_wire (pause_kind meta)));
    ("paused_elapsed_sec", Json_util.float_opt_to_json elapsed);
    ("missing_pause_root_cause", `Bool (Option.is_none meta.latched_reason));
  ]

let registry_paused_keeper_names () =
  Keeper_registry.all ()
  |> List.filter_map (fun (e : Keeper_registry.registry_entry) ->
       if e.meta.paused then Some e.name else None)
  |> sorted_unique_strings

let running_keeper_names ?base_path () =
  Keeper_registry.all ?base_path ()
  |> List.filter_map (fun (e : Keeper_registry.registry_entry) ->
       match e.phase with
       | Keeper_state_machine.Running ->
         if e.meta.paused then None else Some e.name
       | Keeper_state_machine.Offline
       | Keeper_state_machine.Failing
       | Keeper_state_machine.Draining
       | Keeper_state_machine.Paused
       | Keeper_state_machine.Stopped
       | Keeper_state_machine.Crashed
       | Keeper_state_machine.Restarting -> None)
  |> sorted_unique_strings

let durable_paused_keeper_scan config =
  (* NDT-OK: HTTP health snapshots report wall-clock pause age; state transitions remain ledger-driven. *)
  let now = Unix.gettimeofday () in
  Keeper_meta_store.keeper_names config
  |> List.fold_left
       (fun acc name ->
         match Keeper_meta_store.read_meta config name with
         | Ok (Some meta) when meta.paused ->
             let autoboot_enabled = effective_autoboot_enabled config name meta in
             {
               acc with
               names = meta.name :: acc.names;
               autoboot_enabled_names =
                 (if autoboot_enabled then meta.name :: acc.autoboot_enabled_names
                  else acc.autoboot_enabled_names);
               details =
                 paused_keeper_detail_json
                   ~now
                   ~name:meta.name
                   ~autoboot_enabled
                   meta
                 :: acc.details;
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

let paused_keepers_health_json_of_scan ~registry_paused_names durable_scan =
  let names = sorted_unique_strings (registry_paused_names @ durable_scan.names) in
  `Assoc [
    ("count", `Int (List.length names));
    ("names", `List (List.map (fun name -> `String name) names));
    ("registry_paused_count", `Int (List.length registry_paused_names));
    ("registry_paused_names", `List (List.map (fun name -> `String name) registry_paused_names));
    ("registry_paused_semantics", `String "registered keepers whose persisted meta has paused=true; this is not FSM phase=Running");
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
  let registry_paused_names = registry_paused_keeper_names () in
  let durable_scan =
    match current_server_state_opt () with
    | Some state -> durable_paused_keeper_scan (Mcp_server.workspace_config state)
    | None -> empty_paused_keeper_scan
  in
  paused_keepers_health_json_of_scan ~registry_paused_names durable_scan

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

type keeper_identity_drift_scan = {
  configured_names : string list;
  persisted_meta_names : string list;
  materializable_configured_names : string list;
  configured_without_meta_names : string list;
  meta_without_config_names : string list;
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
  let configured_names = Keeper_meta_store.configured_keeper_names config in
  let all_names =
    sorted_unique_strings (configured_names @ Keeper_meta_store.keeper_names config)
  in
  let is_configured name = List.exists (String.equal name) configured_names in
  let should_count_autoboot_target name = is_configured name in
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
           match Keeper_meta_store.read_meta config name with
           | Ok (Some meta) ->
             let autoboot_enabled = effective_autoboot_enabled config name meta in
             let acc =
               if
                 (not meta.paused)
                 && autoboot_enabled
                 && should_count_autoboot_target meta.name
               then add_autoboot acc meta.name
               else acc
             in
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
             if
               should_count_autoboot_target name
               && Keeper_meta_store.declarative_autoboot_enabled_by_default config name
             then add_autoboot acc name |> fun acc -> add_bootable acc name
             else acc
           | Error err ->
             (* Preserve the existing conservative behavior: unreadable meta is
                still counted as autoboot/bootable for configured keepers so
                the operator sees a degraded fleet instead of a silently
                shrinking target. *)
             let acc =
               if should_count_autoboot_target name
               then add_autoboot acc name |> fun acc -> add_bootable acc name
               else acc
             in
             let autoboot_read_errors =
               if should_count_autoboot_target name
               then (name, err) :: acc.autoboot_scan.read_errors
               else acc.autoboot_scan.read_errors
             in
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
                   read_errors = autoboot_read_errors;
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
  Keeper_meta_store.configured_keeper_names config
  |> sorted_unique_strings
  |> List.fold_left
       (fun acc name ->
         match Keeper_meta_store.read_meta config name with
         | Ok (Some meta) ->
             if (not meta.paused) && effective_autoboot_enabled config name meta then
               { acc with autoboot_names = meta.name :: acc.autoboot_names }
             else acc
         | Ok None ->
             if Keeper_meta_store.declarative_autoboot_enabled_by_default config name then
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
  }

let empty_keeper_phase_counts =
  { running = 0; failing = 0; recovering = 0 }

type keeper_phase_detail =
  { phase : string
  ; last_failure_reason : string option
  ; last_error : string option
  ; restart_count : int
  ; latest_crash_at : float option
  ; latest_crash_reason : string option
  }

type keeper_phase_snapshot =
  { counts : keeper_phase_counts
  ; running_names : string list
  ; recovering_names : string list
  ; configuration_blocked_names : string list
  ; phase_values : (string * Keeper_state_machine.phase) list
  ; phase_details : (string * keeper_phase_detail) list
  }

let keeper_phase_detail_of_entry (entry : Keeper_registry.registry_entry) =
  let latest_crash_at, latest_crash_reason =
    match entry.crash_log with
    | (ts, reason) :: _ -> (Some ts, Some reason)
    | [] -> (None, None)
  in
  {
    phase = Keeper_state_machine.phase_to_string entry.phase;
    last_failure_reason =
      Option.map Keeper_registry.failure_reason_to_string entry.last_failure_reason;
    last_error = entry.last_error;
    restart_count = entry.restart_count;
    latest_crash_at;
    latest_crash_reason;
  }

let keeper_phase_snapshot ?base_path () =
  Keeper_registry.all ?base_path ()
  |> List.fold_left
       (fun acc (entry : Keeper_registry.registry_entry) ->
         let acc =
            {
              acc with
              phase_values = (entry.name, entry.phase) :: acc.phase_values;
              phase_details =
                (entry.name, keeper_phase_detail_of_entry entry) :: acc.phase_details;
            }
          in
          let counts = acc.counts in
          let capacity_eligible = not entry.meta.paused in
          (* Phase inventory is not execution truth. Executability is projected
             separately through the shared closed owner-execution ADT. *)
          let is_recovering =
            match entry.phase with
            | Keeper_state_machine.Failing
              when capacity_eligible ->
              true
            | _ -> false
          in
          let recovering =
            if is_recovering then counts.recovering + 1 else counts.recovering
          in
          let recovering_names =
            if is_recovering then entry.name :: acc.recovering_names
            else acc.recovering_names
          in
          let configuration_blocked_names =
            match entry.phase, entry.last_failure_reason with
            | ( Keeper_state_machine.Failing
              , Some (Keeper_registry.Turn_configuration_error _) )
              when capacity_eligible ->
              entry.name :: acc.configuration_blocked_names
            | _ -> acc.configuration_blocked_names
          in
          match entry.phase with
          | Keeper_state_machine.Running when capacity_eligible ->
            {
              acc with
              counts = { counts with running = counts.running + 1 };
              running_names = entry.name :: acc.running_names;
              recovering_names;
              configuration_blocked_names;
            }
          | Keeper_state_machine.Running ->
            acc
          | Keeper_state_machine.Failing when capacity_eligible ->
            {
              acc with
              counts =
                { counts with failing = counts.failing + 1; recovering };
              recovering_names;
              configuration_blocked_names;
            }
          | Keeper_state_machine.Failing ->
            acc
          | Keeper_state_machine.Offline
          | Keeper_state_machine.Draining
          | Keeper_state_machine.Paused
          | Keeper_state_machine.Stopped
          | Keeper_state_machine.Crashed
          | Keeper_state_machine.Restarting ->
            acc)
       {
         counts = empty_keeper_phase_counts;
         running_names = [];
         recovering_names = [];
         configuration_blocked_names = [];
         phase_values = [];
         phase_details = [];
       }
  |> fun snapshot ->
  {
    snapshot with
    running_names = sorted_unique_strings snapshot.running_names;
    recovering_names = sorted_unique_strings snapshot.recovering_names;
    configuration_blocked_names =
      sorted_unique_strings snapshot.configuration_blocked_names;
    phase_values =
      List.sort (fun (a, _) (b, _) -> String.compare a b) snapshot.phase_values;
    phase_details =
      List.sort (fun (a, _) (b, _) -> String.compare a b) snapshot.phase_details;
  }

let keeper_phase_counts ?base_path () = (keeper_phase_snapshot ?base_path ()).counts

type keeper_execution_owner =
  { keeper_name : string
  ; truth : Keeper_activation_readiness.owner_execution_truth
  ; non_executable_cause : keeper_non_executable_cause option
  }
and keeper_non_executable_cause =
  | Cause_owner_absent_from_snapshot
  | Cause_owner_unregistered
  | Cause_no_keeper_binding
  | Cause_fiber_dead
  | Cause_lane_exited
  | Cause_completion_settled
  | Cause_autoboot_disabled
  | Cause_proactive_disabled
  | Cause_lifecycle_denied
  | Cause_runtime_terminal
  | Cause_shutdown_fenced
  | Cause_metadata_unavailable
  | Cause_runtime_not_live



let non_executable_cause ~registry_entry = function
  | Keeper_activation_readiness.Executable -> None
  | Keeper_activation_readiness.Recoverable ->
    Some
      (match registry_entry with
       | None -> Cause_owner_unregistered
       | Some (entry : Keeper_registry.registry_entry) ->
         if not entry.conditions.fiber_alive then Cause_fiber_dead
         else if Keeper_registry.lane_has_exited entry then Cause_lane_exited
         else if Option.is_some (Eio.Promise.peek entry.done_p) then
           Cause_completion_settled
         else Cause_runtime_not_live)
  | Keeper_activation_readiness.Retained_disabled
      Keeper_activation_readiness.Retained_autoboot_disabled ->
    Some Cause_autoboot_disabled
  | Keeper_activation_readiness.Retained_disabled
      Keeper_activation_readiness.Retained_proactive_disabled ->
    Some Cause_proactive_disabled
  | Keeper_activation_readiness.Paused_dead
      (Keeper_activation_readiness.Persisted_lifecycle_denied _) ->
    Some Cause_lifecycle_denied
  | Keeper_activation_readiness.Paused_dead
      (Keeper_activation_readiness.Runtime_terminal _) ->
    Some Cause_runtime_terminal
  | Keeper_activation_readiness.Shutdown_fenced _ -> Some Cause_shutdown_fenced
  | Keeper_activation_readiness.Unknown _ -> Some Cause_metadata_unavailable
;;

type keeper_execution_snapshot =
  { owners : keeper_execution_owner list
  ; executable_names : string list
  }

let empty_keeper_execution_snapshot =
  { owners = []; executable_names = [] }
;;

let keeper_execution_snapshot config =
  let base_path = config.Workspace.base_path in
  let registry_names =
    Keeper_registry.all ~base_path ()
    |> List.map (fun (entry : Keeper_registry.registry_entry) -> entry.name)
  in
  let queue_names =
    Keeper_event_queue_persistence.discover_keeper_names_with_durable_state
      ~base_path
    |> fun discovery -> discovery.keeper_names
  in
  let owner_names = sorted_unique_strings (registry_names @ queue_names) in
  let owners =
    List.map
      (fun keeper_name ->
        let meta_result =
          match Keeper_meta_store.read_effective_meta config keeper_name with
          | Ok (Some meta) -> Ok meta
          | Ok None -> Error "durable keeper metadata missing"
          | Error detail -> Error detail
        in
        let admission =
          Keeper_owner_registry.shutdown_operation_id ~base_path ~keeper_name
        in
        let registry_entry = Keeper_registry.get ~base_path keeper_name in
        let runtime =
          Keeper_activation_readiness.owner_runtime_of_registry_entry
            registry_entry
        in
        let truth =
          match admission with
          | Error error ->
            Keeper_activation_readiness.Unknown
              (Keeper_owner_registry.lookup_error_to_string error)
          | Ok shutdown_operation_id ->
            Keeper_activation_readiness.classify_durable_demand_execution
              ~shutdown_operation_id
              ~runtime
              meta_result
        in
        {
          keeper_name;
          truth;
          non_executable_cause = non_executable_cause ~registry_entry truth;
        })
      owner_names
  in
  let executable_names =
    owners
    |> List.filter_map (fun owner ->
      match owner.truth with
      | Keeper_activation_readiness.Executable -> Some owner.keeper_name
      | Keeper_activation_readiness.Recoverable
      | Keeper_activation_readiness.Retained_disabled _
      | Keeper_activation_readiness.Paused_dead _
      | Keeper_activation_readiness.Shutdown_fenced _
      | Keeper_activation_readiness.Unknown _ -> None)
  in
  { owners; executable_names }
;;

let owner_execution_truth snapshot ~keeper_name =
  match
    List.find_opt
      (fun owner -> String.equal owner.keeper_name keeper_name)
      snapshot.owners
  with
  | Some owner -> owner.truth
  | None ->
    Keeper_activation_readiness.Unknown
      "owner absent from canonical execution snapshot"
;;


let string_set_of_list values =
  List.fold_left (fun acc value -> String_set.add value acc) String_set.empty values

let json_string_list values = Json_util.json_string_list values

let configured_keeper_is_materializable config name =
  (* #22586: autoboot-disabled keepers carry no identity-drift materialization
     pressure. *)
  Keeper_meta_store.declarative_autoboot_enabled_by_default config name
  &&
  (* #22615: SSOT materializability predicate. #22616: the probe-load fallback
     is surfaced via the ProfileLoadFailures counter + warn inside
     Keeper_types_profile (replaces the previously silent inline check; the
     Cancelled re-raise discipline is preserved inside the helper). *)
  Keeper_types_profile.keeper_profile_defaults_materializable_for_name
    ~base_path:config.Workspace.base_path name

let keeper_identity_drift_scan config =
  let configured_names =
    Keeper_meta_store.configured_keeper_names config |> sorted_unique_strings
  in
  let persisted_meta_names =
    Keeper_meta_store.persisted_keeper_names config |> sorted_unique_strings
  in
  let materializable_configured_names =
    configured_names
    |> List.filter (configured_keeper_is_materializable config)
    |> sorted_unique_strings
  in
  let configured_set = string_set_of_list configured_names in
  let persisted_set = string_set_of_list persisted_meta_names in
  {
    configured_names;
    persisted_meta_names;
    materializable_configured_names;
    configured_without_meta_names =
      materializable_configured_names
      |> List.filter (fun name -> not (String_set.mem name persisted_set))
      |> sorted_unique_strings;
    meta_without_config_names =
      persisted_meta_names
      |> List.filter (fun name -> not (String_set.mem name configured_set))
      |> sorted_unique_strings;
  }

let keeper_identity_drift_health_json_of_scan scan =
  let configured_without_meta_count =
    List.length scan.configured_without_meta_names
  in
  let meta_without_config_count = List.length scan.meta_without_config_names in
  let blocking = meta_without_config_count > 0 in
  let status =
    if blocking then "blocked"
    else if configured_without_meta_count > 0 then "degraded"
    else "ok"
  in
  let terminal_reason =
    if meta_without_config_count > 0 then "runtime_meta_without_keeper_toml"
    else if configured_without_meta_count > 0 then "configured_keeper_without_runtime_meta"
    else "none"
  in
  `Assoc
    [
      ("schema", `String "masc.keeper_identity_drift.v1");
      ("status", `String status);
      ("blocking", `Bool blocking);
      ("terminal_reason", `String terminal_reason);
      ("operator_action_required", `Bool (status <> "ok"));
      ("configured_keeper_count", `Int (List.length scan.configured_names));
      ( "configured_keeper_names",
        json_string_list scan.configured_names );
      ( "materializable_configured_keeper_count",
        `Int (List.length scan.materializable_configured_names) );
      ( "materializable_configured_keeper_names",
        json_string_list scan.materializable_configured_names );
      ("persisted_meta_names", json_string_list scan.persisted_meta_names);
      ("configured_without_meta_count", `Int configured_without_meta_count);
      ( "configured_without_meta_names",
        json_string_list scan.configured_without_meta_names );
      ("meta_without_config_count", `Int meta_without_config_count);
      ( "meta_without_config_names",
        json_string_list scan.meta_without_config_names );
      ( "next_action",
        `String
          (if meta_without_config_count > 0 then
             "add_matching_keeper_toml_or_retire_stale_meta"
           else if configured_without_meta_count > 0 then
             "materialize_configured_keeper_or_disable_unused_toml"
           else "none") );
    ]

let keeper_identity_drift_health_json config =
  keeper_identity_drift_scan config |> keeper_identity_drift_health_json_of_scan


let active_task_owner_fiber_scan_semantics =
  "reports keeper-shaped active task owners without executable keeper fibers; \
   disabled keepers are excluded; matching keeper rows can degrade fleet \
   status; AwaitingVerification obligations are reported separately as \
   system-LLM completion-authority pending rows and never as Keeper blockers; \
   credentialed non-keeper client task owners are reported separately as \
   advisory rows"



type active_task_owner_without_executable_fiber = {
  keeper_name : string option;
  agent_name : string;
  task_id : string;
  task_status : string;
}

type completion_authority_pending_task = {
  producer_agent_name : string;
  task_id : string;
  submitted_at : string;
  verification_id : string;
}

type non_keeper_active_task_owner = {
  agent_name : string;
  task_id : string;
  task_status : string;
}

type active_task_owner_fiber_scan = {
  active_task_owner_without_executable_fibers :
    active_task_owner_without_executable_fiber list;
  completion_authority_pending_tasks : completion_authority_pending_task list;
  non_keeper_active_task_owners : non_keeper_active_task_owner list;
  active_task_owner_scan_errors : (string * string) list;
}

let empty_active_task_owner_fiber_scan =
  {
    active_task_owner_without_executable_fibers = [];
    completion_authority_pending_tasks = [];
    non_keeper_active_task_owners = [];
    active_task_owner_scan_errors = [];
  }

let compare_string_pair (left_name, left_detail) (right_name, right_detail) =
  let cmp = String.compare left_name right_name in
  if cmp <> 0 then cmp else String.compare left_detail right_detail

let compare_active_task_owner_without_executable_fiber left right =
  let cmp = Option.compare String.compare left.keeper_name right.keeper_name in
  if cmp <> 0 then cmp
  else
    let cmp = String.compare left.agent_name right.agent_name in
    if cmp <> 0 then cmp
    else String.compare left.task_id right.task_id

let compare_completion_authority_pending_task left right =
  let cmp = String.compare left.producer_agent_name right.producer_agent_name in
  if cmp <> 0 then cmp
  else
    let cmp = String.compare left.task_id right.task_id in
    if cmp <> 0 then cmp
    else String.compare left.verification_id right.verification_id

let compare_non_keeper_active_task_owner left right =
  let cmp = String.compare left.agent_name right.agent_name in
  if cmp <> 0 then cmp else String.compare left.task_id right.task_id

type active_task_assignment =
  | Keeper_task_owner of { assignee : string; task_status : string }
  | Completion_authority_pending of {
      producer_agent_name : string;
      submitted_at : string;
      verification_id : string;
    }

let active_task_assignment (task : Masc_domain.task) =
  match task.task_status with
  | Masc_domain.AwaitingVerification { assignee; submitted_at; verification_id; _ } ->
      Some
        (Completion_authority_pending
           { producer_agent_name = assignee; submitted_at; verification_id })
  | task_status ->
      Masc_domain.task_assignee_of_status task_status
      |> Option.map (fun assignee ->
             Keeper_task_owner
               {
                 assignee;
                 task_status = Workspace_task_schedule.task_status_label task_status;
               })

let active_task_owner_without_executable_fiber_json row =
  `Assoc
    [
      ("keeper_name", Json_util.string_opt_to_json row.keeper_name);
      ("agent_name", `String row.agent_name);
      ("task_id", `String row.task_id);
      ("task_status", `String row.task_status);
      ("executable", `Bool false);
    ]

let completion_authority_pending_task_json row =
  `Assoc
    [
      ("producer_agent_name", `String row.producer_agent_name);
      ("task_id", `String row.task_id);
      ("submitted_at", `String row.submitted_at);
      ("verification_id", `String row.verification_id);
      ("owner_kind", `String "system_llm_completion_authority");
      ("fleet_blocking", `Bool false);
    ]

let non_keeper_active_task_owner_json row =
  `Assoc
    [
      ("agent_name", `String row.agent_name);
      ("task_id", `String row.task_id);
      ("task_status", `String row.task_status);
      ("owner_kind", `String "non_keeper_client");
      ("fleet_blocking", `Bool false);
    ]

type keeper_agent_binding_scan = {
  enabled_keeper_names : string list;
  disabled_agent_names : string list;
  binding_read_errors : (string * string) list;
}

let empty_keeper_agent_binding_scan =
  { enabled_keeper_names = []; disabled_agent_names = []; binding_read_errors = [] }

let keeper_agent_bindings config =
  Keeper_meta_store.configured_keeper_names config
  |> sorted_unique_strings
  |> List.fold_left
       (fun scan name ->
         match Keeper_meta_store.read_meta config name with
         | Ok (Some meta) ->
             if effective_autoboot_enabled config name meta then
               {
                 scan with
                 enabled_keeper_names = meta.name :: scan.enabled_keeper_names;
               }
             else
               {
                 scan with
                 disabled_agent_names = meta.name :: scan.disabled_agent_names;
               }
         | Ok None -> scan
         | Error err ->
             {
               scan with
               binding_read_errors = (name, err) :: scan.binding_read_errors;
             })
       empty_keeper_agent_binding_scan
  |> fun scan ->
  {
    enabled_keeper_names = sorted_unique_strings scan.enabled_keeper_names;
    disabled_agent_names = sorted_unique_strings scan.disabled_agent_names;
    binding_read_errors =
      List.sort_uniq compare_string_pair scan.binding_read_errors;
  }

let keeper_names_for_agent enabled_keeper_names assignee =
  List.filter (String.equal assignee) enabled_keeper_names

let is_credentialed_external_client config assignee =
  (not (List.mem assignee (Keeper_meta_store.keeper_names config)))
  &&
  match Auth.load_credential config.Workspace_utils_backend_setup.base_path assignee with
  | Some _ -> true
  | None -> false

let active_task_owner_fiber_scan config ~executable_names =
  let executable_set = string_set_of_list executable_names in
  let binding_scan = keeper_agent_bindings config in
  let agent_bindings = binding_scan.enabled_keeper_names in
  let meta_read_errors = binding_scan.binding_read_errors in
  match Workspace.read_backlog_observation_with_source_r config with
  | Error err ->
      {
        active_task_owner_without_executable_fibers = [];
        completion_authority_pending_tasks = [];
        non_keeper_active_task_owners = [];
        active_task_owner_scan_errors =
          ("backlog", err) :: meta_read_errors;
      }
  | Ok observation ->
      let backlog = observation.observed_backlog in
      let backlog_read_errors =
        match observation.recovered_from with
        | None -> []
        | Some recovery ->
          [ ( "backlog"
            , Printf.sprintf
                "primary backlog unavailable; observing recovery snapshot at %s: %s"
                recovery.recovery_path
                recovery.primary_error ) ]
      in
      let pending_rows, blocking_rows, non_keeper_rows =
        backlog.tasks
        |> List.fold_left
             (fun (pending_rows, blocking_rows, non_keeper_rows) task ->
             match active_task_assignment task with
             | None -> (pending_rows, blocking_rows, non_keeper_rows)
             | Some
                 (Completion_authority_pending
                    { producer_agent_name; submitted_at; verification_id }) ->
                 ( { producer_agent_name
                   ; task_id = task.id
                   ; submitted_at
                   ; verification_id
                   }
                   :: pending_rows
                 , blocking_rows
                 , non_keeper_rows )
             | Some (Keeper_task_owner { assignee; task_status }) ->
                 let keeper_names = keeper_names_for_agent agent_bindings assignee in
                 if
                   List.exists
                     (fun keeper_name -> String_set.mem keeper_name executable_set)
                     keeper_names
                 then (pending_rows, blocking_rows, non_keeper_rows)
                 else (
                   match keeper_names with
                   | []
                     when is_credentialed_external_client config assignee ->
                       ( pending_rows
                       , blocking_rows
                       , {
                           agent_name = assignee;
                           task_id = task.id;
                           task_status;
                         }
                         :: non_keeper_rows )
                   | []
                     when List.mem assignee binding_scan.disabled_agent_names
                          || meta_read_errors <> [] ->
                       (pending_rows, blocking_rows, non_keeper_rows)
                   | [] ->
                       ( pending_rows
                       , {
                           keeper_name = None;
                           agent_name = assignee;
                           task_id = task.id;
                           task_status;
                         }
                         :: blocking_rows
                       , non_keeper_rows )
                   | keeper_names ->
                       ( pending_rows
                       , keeper_names
                         |> List.fold_left
                              (fun rows keeper_name ->
                                {
                                  keeper_name = Some keeper_name;
                                  agent_name = assignee;
                                  task_id = task.id;
                                  task_status;
                                }
                                :: rows)
                              blocking_rows
                       , non_keeper_rows )))
             ([], [], [])
      in
      let pending_rows =
        pending_rows
        |> List.sort_uniq compare_completion_authority_pending_task
      in
      let rows =
        blocking_rows
        |> List.sort_uniq compare_active_task_owner_without_executable_fiber
      in
      let non_keeper_rows =
        non_keeper_rows |> List.sort_uniq compare_non_keeper_active_task_owner
      in
      {
        active_task_owner_without_executable_fibers = rows;
        completion_authority_pending_tasks = pending_rows;
        non_keeper_active_task_owners = non_keeper_rows;
        active_task_owner_scan_errors = backlog_read_errors @ meta_read_errors;
      }



let keeper_fleet_safety_health_json
    ?bootable_names:bootable_names_override
    ?autoboot_scan:autoboot_scan_override
    ?phase_snapshot
    ~execution_snapshot
    ?base_path
    ?reaction_capacity_names
    ?keeper_bootstrap_enabled:keeper_bootstrap_enabled_override
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
           ( Keeper_runtime.bootable_keeper_names (Mcp_server.workspace_config state)
           , autoboot_enabled_keeper_scan (Mcp_server.workspace_config state) )
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
  let keeper_bootstrap_enabled =
    match keeper_bootstrap_enabled_override with
    | Some value -> value
    | None -> Env_config.KeeperBootstrap.enabled
  in
  let runtime_base_path =
    match base_path with
    | Some _ as value -> value
    | None ->
      current_server_state_opt ()
      |> Option.map (fun state -> (Mcp_server.workspace_config state).base_path)
  in
  let executable_names = execution_snapshot.executable_names in
  let executable_count = List.length executable_names in
  let fallback_running_names =
    match reaction_capacity_names with
    | Some names -> sorted_unique_strings names
    | None -> running_keeper_names ?base_path:runtime_base_path ()
  in
  let running_names =
    match phase_snapshot with
    | Some snapshot -> snapshot.running_names
    | None -> fallback_running_names
  in
  let recovering_names =
    match phase_snapshot with
    | Some snapshot -> snapshot.recovering_names
    | None -> []
  in
  let configuration_blocked_names =
    match phase_snapshot with
    | Some snapshot ->
      List.filter
        (fun name -> List.exists (String.equal name) autoboot_scan.autoboot_names)
        snapshot.configuration_blocked_names
    | None -> []
  in
  let configuration_blocked_count = List.length configuration_blocked_names in
  let all_target_keepers_configuration_blocked =
    target_count > 0 && configuration_blocked_count >= target_count
  in
  let active_task_owner_scan =
    match current_server_state_opt () with
    | Some state ->
        active_task_owner_fiber_scan
          (Mcp_server.workspace_config state)
          ~executable_names
    | None -> empty_active_task_owner_fiber_scan
  in
  let active_task_owner_without_executable_fiber_names =
    active_task_owner_scan.active_task_owner_without_executable_fibers
    |> List.filter_map (fun row -> row.keeper_name)
    |> sorted_unique_strings
  in
  let active_task_owner_without_executable_fiber_count =
    List.length active_task_owner_scan.active_task_owner_without_executable_fibers
  in
  let non_keeper_active_task_owner_count =
    List.length active_task_owner_scan.non_keeper_active_task_owners
  in
  let active_task_owner_without_executable_fiber =
    active_task_owner_without_executable_fiber_count > 0
  in
  let backlog_observation_degraded =
    List.exists
      (fun (source, _) -> String.equal source "backlog")
      active_task_owner_scan.active_task_owner_scan_errors
  in
  let completion_authority_pending_task_count =
    List.length active_task_owner_scan.completion_authority_pending_tasks
  in
  let completion_authority_pending = completion_authority_pending_task_count > 0 in
  let no_executable_keeper_fibers = target_count > 0 && executable_count = 0 in
  let reaction_capacity_shortfall_count =
    max 0 (target_count - executable_count)
  in
  let reaction_capacity_below_target =
    target_count > 0 && reaction_capacity_shortfall_count > 0
  in
  let keeper_bootstrap_blocked =
    (not keeper_bootstrap_enabled)
    && (no_executable_keeper_fibers || reaction_capacity_below_target)
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
  let status =
    if no_executable_keeper_fibers then "blocked"
    else if all_target_keepers_configuration_blocked then "blocked"
    else if configuration_blocked_count > 0 then "degraded"
    else if reaction_capacity_below_target then "degraded"
    else if active_task_owner_without_executable_fiber then "degraded"
    else if backlog_observation_degraded then "degraded"
    else "ok"
  in
  (* Which keepers are not running is bootable minus executable, and both
     lists ship in this response. The subtraction belongs to whoever reads
     them, so it is not precomputed here. *)
  let blocker =
    if keeper_bootstrap_blocked then Some "keeper_bootstrap_disabled"
    else if no_executable_keeper_fibers then Some "no_executable_keeper_fibers"
    else if configuration_blocked_count > 0 then Some "turn_configuration_error"
    else if reaction_capacity_below_target then Some "reaction_capacity_below_target"
    else if active_task_owner_without_executable_fiber
    then Some "active_task_owner_without_executable_fiber"
    else if paused_autoboot_count > 0 then Some "durable_paused_autoboot_enabled"
    else None
  in
  `Assoc
    [ "schema", `String "masc.keeper_fleet_operator.v1"
    ; "status", `String status
    ; ("blocker", Json_util.string_opt_to_json blocker)
    ; "keeper_bootstrap_enabled", `Bool keeper_bootstrap_enabled
    ; ( "keeper_bootstrap_blocker"
      , if keeper_bootstrap_blocked then `String "keeper_bootstrap_disabled" else `Null )
    ; "bootable_keeper_count", `Int bootable_count
    ; ( "bootable_keeper_names"
      , `List (List.map (fun name -> `String name) bootable_names) )
    ; "autoboot_enabled_keeper_count", `Int target_count
    ; ( "autoboot_enabled_keeper_names"
      , `List (List.map (fun name -> `String name) autoboot_scan.autoboot_names) )
    ; ( "autoboot_enabled_read_errors"
      , `List
          (List.map
             (fun (keeper, error) ->
               `Assoc [ ("keeper", `String keeper); ("error", `String error) ])
             autoboot_scan.read_errors) )
    ; "running_keeper_fiber_count", `Int phase_counts.running
    ; "running_keeper_names", `List (List.map (fun name -> `String name) running_names)
    ; "failing_keeper_fiber_count", `Int phase_counts.failing
    ; "recovering_keeper_fiber_count", `Int phase_counts.recovering
    ; ( "recovering_keeper_names"
      , `List (List.map (fun name -> `String name) recovering_names) )
    ; "configuration_blocked_keeper_count", `Int configuration_blocked_count
    ; ( "configuration_blocked_keeper_names"
      , `List (List.map (fun name -> `String name) configuration_blocked_names) )
    ; ( "all_target_keepers_configuration_blocked"
      , `Bool all_target_keepers_configuration_blocked )
    ; "executable_keeper_fiber_count", `Int executable_count
    ; ( "executable_keeper_names"
      , `List (List.map (fun name -> `String name) executable_names) )
    ; "target_reaction_capacity_count", `Int target_count
    ; "no_executable_keeper_fibers", `Bool no_executable_keeper_fibers
    ; ( "active_task_owner_without_executable_fiber"
      , `Bool active_task_owner_without_executable_fiber )
    ; ( "active_task_owner_without_executable_fiber_count"
      , `Int active_task_owner_without_executable_fiber_count )
    ; ( "active_task_owner_without_executable_fiber_names"
      , `List
          (List.map
             (fun name -> `String name)
             active_task_owner_without_executable_fiber_names) )
    ; ( "active_task_owner_without_executable_fiber_tasks"
      , `List
          (List.map
             active_task_owner_without_executable_fiber_json
             active_task_owner_scan.active_task_owner_without_executable_fibers) )
    ; "completion_authority_pending", `Bool completion_authority_pending
    ; ( "completion_authority_pending_task_count"
      , `Int completion_authority_pending_task_count )
    ; ( "completion_authority_pending_tasks"
      , `List
          (List.map
             completion_authority_pending_task_json
             active_task_owner_scan.completion_authority_pending_tasks) )
    ; ( "completion_authority_pending_semantics"
      , `String
          "AwaitingVerification obligations awaiting a verdict from the system \
           LLM completion-authority lane; producer ownership is retained for \
           task identity but this row is never a Keeper fleet blocker" )
    ; ( "non_keeper_active_task_owner_count"
      , `Int non_keeper_active_task_owner_count )
    ; ( "non_keeper_active_task_owners"
      , `List
          (List.map
             non_keeper_active_task_owner_json
             active_task_owner_scan.non_keeper_active_task_owners) )
    ; ( "non_keeper_active_task_owner_semantics"
      , `String
          "active tasks owned by credentialed non-keeper clients; visible for \
           operators but not keeper fleet blockers" )
    ; ( "active_task_owner_fiber_scan_semantics"
      , `String active_task_owner_fiber_scan_semantics )
    ; ( "active_task_owner_scan_error_count"
      , `Int (List.length active_task_owner_scan.active_task_owner_scan_errors) )
    ; ( "active_task_owner_scan_errors"
      , `List
          (List.map
             (fun (source, error) ->
               `Assoc [ ("source", `String source); ("error", `String error) ])
             active_task_owner_scan.active_task_owner_scan_errors) )
    ; "reaction_capacity_below_target", `Bool reaction_capacity_below_target
    ; "reaction_capacity_shortfall_count", `Int reaction_capacity_shortfall_count
    ; "paused_keeper_count", `Int paused_total_count
    ; "paused_autoboot_enabled_keeper_count", `Int paused_autoboot_count
    ; ( "operator_action_required"
      , `Bool
          (no_executable_keeper_fibers
           || configuration_blocked_count > 0
           || reaction_capacity_below_target
           || keeper_bootstrap_blocked
           || active_task_owner_without_executable_fiber) )
    ]
