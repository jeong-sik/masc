(* Server_routes_http_runtime_fleet_scan — keeper fleet scan,
   paused-keeper diagnostics, phase counts, and fleet safety health.

   Extracted from server_routes_http_runtime.ml during godfile decomposition.
   Depends on: Keeper_types, Keeper_types_profile, Keeper_meta_store, etc. *)

open Server_utils
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

let blocker_class_string (info : Keeper_meta_contract.blocker_info option) =
  Option.map (fun (info : Keeper_meta_contract.blocker_info) ->
    Keeper_meta_contract.blocker_class_to_string info.klass) info

let blocker_detail (info : Keeper_meta_contract.blocker_info option) =
  Option.map (fun (info : Keeper_meta_contract.blocker_info) -> info.detail) info

let pause_elapsed_sec now (meta : Keeper_meta_contract.keeper_meta) =
  match Workspace_resilience.Time.parse_iso8601_opt meta.updated_at with
  | Some updated_ts when updated_ts > 0.0 -> Some (max 0.0 (now -. updated_ts))
  | Some _ | None -> None

type pause_kind = Keeper_activation_readiness.pause_kind =
  | Active
  | Operator_paused
  | Unclassified_paused
  | Dead_tombstone

let pause_kind = Keeper_activation_readiness.pause_kind
let pause_kind_to_wire = Keeper_activation_readiness.pause_kind_to_wire

let paused_keeper_detail_json ~now ~name ~(autoboot_enabled : bool)
    (meta : Keeper_meta_contract.keeper_meta) =
  let elapsed = pause_elapsed_sec now meta in
  let last_blocker = meta.runtime.last_blocker in
  `Assoc [
    ("name", `String name);
    ("autoboot_enabled", `Bool autoboot_enabled);
    ("pause_kind", `String (pause_kind_to_wire (pause_kind meta)));
    ("paused_elapsed_sec", Json_util.float_opt_to_json elapsed);
    ( "last_blocker"
    , match last_blocker with
      | Some info -> Keeper_meta_contract.blocker_info_to_json info
      | None -> `Null );
    ( "missing_pause_root_cause"
    , `Bool
        (Option.is_none meta.latched_reason
         && Option.is_none meta.runtime.last_blocker) );
  ]

let registry_paused_keeper_names () =
  Keeper_registry.all ()
  |> List.filter_map (fun (e : Keeper_registry.registry_entry) ->
       if e.meta.paused then Some e.name else None)
  |> sorted_unique_strings

let running_paused_keeper_names = registry_paused_keeper_names

let running_keeper_names ?base_path () =
  Keeper_registry.all ?base_path ()
  |> List.filter_map (fun (e : Keeper_registry.registry_entry) ->
       match e.phase with
       | Keeper_state_machine.Running ->
         if e.meta.paused then None else Some e.name
       | Keeper_state_machine.Offline
       | Keeper_state_machine.Overflowed
       | Keeper_state_machine.Failing
       | Keeper_state_machine.Compacting
       | Keeper_state_machine.HandingOff
       | Keeper_state_machine.Draining
       | Keeper_state_machine.Paused
       | Keeper_state_machine.Stopped
       | Keeper_state_machine.Crashed
       | Keeper_state_machine.Restarting
       | Keeper_state_machine.Dead -> None)
  |> sorted_unique_strings

let durable_paused_keeper_scan ?(include_details = true) config =
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
    ("registry_paused_count", `Int (List.length running_names));
    ("registry_paused_names", `List (List.map (fun name -> `String name) running_names));
    ("registry_paused_semantics", `String "registered keepers whose persisted meta has paused=true; this is not FSM phase=Running");
    ("running_count", `Int (List.length running_names));
    ("running_names", `List (List.map (fun name -> `String name) running_names));
    ("running_count_semantics", `String "legacy alias for registry_paused_count");
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
    | Some state -> durable_paused_keeper_scan (Mcp_server.workspace_config state)
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
  ; executable : int
  }

let empty_keeper_phase_counts =
  { running = 0; failing = 0; recovering = 0; executable = 0 }

type keeper_phase_detail =
  { phase : string
  ; last_failure_reason : string option
  ; last_error : string option
  ; restart_count : int
  ; dead_since_ts : float option
  ; latest_crash_at : float option
  ; latest_crash_reason : string option
  }

type keeper_phase_snapshot =
  { counts : keeper_phase_counts
  ; running_names : string list
  ; recovering_names : string list
  ; executable_names : string list
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
    dead_since_ts = entry.dead_since_ts;
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
          let can_execute =
            capacity_eligible && Keeper_state_machine.can_execute_turn entry.phase
          in
          let executable = if can_execute then counts.executable + 1 else counts.executable in
          let executable_names =
            if can_execute then entry.name :: acc.executable_names
            else acc.executable_names
          in
          (* Failing remains executable and can recover on the next successful
             heartbeat or turn. Count it separately without a restart gate. *)
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
          match entry.phase with
          | Keeper_state_machine.Running when capacity_eligible ->
            {
              acc with
              counts = { counts with running = counts.running + 1; executable };
              running_names = entry.name :: acc.running_names;
              recovering_names;
              executable_names;
            }
          | Keeper_state_machine.Running ->
            { acc with counts = { counts with executable }; executable_names }
          | Keeper_state_machine.Failing when capacity_eligible ->
            {
              acc with
              counts =
                { counts with failing = counts.failing + 1; recovering; executable };
              recovering_names;
              executable_names;
            }
          | Keeper_state_machine.Failing ->
            { acc with counts = { counts with executable }; executable_names }
          | Keeper_state_machine.Offline
          | Keeper_state_machine.Overflowed
          | Keeper_state_machine.Compacting
          | Keeper_state_machine.HandingOff
          | Keeper_state_machine.Draining
          | Keeper_state_machine.Paused
          | Keeper_state_machine.Stopped
          | Keeper_state_machine.Crashed
          | Keeper_state_machine.Restarting
          | Keeper_state_machine.Dead ->
            { acc with counts = { counts with executable }; executable_names })
       {
         counts = empty_keeper_phase_counts;
         running_names = [];
         recovering_names = [];
         executable_names = [];
         phase_values = [];
         phase_details = [];
       }
  |> fun snapshot ->
  {
    snapshot with
    running_names = sorted_unique_strings snapshot.running_names;
    recovering_names = sorted_unique_strings snapshot.recovering_names;
    executable_names = sorted_unique_strings snapshot.executable_names;
    phase_values =
      List.sort (fun (a, _) (b, _) -> String.compare a b) snapshot.phase_values;
    phase_details =
      List.sort (fun (a, _) (b, _) -> String.compare a b) snapshot.phase_details;
  }

let keeper_phase_counts ?base_path () = (keeper_phase_snapshot ?base_path ()).counts

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
      ("persisted_meta_count", `Int (List.length scan.persisted_meta_names));
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

let json_string_list_field field = function
  | `Assoc fields -> (
      match List.assoc_opt field fields with
      | Some (`List values) ->
          values
          |> List.filter_map (function
               | `String value -> Some value
               | _ -> None)
          |> sorted_unique_strings
      | _ -> [])
  | _ -> []

type blocked_keeper_reason =
  | Durable_paused_autoboot_enabled
  | Meta_read_error
  | Not_bootable
  | Boot_failure of Keeper_runtime.boot_meta_failure_cause
  | Phase of Keeper_state_machine.phase
  | Bootstrap_disabled
  | Not_registered
  | Not_running
  | No_keeper_binding
  | Unknown

let blocked_keeper_reason_label = function
  | Durable_paused_autoboot_enabled -> "durable_paused_autoboot_enabled"
  | Meta_read_error -> "meta_read_error"
  | Not_bootable -> "not_bootable"
  | Boot_failure cause -> Keeper_runtime.boot_meta_failure_cause_label cause
  | Phase phase -> "phase_" ^ Keeper_state_machine.phase_to_string phase
  | Bootstrap_disabled -> "keeper_bootstrap_disabled"
  | Not_registered -> "not_registered"
  | Not_running -> "not_running"
  | No_keeper_binding -> "no_keeper_binding"
  | Unknown -> "unknown"

type blocked_keeper_operator_action =
  | Resume_or_leave_paused
  | Repair_keeper_meta_file
  | Add_keeper_toml_or_disable_stale_autoboot_meta
  | Run_keeper_up_or_recreate_meta
  | Repair_keeper_toml_config
  | Add_sandbox_profile_to_keeper_toml
  | Inspect_keeper_autoboot_logs
  | Enable_keeper_bootstrap_or_start_manually
  | Inspect_dead_keeper_root_cause
  | Restart_or_disable_stopped_keeper
  | Start_or_recover_keeper
  | Inspect_capacity_accounting
  | Repair_failing_keeper
  | Recover_context_overflow
  | Wait_for_compaction
  | Wait_for_handoff
  | Wait_for_keeper_drain
  | Inspect_crashed_keeper
  | Wait_for_keeper_restart
  | Create_keeper_or_reassign_task

let blocked_keeper_operator_action_to_string = function
  | Resume_or_leave_paused -> "resume_or_leave_paused"
  | Repair_keeper_meta_file -> "repair_keeper_meta_file"
  | Add_keeper_toml_or_disable_stale_autoboot_meta ->
      "add_keeper_toml_or_disable_stale_autoboot_meta"
  | Run_keeper_up_or_recreate_meta -> "run_keeper_up_or_recreate_meta"
  | Repair_keeper_toml_config -> "repair_keeper_toml_config"
  | Add_sandbox_profile_to_keeper_toml -> "add_sandbox_profile_to_keeper_toml"
  | Inspect_keeper_autoboot_logs -> "inspect_keeper_autoboot_logs"
  | Enable_keeper_bootstrap_or_start_manually ->
      "enable_keeper_bootstrap_or_start_manually"
  | Inspect_dead_keeper_root_cause -> "inspect_dead_keeper_root_cause"
  | Restart_or_disable_stopped_keeper -> "restart_or_disable_stopped_keeper"
  | Start_or_recover_keeper -> "start_or_recover_keeper"
  | Inspect_capacity_accounting -> "inspect_capacity_accounting"
  | Repair_failing_keeper -> "repair_failing_keeper"
  | Recover_context_overflow -> "recover_context_overflow"
  | Wait_for_compaction -> "wait_for_compaction"
  | Wait_for_handoff -> "wait_for_handoff"
  | Wait_for_keeper_drain -> "wait_for_keeper_drain"
  | Inspect_crashed_keeper -> "inspect_crashed_keeper"
  | Wait_for_keeper_restart -> "wait_for_keeper_restart"
  | Create_keeper_or_reassign_task -> "create_keeper_or_reassign_task"

let blocked_keeper_action = function
  | Durable_paused_autoboot_enabled -> Resume_or_leave_paused
  | Meta_read_error -> Repair_keeper_meta_file
  | Not_bootable -> Add_keeper_toml_or_disable_stale_autoboot_meta
  | Boot_failure Keeper_runtime.Missing_meta -> Run_keeper_up_or_recreate_meta
  | Boot_failure Keeper_runtime.Meta_read_error -> Repair_keeper_meta_file
  | Boot_failure Keeper_runtime.Config_invalid ->
      Repair_keeper_toml_config
  | Boot_failure Keeper_runtime.Sandbox_profile_required ->
      Add_sandbox_profile_to_keeper_toml
  | Boot_failure Keeper_runtime.Materialization_failed ->
      Inspect_keeper_autoboot_logs
  | Bootstrap_disabled -> Enable_keeper_bootstrap_or_start_manually
  | Phase Keeper_state_machine.Dead -> Inspect_dead_keeper_root_cause
  | Phase Keeper_state_machine.Stopped -> Restart_or_disable_stopped_keeper
  | Phase Keeper_state_machine.Paused -> Resume_or_leave_paused
  | Phase Keeper_state_machine.Offline -> Start_or_recover_keeper
  | Phase Keeper_state_machine.Running -> Inspect_capacity_accounting
  | Phase Keeper_state_machine.Failing -> Repair_failing_keeper
  | Phase Keeper_state_machine.Overflowed -> Recover_context_overflow
  | Phase Keeper_state_machine.Compacting -> Wait_for_compaction
  | Phase Keeper_state_machine.HandingOff -> Wait_for_handoff
  | Phase Keeper_state_machine.Draining -> Wait_for_keeper_drain
  | Phase Keeper_state_machine.Crashed -> Inspect_crashed_keeper
  | Phase Keeper_state_machine.Restarting -> Wait_for_keeper_restart
  | Not_registered -> Start_or_recover_keeper
  | Not_running -> Start_or_recover_keeper
  | No_keeper_binding -> Create_keeper_or_reassign_task
  | Unknown -> Inspect_keeper_autoboot_logs

let blocked_keeper_action_label reason =
  reason |> blocked_keeper_action |> blocked_keeper_operator_action_to_string

let blocked_keeper_operator_action = function
  | Phase
      ( Keeper_state_machine.Failing
      | Keeper_state_machine.Crashed
      | Keeper_state_machine.Restarting
      | Keeper_state_machine.Dead ) ->
      List.find_opt
        (fun (action : Operator_pending_confirm.available_action) ->
          String.equal action.action_type Operator_action_constants.keeper_recover)
        Operator_pending_confirm.available_actions
  | Durable_paused_autoboot_enabled
  | Meta_read_error
  | Not_bootable
  | Boot_failure _
  | Bootstrap_disabled
  | Phase
      ( Keeper_state_machine.Offline
      | Keeper_state_machine.Running
      | Keeper_state_machine.Overflowed
      | Keeper_state_machine.Compacting
      | Keeper_state_machine.HandingOff
      | Keeper_state_machine.Draining
      | Keeper_state_machine.Paused
      | Keeper_state_machine.Stopped )
  | Not_registered
  | Not_running
  | No_keeper_binding
  | Unknown ->
      None

let blocked_keeper_operator_action_fields reason =
  match blocked_keeper_operator_action reason with
  | None ->
      [
        ("operator_action_type", `Null);
        ("operator_tool_name", `Null);
        ("operator_action_confirm_required", `Null);
      ]
  | Some action ->
      [
        ("operator_action_type", `String action.action_type);
        ("operator_tool_name", `String action.tool_name);
        ("operator_action_confirm_required", `Bool action.confirm_required);
      ]

let latest_crash_log_reason crash_log =
  let latest =
    List.fold_left
      (fun acc (ts, reason) ->
        let reason = String.trim reason in
        if String.equal reason "" then acc
        else
          match acc with
          | None -> Some (ts, reason)
          | Some (latest_ts, _) when ts > latest_ts -> Some (ts, reason)
          | Some _ -> acc)
      None
      crash_log
  in
  Option.map snd latest

let phase_supports_crash_log_failure_reason = function
  | Keeper_state_machine.Failing
  | Keeper_state_machine.Crashed
  | Keeper_state_machine.Dead ->
      true
  | Keeper_state_machine.Offline
  | Keeper_state_machine.Running
  | Keeper_state_machine.Overflowed
  | Keeper_state_machine.Compacting
  | Keeper_state_machine.HandingOff
  | Keeper_state_machine.Draining
  | Keeper_state_machine.Paused
  | Keeper_state_machine.Stopped
  | Keeper_state_machine.Restarting ->
      false

let active_task_owner_fiber_scan_semantics =
  "reports keeper-shaped active task owners without executable keeper fibers; \
   disabled keepers are excluded; matching keeper rows can degrade fleet \
   status; credentialed non-keeper client task owners are reported separately \
   as advisory rows"

let paused_keeper_last_blocker_json paused_keepers_json name =
  match paused_keepers_json with
  | `Assoc fields -> (
    match List.assoc_opt "details" fields with
    | Some (`List details) ->
      (match
         details
         |> List.find_map (function
           | `Assoc detail_fields
             when (match List.assoc_opt "name" detail_fields with
                   | Some (`String detail_name) -> String.equal detail_name name
                   | _ -> false) ->
               (match List.assoc_opt "last_blocker" detail_fields with
                | Some last_blocker -> Some last_blocker
                | None -> Some `Null)
           | _ -> None)
       with
       | Some last_blocker -> last_blocker
       | None -> `Null)
    | Some _ | None -> `Null)
  | _ -> `Null

(* Maximum length of the diagnostic string surfaced on public [/health]
   fields via [public_health_diagnostic_preview]. Operational limit (UX
   contract for operator-facing snippets), not a security bound — full
   redaction happens upstream through [Keeper_secret_redaction] and
   [Observability_redact.redact_text]; this only truncates the tail. *)
let max_public_diagnostic_preview_len = 240

let public_health_diagnostic_preview ?base_path ~keeper_name text =
  let text =
    match base_path with
    | None -> text
    | Some base_path ->
        let base_path = String.trim base_path in
        if base_path = "" then text
        else
          String_util.replace_substring
            ~needle:base_path
            ~by:"[REDACTED_PATH]"
            text
  in
  let text =
    match base_path with
    | None -> Observability_redact.redact_text text
    | Some base_path ->
        let redaction = Keeper_secret_redaction.snapshot ~base_path ~keeper_name in
        Keeper_secret_redaction.redact_text redaction text
  in
  Observability_redact.redact_preview ~max_len:max_public_diagnostic_preview_len text

let blocked_keeper_detail_json
    ?base_path
    ?(last_blocker = `Null)
    ?phase_detail
    ~keeper_bootstrap_enabled
    ~bootable_set
    ~capacity_set
    ~paused_set
    ~read_error_set
    name =
  let is_paused = String_set.mem name paused_set in
  let is_bootable = String_set.mem name bootable_set in
  let is_capacity = String_set.mem name capacity_set in
  let has_read_error = String_set.mem name read_error_set in
  let phase_from_detail =
    Option.bind
      (Option.map (fun detail -> detail.phase) phase_detail)
      Keeper_state_machine.phase_of_string
  in
  let last_failure =
    match base_path with
    | None -> None
    | Some base_path -> Keeper_runtime.boot_meta_failure_for ~base_path ~name
  in
  let registry_entry =
    match base_path with
    | None -> None
    | Some base_path -> Keeper_registry.get ~base_path name
  in
  let diagnostic_preview =
    public_health_diagnostic_preview ?base_path ~keeper_name:name
  in
  let registry_phase =
    match registry_entry with
    | Some (entry : Keeper_registry.registry_entry) -> Some entry.phase
    | None -> None
  in
  let phase =
    match registry_phase with
    | Some _ as phase -> phase
    | None -> phase_from_detail
  in
  let phase_name =
    match phase with
    | Some phase -> Some (Keeper_state_machine.phase_to_string phase)
    | None -> Option.map (fun detail -> detail.phase) phase_detail
  in
  let registry_last_failure_reason =
    let raw =
      match registry_entry with
      | Some { Keeper_registry.last_failure_reason = Some reason; _ } ->
          Some (Keeper_registry.failure_reason_to_string reason)
      | Some { Keeper_registry.last_failure_reason = None; crash_log; _ }
        when Option.value
               ~default:false
               (Option.map phase_supports_crash_log_failure_reason phase) ->
          latest_crash_log_reason crash_log
      | Some { Keeper_registry.last_failure_reason = None; _ } | None -> None
    in
    Option.map diagnostic_preview raw
  in
  let reason =
    if is_paused then Durable_paused_autoboot_enabled
    else if has_read_error then Meta_read_error
    else
      match last_failure with
      | Some failure -> Boot_failure failure.Keeper_runtime.cause
      | None ->
          if not is_bootable then Not_bootable
          else if not is_capacity then
            (match phase with
             | Some phase -> Phase phase
             | None ->
               if keeper_bootstrap_enabled then Not_registered
               else Bootstrap_disabled)
          else Unknown
  in
  let terminal_phase_field =
    match phase with
    | Some phase -> [ ("terminal_phase", `Bool (Keeper_state_machine.is_terminal phase)) ]
    | None -> []
  in
  let keeper_bootstrap_blocker =
    match reason with
    | Bootstrap_disabled -> Some "keeper_bootstrap_disabled"
    | _ -> None
  in
  let last_failure_fields =
    match last_failure with
    | None ->
        [
          ("last_bootstrap_reason", `Null);
          ("last_bootstrap_error", `Null);
          ("last_bootstrap_config_error", `Null);
          ("last_bootstrap_recorded_at", `Null);
        ]
    | Some failure ->
        [
          ( "last_bootstrap_reason"
          , `String
              (Keeper_runtime.boot_meta_failure_cause_label
                 failure.Keeper_runtime.cause) );
          ("last_bootstrap_error", `String failure.Keeper_runtime.error);
          ( "last_bootstrap_config_error"
          , Json_util.option_to_yojson
              (fun error ->
                 Keeper_types_profile.keeper_toml_config_error_of_load_error
                   ~keeper_name:name
                   error
                 |> Keeper_types_profile.keeper_toml_config_error_to_json)
              failure.Keeper_runtime.config_error );
          ("last_bootstrap_recorded_at", `String failure.Keeper_runtime.recorded_at);
        ]
  in
  let phase_detail_fields =
    match phase_detail with
    | None ->
        [
          ( "last_failure_reason"
          , Json_util.string_opt_to_json registry_last_failure_reason );
          ("last_error", `Null);
          ("restart_count", `Null);
          ("dead_since_ts", `Null);
          ("latest_crash_at", `Null);
          ("latest_crash_reason", `Null);
        ]
    | Some detail ->
        let last_failure_reason =
          match detail.last_failure_reason with
          | Some reason -> Some (diagnostic_preview reason)
          | None -> registry_last_failure_reason
        in
        [
          ( "last_failure_reason"
          , Json_util.string_opt_to_json last_failure_reason );
          ("last_error", Json_util.string_opt_to_json (Option.map diagnostic_preview detail.last_error));
          ("restart_count", `Int detail.restart_count);
          ("dead_since_ts", Json_util.float_opt_to_json detail.dead_since_ts);
          ("latest_crash_at", Json_util.float_opt_to_json detail.latest_crash_at);
          ( "latest_crash_reason"
          , Json_util.string_opt_to_json
              (Option.map diagnostic_preview detail.latest_crash_reason) );
        ]
  in
  `Assoc
    ([
       ("keeper", `String name);
       ("name", `String name);
       ("reason", `String (blocked_keeper_reason_label reason));
       ("action", `String (blocked_keeper_action_label reason));
       ("phase", Json_util.string_opt_to_json phase_name);
       ("last_blocker", last_blocker);
       ("bootable", `Bool is_bootable);
       ("reaction_capacity", `Bool is_capacity);
       ("paused", `Bool is_paused);
       ("meta_read_error", `Bool has_read_error);
       ("keeper_bootstrap_enabled", `Bool keeper_bootstrap_enabled);
       ( "keeper_bootstrap_blocker"
       , Json_util.string_opt_to_json keeper_bootstrap_blocker );
     ]
     @ terminal_phase_field
     @ blocked_keeper_operator_action_fields reason
     @ last_failure_fields
     @ phase_detail_fields)

type active_task_owner_without_executable_fiber = {
  keeper_name : string option;
  agent_name : string;
  task_id : string;
  task_status : string;
}

type non_keeper_active_task_owner = {
  agent_name : string;
  task_id : string;
  task_status : string;
}

type active_task_owner_fiber_scan = {
  active_task_owner_without_executable_fibers :
    active_task_owner_without_executable_fiber list;
  non_keeper_active_task_owners : non_keeper_active_task_owner list;
  active_task_owner_scan_errors : (string * string) list;
}

let empty_active_task_owner_fiber_scan =
  {
    active_task_owner_without_executable_fibers = [];
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

let compare_non_keeper_active_task_owner left right =
  let cmp = String.compare left.agent_name right.agent_name in
  if cmp <> 0 then cmp else String.compare left.task_id right.task_id

let active_task_assignment (task : Masc_domain.task) =
  Masc_domain.task_assignee_of_status task.task_status
  |> Option.map (fun assignee ->
         (assignee, Workspace_task_schedule.task_status_label task.task_status))

let active_task_owner_without_executable_fiber_json row =
  let action =
    match row.keeper_name with
    | Some _ -> blocked_keeper_action_label Not_running
    | None -> blocked_keeper_action_label No_keeper_binding
  in
  `Assoc
    [
      ("keeper", Json_util.string_opt_to_json row.keeper_name);
      (* Legacy alias retained for existing fleet-safety consumers. *)
      ("name", Json_util.string_opt_to_json row.keeper_name);
      ("agent_name", `String row.agent_name);
      ("task_id", `String row.task_id);
      ("task_status", `String row.task_status);
      ("executable", `Bool false);
      ("action", `String action);
    ]

let non_keeper_active_task_owner_json row =
  `Assoc
    [
      ("agent_name", `String row.agent_name);
      ("task_id", `String row.task_id);
      ("task_status", `String row.task_status);
      ("owner_kind", `String "non_keeper_client");
      ("fleet_blocking", `Bool false);
      ("action", `String "track_client_task_or_release_when_done");
    ]

type keeper_agent_binding_scan = {
  enabled_agent_bindings : (string * string) list;
  disabled_agent_names : string list;
  binding_read_errors : (string * string) list;
}

let empty_keeper_agent_binding_scan =
  { enabled_agent_bindings = []; disabled_agent_names = []; binding_read_errors = [] }

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
                 enabled_agent_bindings =
                   (meta.agent_name, meta.name) :: scan.enabled_agent_bindings;
               }
             else
               {
                 scan with
                 disabled_agent_names = meta.agent_name :: scan.disabled_agent_names;
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
    enabled_agent_bindings =
      List.sort_uniq compare_string_pair scan.enabled_agent_bindings;
    disabled_agent_names = sorted_unique_strings scan.disabled_agent_names;
    binding_read_errors =
      List.sort_uniq compare_string_pair scan.binding_read_errors;
  }

let keeper_names_for_agent agent_bindings assignee =
  agent_bindings
  |> List.filter_map (fun (agent_name, keeper_name) ->
       if String.equal agent_name assignee then Some keeper_name else None)
  |> sorted_unique_strings

let is_credentialed_external_client config assignee =
  (not (Keeper_identity.is_keeper_principal_agent_name assignee))
  &&
  match Auth.load_credential config.Workspace_utils_backend_setup.base_path assignee with
  | Some _ -> true
  | None -> false

let active_task_owner_fiber_scan config ~executable_names =
  let executable_set = string_set_of_list executable_names in
  let binding_scan = keeper_agent_bindings config in
  let agent_bindings = binding_scan.enabled_agent_bindings in
  let meta_read_errors = binding_scan.binding_read_errors in
  match Workspace.read_backlog_r config with
  | Error err ->
      {
        active_task_owner_without_executable_fibers = [];
        non_keeper_active_task_owners = [];
        active_task_owner_scan_errors =
          ("backlog", err) :: meta_read_errors;
      }
  | Ok backlog ->
      let blocking_rows, non_keeper_rows =
        backlog.tasks
        |> List.fold_left
             (fun (blocking_rows, non_keeper_rows) task ->
             match active_task_assignment task with
             | None -> (blocking_rows, non_keeper_rows)
             | Some (assignee, task_status) ->
                 let keeper_names = keeper_names_for_agent agent_bindings assignee in
                 if
                   List.exists
                     (fun keeper_name -> String_set.mem keeper_name executable_set)
                     keeper_names
                 then (blocking_rows, non_keeper_rows)
                 else (
                   match keeper_names with
                   | []
                     when is_credentialed_external_client config assignee ->
                       ( blocking_rows
                       , {
                           agent_name = assignee;
                           task_id = task.id;
                           task_status;
                         }
                         :: non_keeper_rows )
                   | []
                     when List.mem assignee binding_scan.disabled_agent_names
                          || meta_read_errors <> [] ->
                       (blocking_rows, non_keeper_rows)
                   | [] ->
                       ( {
                           keeper_name = None;
                           agent_name = assignee;
                           task_id = task.id;
                           task_status;
                         }
                         :: blocking_rows
                       , non_keeper_rows )
                   | keeper_names ->
                       ( keeper_names
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
             ([], [])
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
        non_keeper_active_task_owners = non_keeper_rows;
        active_task_owner_scan_errors = meta_read_errors;
      }

let active_task_owner_blocked_name row =
  match row.keeper_name with
  | Some keeper_name -> keeper_name
  | None -> row.agent_name

let active_task_owner_blocked_detail_json row =
  let reason =
    match row.keeper_name with
    | Some _ -> Not_running
    | None -> No_keeper_binding
  in
  `Assoc
    [
      ("keeper", Json_util.string_opt_to_json row.keeper_name);
      ("name", Json_util.string_opt_to_json row.keeper_name);
      ("agent_name", `String row.agent_name);
      ("task_id", `String row.task_id);
      ("task_status", `String row.task_status);
      ("reason", `String (blocked_keeper_reason_label reason));
      ("action", `String (blocked_keeper_action_label reason));
    ]

let keeper_fleet_safety_health_json
    ?bootable_names:bootable_names_override
    ?autoboot_scan:autoboot_scan_override
    ?phase_snapshot
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
  let executable_names =
    match phase_snapshot with
    | Some snapshot -> snapshot.executable_names
    | None -> fallback_running_names
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
  let active_task_owner_blocked_names =
    active_task_owner_scan.active_task_owner_without_executable_fibers
    |> List.map active_task_owner_blocked_name
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
  let phase_details =
    match phase_snapshot with
    | Some snapshot -> snapshot.phase_details
    | None -> []
  in
  let phase_detail name = List.assoc_opt name phase_details in
  let minimum_running_fibers =
    if target_count <= 1 then target_count else 2
  in
  let no_running_fibers = target_count > 0 && phase_counts.running = 0 in
  let no_executable_keeper_fibers = target_count > 0 && phase_counts.executable = 0 in
  let low_running_fiber_margin =
    target_count > 1 && phase_counts.running < minimum_running_fibers
  in
  (* Recovering lanes are deliberately capacity-bearing for the fleet verdict:
     [Failing] remains executable in the FSM and is eligible for
     heartbeat-driven recovery. Keep that policy in one value so
     the advertised effective count and its derived shortfall cannot diverge.
     Actual healthy execution remains available separately as
     [healthy_running_keeper_fiber_count]. *)
  let effective_reaction_capacity_count =
    phase_counts.running + phase_counts.recovering
  in
  let reaction_capacity_shortfall_count =
    max 0 (target_count - effective_reaction_capacity_count)
  in
  let reaction_capacity_below_target =
    target_count > 0 && reaction_capacity_shortfall_count > 0
  in
  let keeper_bootstrap_blocked =
    (not keeper_bootstrap_enabled)
    && (no_executable_keeper_fibers
       || no_running_fibers
       || low_running_fiber_margin
       || reaction_capacity_below_target)
  in
  let active_task_owner_is_selected_blocker =
    active_task_owner_without_executable_fiber
    && not
         (no_executable_keeper_fibers
          || no_running_fibers
          || low_running_fiber_margin
          || reaction_capacity_below_target
          || keeper_bootstrap_blocked)
  in
  let executable_reaction_capacity_shortfall_count =
    max 0 (target_count - phase_counts.executable)
  in
  let executable_reaction_capacity_below_target =
    target_count > 0 && executable_reaction_capacity_shortfall_count > 0
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
  let names_not_in active_names =
    let active_names = sorted_unique_strings active_names in
    autoboot_scan.autoboot_names
    |> List.filter (fun name -> not (List.mem name active_names))
    |> sorted_unique_strings
  in
  let status =
    if no_executable_keeper_fibers then "blocked"
    else if no_running_fibers then "degraded"
    else if low_running_fiber_margin then "degraded"
    else if reaction_capacity_below_target then "degraded"
    else if active_task_owner_without_executable_fiber then "degraded"
    else "ok"
  in
  let blocked_keeper_names =
    if no_executable_keeper_fibers then names_not_in executable_names
    else if no_running_fibers || low_running_fiber_margin || reaction_capacity_below_target
    then names_not_in (running_names @ recovering_names)
    else if active_task_owner_is_selected_blocker then active_task_owner_blocked_names
    else []
  in
  (* Counts unique blocked keeper NAMES, not capacity shortfall. This
     intentionally differs from pre-#22388 behavior, which reported
     [executable_reaction_capacity_shortfall_count]; see the PR summary.
     Consumers should read this as "number of named blockers" rather than
     missing capacity slots. *)
  let blocked_count = List.length blocked_keeper_names in
  let active_capacity_names =
    if no_executable_keeper_fibers then executable_names
    else if no_running_fibers || low_running_fiber_margin || reaction_capacity_below_target
    then running_names @ recovering_names
    else running_names
  in
  let bootable_set = string_set_of_list bootable_names in
  let capacity_set = string_set_of_list active_capacity_names in
  let paused_set =
    paused_keepers_json
    |> json_string_list_field "autoboot_enabled_names"
    |> string_set_of_list
  in
  let read_error_set =
    autoboot_scan.read_errors |> List.map fst |> string_set_of_list
  in
  let blocked_keeper_reasons =
    if active_task_owner_is_selected_blocker then
      active_task_owner_scan.active_task_owner_without_executable_fibers
      |> List.map active_task_owner_blocked_detail_json
    else
      blocked_keeper_names
      |> List.map
           (fun name ->
             blocked_keeper_detail_json
               ?base_path:runtime_base_path
               ~last_blocker:(paused_keeper_last_blocker_json paused_keepers_json name)
               ?phase_detail:(phase_detail name)
               ~keeper_bootstrap_enabled
               ~bootable_set
               ~capacity_set
               ~paused_set
               ~read_error_set
               name)
  in
  let blocker =
    if keeper_bootstrap_blocked then Some "keeper_bootstrap_disabled"
    else if no_executable_keeper_fibers then Some "no_executable_keeper_fibers"
    else if no_running_fibers then Some "no_healthy_running_keeper_fibers"
    else if low_running_fiber_margin then Some "low_running_fiber_margin"
    else if reaction_capacity_below_target then Some "reaction_capacity_below_target"
    else if active_task_owner_without_executable_fiber
    then Some "active_task_owner_without_executable_fiber"
    else if paused_autoboot_count > 0 then Some "durable_paused_autoboot_enabled"
    else None
  in
  `Assoc
    [ "status", `String status
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
    ; "autoboot_enabled_read_error_count", `Int (List.length autoboot_scan.read_errors)
    ; ( "autoboot_enabled_read_errors"
      , `List
          (List.map
             (fun (keeper, error) ->
               `Assoc [ ("keeper", `String keeper); ("error", `String error) ])
             autoboot_scan.read_errors) )
    ; "running_keeper_fiber_count", `Int phase_counts.running
    ; "healthy_running_keeper_fiber_count", `Int phase_counts.running
    ; "running_keeper_names", `List (List.map (fun name -> `String name) running_names)
    ; "failing_keeper_fiber_count", `Int phase_counts.failing
    ; "recovering_keeper_fiber_count", `Int phase_counts.recovering
    ; ( "recovering_keeper_names"
      , `List (List.map (fun name -> `String name) recovering_names) )
    ; "executable_keeper_fiber_count", `Int phase_counts.executable
    ; ( "executable_keeper_names"
      , `List (List.map (fun name -> `String name) executable_names) )
    ; "effective_reaction_capacity_count", `Int effective_reaction_capacity_count
    ; "executable_reaction_capacity_count", `Int phase_counts.executable
    ; "target_reaction_capacity_count", `Int target_count
    ; "minimum_running_fibers", `Int minimum_running_fibers
    ; "no_running_fibers", `Bool no_running_fibers
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
    ; "low_running_fiber_margin", `Bool low_running_fiber_margin
    ; "reaction_capacity_below_target", `Bool reaction_capacity_below_target
    ; "reaction_capacity_shortfall_count", `Int reaction_capacity_shortfall_count
    ; ( "executable_reaction_capacity_below_target"
      , `Bool executable_reaction_capacity_below_target )
    ; ( "executable_reaction_capacity_shortfall_count"
      , `Int executable_reaction_capacity_shortfall_count )
    ; "paused_keeper_count", `Int paused_total_count
    ; "paused_autoboot_enabled_keeper_count", `Int paused_autoboot_count
    ; "blocked_keeper_count", `Int blocked_count
    ; "blocked_count", `Int blocked_count
    ; ( "blocked_count_semantics"
      , `String "number of named keepers currently listed in blocked_keeper_names" )
    ; "blocked_keepers", `Int blocked_count
    ; ( "blocked_keepers_semantics"
      , `String "legacy alias for blocked_keeper_count" )
    ; ( "blocked_keeper_names"
      , `List (List.map (fun name -> `String name) blocked_keeper_names) )
    ; "blocked_keeper_reasons", `List blocked_keeper_reasons
    ; ( "operator_action_required"
      , `Bool
          (no_executable_keeper_fibers
           || no_running_fibers
           || low_running_fiber_margin
           || reaction_capacity_below_target
           || keeper_bootstrap_blocked
           || active_task_owner_without_executable_fiber) )
    ]
