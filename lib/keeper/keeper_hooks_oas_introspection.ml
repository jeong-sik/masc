(** Static introspection of Keeper OAS hook slot configuration. *)

include Keeper_hooks_oas_types

let hook_slot_json ?(features = []) ?(gates = []) ?(effects = []) ?reason
    ~(active : bool) ~(source : string) () : Yojson.Safe.t =
  let list_field name values =
    match values with
    | [] -> []
    | xs -> [(name, `List (List.map (fun s -> `String s) xs))]
  in
  `Assoc
    ([
       (key_active, `Bool active);
       (key_source, `String source);
     ]
     @ (match reason with
       | None -> []
       | Some value -> [(key_reason, `String value)])
     @ list_field "features" features
     @ list_field "gates" gates
     @ list_field "effects" effects)
;;

let hook_introspection_json ~denied_tools ?(max_cost_usd : float option)
    ?(destructive_ops_policy : Destructive_ops_policy.t =
        Destructive_ops_policy.default)
    () : Yojson.Safe.t =
  let destructive_enabled = Destructive_ops_policy.enabled destructive_ops_policy in
  let denied_json = `List (List.map (fun s -> `String s) denied_tools) in
  let destructive_json = `String "dynamic_boundary (Tool_capability.Destructive)" in
  let slot ?features ?gates ?effects ?reason ~active ~source name =
    let features = Option.value features ~default:[] in
    let gates = Option.value gates ~default:[] in
    let effects = Option.value effects ~default:[] in
    let json = hook_slot_json ~features ~gates ~effects ?reason ~active ~source () in
    name, active, json
  in
  let slot_entries =
    [
      slot
        ~active:true
        ~source:"keeper_hooks_oas"
        ~features:[ "utf8_guard" ]
        "before_turn";
      slot
        ~active:true
        ~source:"keeper_run_tools"
        ~features:
          [
            "dynamic_context";
            "adaptive_thinking_budget";
            "tool_surface_selection";
            "memory_injection";
          ]
        "before_turn_params";
      slot
        ~active:true
        ~source:"keeper_hooks_oas"
        ~effects:
          [
            "sse_broadcast";
            "cost_event";
            "metrics";
            "usage_trust";
            "tool_streak_reset";
          ]
        "after_turn";
      slot
        ~active:true
        ~source:"keeper_guards"
        ~gates:
          [
            "timing";
            "custom_guard";
            "readonly_observation_duplicate";
            "streak_gate";
            "keeper_deny_list";
            (if destructive_enabled then "destructive_pattern" else "destructive_pattern_off");
            "governance_approval";
          ]
        ~features:
          [
            (if Option.is_some max_cost_usd
             then "cost_telemetry_threshold"
             else "cost_telemetry_threshold_off");
          ]
        "pre_tool_use";
      slot
        ~active:true
        ~source:"keeper_hooks_oas"
        ~features:
          [
            "tool_callback";
            "tool_call_log";
            "trajectory";
            "board_write_detection";
            "tool_emission_capture";
          ]
        "post_tool_use";
      slot
        ~active:true
        ~source:"keeper_hooks_oas"
        ~effects:[ "tool_use_failure_metric" ]
        "post_tool_use_failure";
      slot
        ~active:true
        ~source:"keeper_hooks_oas"
        ~effects:[ "stop_reason_metric" ]
        "on_stop";
      slot
        ~active:true
        ~source:"keeper_hooks_oas"
        ~features:[ "repeated_tool_nudge"; "idle_skip" ]
        "on_idle";
      slot
        ~active:true
        ~source:"keeper_hooks_oas"
        ~effects:[ "idle_escalation_metric" ]
        "on_idle_escalated";
      slot
        ~active:true
        ~source:"keeper_hooks_oas"
        ~effects:[ "wirein_failure_metric"; "keeper_error_log" ]
        "on_error";
      slot
        ~active:true
        ~source:"keeper_hooks_oas"
        ~effects:[ "wirein_failure_metric"; "keeper_error_log" ]
        "on_tool_error";
      slot
        ~active:false
        ~source:"not_registered"
        ~reason:"compaction is handled by keeper_post_turn"
        "pre_compact";
      slot
        ~active:false
        ~source:"not_registered"
        ~reason:"compaction is handled by keeper_post_turn"
        "post_compact";
      slot
        ~active:false
        ~source:"not_registered"
        ~reason:"compaction is handled by keeper_post_turn"
        "on_context_compacted";
    ]
  in
  let slot_assoc = List.map (fun (name, _active, json) -> name, json) slot_entries in
  (* Derived counts (slot_count / active_slot_count / inactive_slot_count /
     slot_names / deny_list_count) are intentionally NOT emitted: every
     consumer computes them from [slots] / [deny_list] directly. Emitting them
     was redundant derived state with no reader. *)
  `Assoc
    [
      (key_scope, `String "keeper_runtime_composite");
      (key_slots, `Assoc slot_assoc);
      ("deny_list", denied_json);
      ("destructive_check_tools", destructive_json);
      ( "cost_telemetry",
        match max_cost_usd with
        | Some v ->
          `Assoc
            [ (key_max_cost_usd, `Float v); (key_active, `Bool true); ("enforced", `Bool false) ]
        | None -> `Assoc [ (key_active, `Bool false); ("enforced", `Bool false) ] );
    ]
;;
