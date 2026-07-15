(** Runtime-lens gap detection.

    Split from {!Server_dashboard_http_keeper_api}; this module derives
    runtime-lens diagnostic gaps from the manifest scan and summary JSONs. *)

open Server_dashboard_http_keeper_api_types
open Server_dashboard_http_keeper_runtime_manifest_scan
open Server_dashboard_http_keeper_runtime_lens_swimlane

let runtime_lens_gaps ~terminal_event_present ~claim_scope ~config_drift scan =
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
  let claim_status = Json_util.get_string claim_scope "status" in
  let claim_mode = Json_util.get_string claim_scope "mode" in
  let claim_excluded_count = Json_util.get_int claim_scope "excluded_count" in
  let runtime_override =
    Option.value
      (Json_util.get_bool config_drift "runtime_override")
      ~default:false
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
       if runtime_override then
         add
           { code = "keeper_runtime_override_drift"
           ; severity = "warn"
           ; lane = "masc_policy_runtime"
           ; detail =
               Some
                 (Printf.sprintf "default=%s live=%s"
                    (Option.value
                       (Json_util.get_string config_drift "default_runtime_id")
                       ~default:"unknown")
                    (Option.value
                       (Json_util.get_string config_drift "live_runtime_id")
                       ~default:"unknown"))
           }
           gaps
       else gaps)
  |> (fun gaps ->
       if scan.provider_started_count > 0 && not has_provider_lane
       then
         add
           { code = "provider_lane_unresolved"
           ; severity = "bad"
           ; lane = "masc_policy_runtime"
           ; detail = Some "provider attempt exists without provider_lane_resolved"
           }
           gaps
       else gaps)
  |> (fun gaps ->
       if scan.provider_started_count > 0 && not has_context_delta
       then
         add
           { code = "context_delta_missing"
           ; severity = "warn"
           ; lane = "memory_context"
           ; detail = Some "provider turn has no context or event-bus delta rows"
           }
           gaps
       else gaps)
  |> List.rev
  |> fun gaps ->
  let gaps =
    (* F8: lane mandatory event set gaps.
       For each lane with a defined policy, emit a gap if any mandatory event
       is missing while the lane has at least one event (proving activity). *)
    Server_dashboard_http_keeper_runtime_lens_swimlane.lane_policies
    |> List.fold_left
         (fun acc policy ->
            let lane = policy.Server_dashboard_http_keeper_runtime_lens_swimlane.lane in
            let has_any_event_in_lane =
              List.exists
                (fun event ->
                   String.equal
                     (Server_dashboard_http_keeper_runtime_lens_swimlane.event_lane
                        event)
                     lane
                   &&
                   Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan_event_count
                     scan event > 0)
                Keeper_runtime_manifest.all_event_kinds
            in
            if not has_any_event_in_lane then acc
            else if scan.has_terminal then acc
            else
              let missing =
                List.filter
                  (fun event ->
                     Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan_event_count
                       scan event = 0)
                  policy.mandatory_events
              in
              match missing with
              | [] -> acc
              | _ ->
                let missing_codes =
                  List.map Keeper_runtime_manifest.event_kind_to_string missing
                in
                { code = "lane_mandatory_event_missing"
                ; severity = "warn"
                ; lane
                ; detail =
                    Some
                      (Printf.sprintf "mandatory events missing: %s"
                         (String.concat ", " missing_codes))
                }
                :: acc)
         gaps
  in
  let gaps =
    gaps
    |> (fun gaps ->
         match scan.provider_terminal_row with
         | Some row when row.Keeper_runtime_manifest.links.receipt_path = None ->
           { code = "receipt_missing"
           ; severity = "warn"
           ; lane = "keeper"
           ; detail = Some "terminal event has no receipt_path link"
           }
           :: gaps
         | _ -> gaps)
    |> (fun gaps ->
         match scan.provider_terminal_row with
         | Some row when row.Keeper_runtime_manifest.links.checkpoint_path = None ->
           { code = "checkpoint_missing"
           ; severity = "warn"
           ; lane = "oas_agent"
           ; detail = Some "terminal event has no checkpoint_path link"
           }
           :: gaps
         | _ -> gaps)
    |> (fun gaps ->
         match scan.provider_terminal_row with
         | Some row when row.Keeper_runtime_manifest.links.tool_call_log_path = None ->
           { code = "artifact_link_missing"
           ; severity = "warn"
           ; lane = "tool_runtime"
           ; detail = Some "terminal event has no tool_call_log_path link"
           }
           :: gaps
         | _ -> gaps)
    |> (fun gaps ->
         (* P5: terminal vs complete proof separation.
            Turn_finished exists but a mandatory lane policy is not satisfied. *)
         if scan.has_terminal
         then
           let incomplete_lanes =
             Server_dashboard_http_keeper_runtime_lens_swimlane.lane_policies
             |> List.filter_map
                  (fun policy ->
                     let lane =
                       policy.Server_dashboard_http_keeper_runtime_lens_swimlane.lane
                     in
                     let missing =
                       List.filter
                         (fun event ->
                            Server_dashboard_http_keeper_runtime_manifest_scan
                              .runtime_manifest_scan_event_count
                              scan event
                            = 0)
                         policy.mandatory_events
                     in
                     match missing with
                     | [] -> None
                     | _ ->
                       let missing_codes =
                         List.map Keeper_runtime_manifest.event_kind_to_string missing
                       in
                       Some (lane, missing_codes))
           in
           match incomplete_lanes with
           | [] -> gaps
           | _ ->
             let detail =
               incomplete_lanes
               |> List.map
                    (fun (lane, codes) ->
                       Printf.sprintf "%s: %s" lane (String.concat ", " codes))
               |> String.concat "; "
             in
             { code = "turn_terminal_incomplete"
             ; severity = "warn"
             ; lane = "keeper"
             ; detail = Some detail
             }
             :: gaps
         else gaps)
    |> (fun gaps ->
         if scan.provider_started_count > 0
            && scan.event_bus_correlation_ids = []
            && scan.event_bus_run_ids = []
         then
           { code = "provider_oas_link_missing"
           ; severity = "warn"
           ; lane = "provider"
           ; detail =
               Some
                 "provider attempt started but no event_bus correlation or run_id links"
           }
           :: gaps
         else gaps)
    |> (fun gaps ->
         if scan.total_rows > 0
            && runtime_manifest_scan_event_count scan Keeper_runtime_manifest.Turn_started
               > 0
            && runtime_manifest_scan_event_count scan Keeper_runtime_manifest.Phase_gate_decided
               = 0
         then
           { code = "phase_gate_missing"
           ; severity = "warn"
           ; lane = "keeper"
           ; detail = Some "turn started but no phase_gate_decided event recorded"
           }
           :: gaps
         else gaps)
    |> (fun gaps ->
         if scan.total_rows > 0
            && runtime_manifest_scan_event_count scan Keeper_runtime_manifest.Turn_started
               > 0
            && runtime_manifest_scan_event_count scan Keeper_runtime_manifest.Runtime_routed
               = 0
         then
           { code = "runtime_decision_missing"
           ; severity = "warn"
           ; lane = "masc_policy_runtime"
           ; detail = Some "turn started but no runtime_routed event recorded"
           }
           :: gaps
         else gaps)
    |> (fun gaps ->
         if scan.provider_started_count > scan.provider_finished_count
         then
           { code = "provider_attempt_unclosed"
           ; severity = "bad"
           ; lane = "provider"
           ; detail =
               Some
                 (Printf.sprintf
                    "provider attempts started (%d) exceeds finished (%d)"
                    scan.provider_started_count
                    scan.provider_finished_count)
           }
           :: gaps
         else gaps)
    |> (fun gaps ->
         match scan.provider_terminal_row with
         | Some row ->
           let decision = row.Keeper_runtime_manifest.decision in
           (match Json_util.get_string decision "terminal_provider_kind" with
            | Some _ -> gaps
            | None ->
              { code = "provider_provenance_missing"
              ; severity = "warn"
              ; lane = "provider"
              ; detail = Some "terminal provider row lacks terminal_provider_kind"
              }
              :: gaps)
         | None -> gaps)
    |> (fun gaps ->
         match scan.latest_context_compacted_row with
         | Some row ->
           let decision = row.Keeper_runtime_manifest.decision in
           let clock_refs = Json_util.assoc_member_opt "clock_refs" decision in
           (match Option.bind clock_refs (fun cr -> Json_util.get_string cr "compaction_source") with
            | Some _ -> gaps
            | None ->
              { code = "compaction_source_missing"
              ; severity = "warn"
              ; lane = "memory_context"
              ; detail = Some "context_compacted row lacks compaction_source in clock_refs"
              }
              :: gaps)
         | None -> gaps)
    |> (fun gaps ->
         match scan.latest_context_injected_row with
         | Some row ->
           let decision = row.Keeper_runtime_manifest.decision in
           (match Json_util.get_string decision "context_digest" with
            | Some _ -> gaps
            | None ->
              { code = "context_digest_missing"
              ; severity = "warn"
              ; lane = "memory_context"
              ; detail = Some "context_injected row lacks context_digest"
              }
              :: gaps)
         | None -> gaps)
  in
  gaps
  @ Server_dashboard_http_keeper_runtime_lens_clock_groups.runtime_lens_clock_gaps
      scan
