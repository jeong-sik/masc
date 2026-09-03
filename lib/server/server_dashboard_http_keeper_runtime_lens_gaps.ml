(** Runtime-lens gap detection.

    Split from {!Server_dashboard_http_keeper_api}; this module derives
    runtime-lens diagnostic gaps from the manifest scan and summary JSONs. *)

open Server_dashboard_http_keeper_runtime_manifest_scan
open Server_dashboard_http_keeper_runtime_lens_swimlane

let runtime_lens_gaps ~terminal_event_present ~config_drift scan =
  let has_context_delta =
    scan.context_injected_count > 0 || scan.event_bus_count > 0
  in
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
       if scan.has_terminal && not has_context_delta
       then
         add
           { code = "context_delta_missing"
           ; severity = "warn"
           ; lane = "memory_context"
           ; detail = Some "turn finished with no context or event-bus delta rows"
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
    (* Only receipt_path is asserted on the terminal row. The other two links
       cannot carry a judgement there:

       - checkpoint_path is never written on a Turn_finished row. Both
         producers (keeper_agent_run_receipt.ml:250 and
         keeper_turn_helpers.ml:306) call [make] without ?checkpoint_path, so
         the field is null on 0 of 23,378 live rows and the gap would fire on
         every finished turn. Whether the turn saved a checkpoint at all is
         already asserted by the agent_core_agent lane policy, which names
         Checkpoint_saved as both mandatory and terminal.
       - tool_call_log_path is None exactly when the turn made no tool calls
         (keeper_agent_run_receipt.ml:232). That is the ordinary shape of a
         text-only turn — 9,305 of 23,378 live rows — not a gap.

       receipt_path is written unconditionally: [make] takes ~receipt_path as
       a required argument, and it is present on 23,378 of 23,378 live
       Turn_finished rows. The arm therefore holds today and reports a
       producer that stops writing it. *)
    |> (fun gaps ->
         match scan.terminal_row with
         | Some row when row.Keeper_runtime_manifest.links.receipt_path = None ->
           { code = "receipt_missing"
           ; severity = "warn"
           ; lane = "keeper"
           ; detail = Some "terminal event has no receipt_path link"
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
         if scan.has_terminal
            && scan.event_bus_correlation_ids = []
            && scan.event_bus_run_ids = []
         then
           { code = "agent_core_link_missing"
           ; severity = "warn"
           ; lane = "memory_context"
           ; detail =
               Some "turn finished with no event_bus correlation or run_id links"
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
