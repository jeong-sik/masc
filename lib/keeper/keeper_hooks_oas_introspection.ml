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

let hook_introspection_json () : Yojson.Safe.t =
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
          ]
        "after_turn";
      slot
        ~active:true
        ~source:"keeper_hooks_oas"
        ~features:[ "tool_start_timing" ]
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
  (* Derived slot counts are intentionally not emitted: every consumer can
     compute them from [slots]. *)
  `Assoc
    [
      (key_scope, `String "keeper_runtime_composite");
      (key_slots, `Assoc slot_assoc);
    ]
;;
