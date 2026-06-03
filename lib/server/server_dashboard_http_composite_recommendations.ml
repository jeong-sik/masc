include Server_dashboard_http_composite_claims

let fleet_fsm_action_payload ~keeper_name ~kind ~reason ~snapshot ~execution =
  `Assoc
    [ "source", `String "fleet_fsm"
    ; "kind", `String kind
    ; "keeper", `String keeper_name
    ; "reason", `String reason
    ; "phase", Json_util.string_opt_to_json (json_string "phase" snapshot)
    ; "turn_phase", Json_util.string_opt_to_json (json_string "turn_phase" snapshot)
    ; "execution", execution
    ]
;;

let fleet_fsm_message_payload ~keeper_name ~reason ~snapshot ~execution =
  let message =
    Printf.sprintf
      "Fleet FSM supervised resolve request for %s.\n\
       Reason: %s.\n\
       Inspect the latest runtime evidence, distinguish configuration/tool-contract \
       blockers from restartable runtime stalls, and reply with the safest next operator \
       action. Do not self-restart."
      keeper_name
      reason
  in
  match
    fleet_fsm_action_payload ~keeper_name ~kind:"diagnose" ~reason ~snapshot ~execution
  with
  | `Assoc fields ->
    `Assoc (fields @ [ "direct_reply", `Bool true; "message", `String message ])
  | other -> other
;;

let composite_recommended_actions_json ~keeper_name ~snapshot ~execution ~attention =
  let stale_long_enough = attention.cra_stale_long_enough in
  let idle_attention = attention.cra_idle_attention in
  let reason = Option.value ~default:"runtime_attention" attention.cra_reason in
  let make action_type severity reason suggested_payload =
    let action : Operator_digest_types.recommended_action =
      { action_type
      ; target_type = "keeper"
      ; target_id = Some keeper_name
      ; severity
      ; reason
      ; suggested_payload
      }
    in
    action
  in
  let probe action_reason =
    make
      "keeper_probe"
      Operator_digest_types.Sev_warn
      action_reason
      (fleet_fsm_action_payload ~keeper_name ~kind:"probe" ~reason ~snapshot ~execution)
  in
  let message action_reason =
    make
      "keeper_message"
      Operator_digest_types.Sev_warn
      action_reason
      (fleet_fsm_message_payload ~keeper_name ~reason:action_reason ~snapshot ~execution)
  in
  let recover action_reason =
    make
      "keeper_recover"
      Operator_digest_types.Sev_bad
      action_reason
      (fleet_fsm_action_payload
         ~keeper_name
         ~kind:"recover"
         ~reason:action_reason
         ~snapshot
         ~execution)
  in
  let actions =
    if not attention.cra_needs_attention
    then []
    else if composite_execution_claim_no_eligible execution
    then
      [ probe ("Inspect keeper claim scope: " ^ reason)
      ; message ("Resolve keeper claim scope before retry: " ^ reason)
      ]
    else if composite_execution_config_blocked execution
    then
      [ probe ("Inspect configuration/auth blocker: " ^ reason)
      ; message ("Resolve configuration/auth blocker: " ^ reason)
      ]
    else if attention.cra_fiber_stop_requested
    then
      [ probe ("Inspect stop-requested keeper shutdown: " ^ reason)
      ; message ("Confirm keeper shutdown or supervisor reap: " ^ reason)
      ]
    else if composite_execution_saturated execution && not stale_long_enough
    then [ probe ("Inspect local runtime saturation: " ^ reason) ]
    else if idle_attention
    then
      [ probe ("Inspect idle composite: " ^ reason)
      ; message ("Diagnose idle composite trigger gap: " ^ reason)
      ]
    else
      [ probe ("Refresh stale runtime evidence: " ^ reason)
      ; recover ("Controlled keeper recovery for runtime stall: " ^ reason)
      ]
  in
  `List
    (actions
     |> Operator_digest_types.dedup_recommendations
     |> List.map (Operator_digest_types.recommended_action_to_yojson ~actor:"fleet_fsm"))
;;
