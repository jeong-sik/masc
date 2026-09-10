(* The rollup for [/health?full=1]. See the .mli for what it reads and what
   it cannot. *)

let cached_field_names =
  [
    "feature_flags";
    "overall_status";
    "operator_action_required";
    "operator_action_reasons";
    "keeper_fibers";
    "fd_observation";
    "fd_accountant";
    "disk_observation";
    "keeper_fleet_safety";
    "keeper_identity_drift";
    "publication_recovery_activation";
    "keeper_reaction_ledger";
    "keeper_owner";
    "keeper_board_event_collection";
    "keeper_event_queue";
    "keeper_terminal_effect_policy";
    "keeper_observability_artifacts";
    "paused_keepers";
    "keeper_config_error_count";
    "keeper_config_errors";
    "keeper_config_probe_error";
    "keeper_config_unknown_key_count";
    "keeper_config_unknown_keys";
    "keeper_config_schema_status";
    "keeper_config_schema_blocking";
    "keeper_config_schema_terminal_reason";
    "keeper_config_operator_action_required";
    "lazy_task_boot_guard_fires_total";
  ]
;;

let is_cached name = List.exists (String.equal name) cached_field_names

(* The reason an operator sees when a section reports no [status_reasons]. The
   three keys are the ones sections use for it -- [blocker] on fleet safety,
   [terminal_reason] on identity drift and startup degradation, [reason] on
   publication recovery -- and the status string is the last resort. Naming
   them once here replaced a per-section table of fallbacks, which had an
   entry for three sections and [None] for the rest. *)
let fallback_reason json component_status =
  let rec first = function
    | [] -> component_status
    | key :: rest ->
      (match Json_util.assoc_string_opt key json with
       | Some value when String.trim value <> "" -> value
       | Some _ | None -> first rest)
  in
  first [ "blocker"; "terminal_reason"; "reason" ]
;;

let operator_summary ~sections ~runtime_startup_degradation
    ~keeper_config_schema_status ~keeper_config_schema_blocking
    ~keeper_config_schema_terminal_reason ~keeper_config_operator_action_required
    ~lazy_task_boot_guard_fires_total
  =
  let status = ref "ok" in
  let reasons = ref [] in
  let note_status component json =
    match Json_util.assoc_string_opt "status" json with
    | None -> ()
    | Some component_status ->
      (match Health_status.of_string_opt component_status with
       | None -> ()
       | Some parsed_component_status ->
         status := Health_status.max_string !status component_status;
         let action_required =
           match Json_util.assoc_bool_opt "operator_action_required" json with
           | Some value -> value
           | None -> false
         in
         if
           action_required
           || Health_status.requires_operator_action parsed_component_status
           || Health_status.equal parsed_component_status Health_status.Unknown
         then begin
           let component_reasons =
             match Json_util.json_string_list_member "status_reasons" json with
             | [] -> [ fallback_reason json component_status ]
             | values -> values
           in
           let prefixed_reasons =
             List.map
               (fun reason -> Printf.sprintf "%s:%s" component reason)
               component_reasons
           in
           reasons := List.rev_append prefixed_reasons !reasons
         end)
  in
  List.iter
    (fun (component, json) -> if is_cached component then note_status component json)
    sections;
  (* Rolled up and not cached: see the .mli. *)
  note_status "runtime_startup_degradation" runtime_startup_degradation;
  status := Health_status.max_string !status keeper_config_schema_status;
  if keeper_config_operator_action_required || keeper_config_schema_blocking
  then
    reasons :=
      Printf.sprintf "keeper_config_schema:%s" keeper_config_schema_terminal_reason
      :: !reasons;
  if lazy_task_boot_guard_fires_total > 0
  then begin
    status := Health_status.max_string !status "degraded";
    reasons :=
      Printf.sprintf
        "lazy_task_boot_guard_fires_total:%d"
        lazy_task_boot_guard_fires_total
      :: !reasons
  end;
  let reasons = List.rev !reasons in
  (!status, reasons <> [], reasons)
;;
