(** Runtime-lens tool surface extraction and gap detection.

    Split from {!Server_dashboard_http_keeper_api}; this module derives
    runtime-lens diagnostic gaps from the manifest scan and summary JSONs. *)

open Server_dashboard_http_keeper_api_types
open Server_dashboard_http_keeper_runtime_manifest_scan
open Server_dashboard_http_keeper_runtime_lens_swimlane

let first_non_empty_string_list values =
  match List.find_opt (fun values -> values <> []) values with
  | Some values -> values
  | None -> []

let string_contains ~needle value =
  let value = String.lowercase_ascii value in
  let needle = String.lowercase_ascii needle in
  let value_len = String.length value in
  let needle_len = String.length needle in
  if needle_len = 0 then true
  else
    let rec loop idx =
      idx + needle_len <= value_len
      && (String.equal (String.sub value idx needle_len) needle || loop (idx + 1))
    in
    loop 0

let runtime_lens_tool_surface_parts scan =
  (* sound-partial: allow absent runtime-lens decisions as empty evidence while
     preserving explicit decision payloads when the scanner emits them. *)
  let tool_decision =
    match scan.latest_tool_surface_decision with
    | Some decision -> decision
    | None -> `Assoc []
  in
  (* sound-partial: allow absent lane decision as empty evidence. *)
  let lane_decision =
    match scan.latest_provider_lane_decision with
    | Some decision -> decision
    | None -> `Assoc []
  in
  let requested_tools =
    json_string_list_member "requested_tool_names" lane_decision
  in
  let required_tools =
    first_non_empty_string_list
      [
        json_string_list_member "required_tool_names" lane_decision;
        json_string_list_member "required_tool_names" tool_decision;
      ]
  in
  let materialized_tools =
    json_string_list_member "materialized_tool_names" lane_decision
  in
  let missing_required_tools =
    first_non_empty_string_list
      [
        json_string_list_member "missing_required_tool_names_after_lane"
          lane_decision;
        json_string_list_member "missing_required_tool_names" tool_decision;
      ]
  in
  ( tool_decision
  , lane_decision
  , requested_tools
  , required_tools
  , materialized_tools
  , missing_required_tools )

let runtime_lens_gaps ~terminal_event_present ~claim_scope ~config_drift scan =
  let ( _
      , _
      , _
      , required_tools
      , materialized_tools
      , missing_required_tools )
    =
    runtime_lens_tool_surface_parts scan
  in
  let has_tool_surface =
    runtime_manifest_scan_event_count scan
      Keeper_runtime_manifest.Tool_surface_selected
    > 0
  in
  let has_provider_lane =
    runtime_manifest_scan_event_count scan
      Keeper_runtime_manifest.Provider_lane_resolved
    > 0
  in
  let has_context_delta =
    scan.context_injected_count > 0
    || scan.context_compacted_event_count > 0
    || scan.event_bus_count > 0
  in
  let claim_status = json_string_member_opt "status" claim_scope in
  let claim_mode = json_string_member_opt "mode" claim_scope in
  let claim_excluded_count = json_int_member_opt "excluded_count" claim_scope in
  let cascade_override =
    Option.value
      (json_bool_member_opt "cascade_override" config_drift)
      ~default:false
  in
  let pre_dispatch_reason =
    match scan.latest_pre_dispatch_blocked_row with
    | Some row ->
      first_string_opt
        [ json_string_member_opt "reason" row.Keeper_runtime_manifest.decision
        ; json_string_member_opt "terminal_reason_code" row.Keeper_runtime_manifest.decision
        ; Some row.Keeper_runtime_manifest.status
        ]
    | None -> None
  in
  let add gap gaps = gap :: gaps in
  []
  |> (fun gaps ->
       if scan.total_rows > 0 && not terminal_event_present then
         add
           { code = "missing_turn_finished"
           ; severity = "warn"
           ; lane = "keeper"
           ; detail = Some "manifest has rows but no turn_finished row"
           }
           gaps
       else gaps)
  |> (fun gaps ->
       match claim_status with
       | Some "no_eligible" ->
         add
           { code = "claim_scope_no_eligible"
           ; severity = "warn"
           ; lane = "keeper"
           ; detail =
               Some
                 (Printf.sprintf
                    "keeper_task_claim found no eligible tasks in mode=%s excluded=%s"
                    (Option.value claim_mode ~default:"unknown")
                    (match claim_excluded_count with
                     | Some value -> string_of_int value
                     | None -> "unknown"))
           }
           gaps
       | _ -> gaps)
  |> (fun gaps ->
       match claim_status, claim_mode with
       | Some "no_eligible", Some "active_goal_ids" ->
         add
           { code = "claim_scope_global_backlog_outside_keeper"
           ; severity = "warn"
           ; lane = "keeper"
           ; detail =
               Some
                 "active_goal_ids scope found no eligible work; global backlog may be outside this keeper or blocked by policy"
           }
           gaps
       | _ -> gaps)
  |> (fun gaps ->
       if cascade_override then
         add
           { code = "keeper_cascade_override_drift"
           ; severity = "warn"
           ; lane = "masc_policy_cascade"
           ; detail =
               Some
                 (Printf.sprintf "default=%s live=%s"
                    (Option.value
                       (json_string_member_opt "default_cascade_name" config_drift)
                       ~default:"unknown")
                    (Option.value
                       (json_string_member_opt "live_cascade_name" config_drift)
                       ~default:"unknown"))
           }
           gaps
       else gaps)
  |> (fun gaps ->
       match pre_dispatch_reason with
       | Some reason when string_contains ~needle:"no_tool_capable_provider" reason ->
         add
           { code = "route_tool_capability_gap"
           ; severity = "bad"
           ; lane = "masc_policy_cascade"
           ; detail = Some "pre-dispatch blocked because route cannot materialize required tools"
           }
           gaps
       | _ -> gaps)
  |> (fun gaps ->
       if missing_required_tools <> [] then
         add
           { code = "required_tool_not_materialized"
           ; severity = "bad"
           ; lane = "tool_runtime"
           ; detail =
               Some
                 (Printf.sprintf "missing required tools: %s"
                    (String.concat ", " missing_required_tools))
           }
           gaps
       else gaps)
  |> (fun gaps ->
       if (has_tool_surface || scan.provider_started_count > 0)
          && not has_provider_lane
       then
         add
           { code = "provider_lane_unresolved"
           ; severity = "bad"
           ; lane = "masc_policy_cascade"
           ; detail = Some "tool surface/provider attempt exists without provider_lane_resolved"
           }
           gaps
       else gaps)
  |> (fun gaps ->
       if (has_tool_surface || scan.provider_started_count > 0)
          && not has_context_delta
       then
         add
           { code = "context_delta_missing"
           ; severity = "warn"
           ; lane = "memory_context"
           ; detail = Some "provider turn has no context or event-bus delta rows"
           }
           gaps
       else gaps)
  |> (fun gaps ->
       if scan.memory_injected_count > 0 && scan.memory_flushed_count = 0 then
         add
           { code = "memory_flush_missing"
           ; severity = "warn"
           ; lane = "memory_context"
           ; detail = Some "memory was injected but no memory_flushed row was recorded"
           }
           gaps
       else gaps)
  |> (fun gaps ->
       if required_tools <> [] && materialized_tools = []
          && missing_required_tools = []
       then
         add
           { code = "provider_lane_unresolved"
           ; severity = "warn"
           ; lane = "masc_policy_cascade"
           ; detail = Some "required tools exist but provider lane materialization is unknown"
           }
           gaps
       else gaps)
  |> List.rev
