(** Keeper meta JSON codec facade.

    Included by [Keeper_types] so existing [Keeper_types.*] callers keep
    their public API while guards, parsing, and serialization stay in
    smaller private modules. *)

open Keeper_types_profile
open Keeper_meta_contract
include Keeper_meta_json_scrub

let meta_to_json (m : keeper_meta) : Yojson.Safe.t =
  let rt = m.runtime in
  (* Most policy fields are TOML-only. Identity/personality fields plus
     multimodal_policy are persisted as the effective runtime snapshot so
     dashboards, checkpoint writers, and meta readers do not see a blank or
     downgraded keeper between TOML load and prompt render. *)
  `Assoc
    [ "name", `String m.name
    ; "agent_name", `String m.agent_name
    ; ( "persona"
      , match m.persona with
        | Some s -> `String s
        | None -> `Null )
    ; "instructions", `String m.instructions
    ; "trace_id", `String (Keeper_id.Trace_id.to_string rt.trace_id)
    ; "multimodal_policy", `String (multimodal_policy_to_string m.multimodal_policy)
    ; "trace_history", `List (List.map (fun s -> `String s) rt.trace_history)
    ; "generation", `Int rt.generation
    ; "last_handoff_ts", `Float rt.last_handoff_ts
    ; "created_at", `String m.created_at
    ; "updated_at", `String m.updated_at
    ; "total_turns", `Int rt.usage.total_turns
    ; "total_input_tokens", `Int rt.usage.total_input_tokens
    ; "total_output_tokens", `Int rt.usage.total_output_tokens
    ; "total_tokens", `Int rt.usage.total_tokens
    ; "total_cost_usd", `Float rt.usage.total_cost_usd
    ; "last_turn_ts", `Float rt.usage.last_turn_ts
    ; "last_input_tokens", `Int rt.usage.last_input_tokens
    ; "last_output_tokens", `Int rt.usage.last_output_tokens
    ; "last_total_tokens", `Int rt.usage.last_total_tokens
    ; "last_latency_ms", `Int rt.usage.last_latency_ms
    ; "compaction_count", `Int rt.compaction_rt.count
    ; "last_compaction_ts", `Float rt.compaction_rt.last_ts
    ; "last_compaction_before_tokens", `Int rt.compaction_rt.last_before_tokens
    ; "last_compaction_after_tokens", `Int rt.compaction_rt.last_after_tokens
    ; "proactive_count_total", `Int rt.proactive_rt.count_total
    ; "last_proactive_ts", `Float rt.proactive_rt.last_ts
    ; "proactive_visible_count_total", `Int rt.proactive_rt.visible_count_total
    ; "last_visible_proactive_ts", `Float rt.proactive_rt.last_visible_ts
    ; ( "last_proactive_outcome"
      , `String (proactive_cycle_outcome_to_string rt.proactive_rt.last_outcome) )
    ; "last_proactive_reason", `String rt.proactive_rt.last_reason
    ; "last_proactive_preview", `String rt.proactive_rt.last_preview
    ; "consecutive_noop_count", `Int rt.proactive_rt.consecutive_noop_count
    ; "last_compaction_check_ts", `Float rt.compaction_rt.last_check_ts
    ; ( "last_compaction_decision"
      , `String (compaction_runtime_decision_to_string rt.compaction_rt.last_decision)
      )
    ; "active_goal_ids", `List (List.map (fun s -> `String s) m.active_goal_ids)
    ; "last_autonomous_action_at", `String rt.last_autonomous_action_at
    ; "autonomous_action_count", `Int rt.autonomous_action_count
    ; "autonomous_turn_count", `Int rt.autonomous_turn_count
    ; "autonomous_text_turn_count", `Int rt.autonomous_text_turn_count
    ; "autonomous_tool_turn_count", `Int rt.autonomous_tool_turn_count
    ; "board_reactive_turn_count", `Int rt.board_reactive_turn_count
    ; "mention_reactive_turn_count", `Int rt.mention_reactive_turn_count
    ; "noop_turn_count", `Int rt.noop_turn_count
    ; ( "message_scope_ack_id"
      , match rt.message_scope_ack_id with
        | Some id -> `String id
        | None -> `Null )
    ; ( "last_blocker"
      , match rt.last_blocker with
        | Some info -> blocker_info_to_json info
        | None -> `Null )
    ; ( "last_runtime_attempt"
      , match rt.last_runtime_attempt with
        | Some record -> runtime_attempt_record_to_json record
        | None -> `Null )
    ; ( "last_turn_tool_calls"
      , `List
          (List.map
             (fun (s : Keeper_meta_contract.tool_call_summary) ->
                `Assoc [ ("tool_name", `String s.tool_name); ("outcome", `String s.outcome) ])
             rt.last_turn_tool_calls) )
    ; "paused", `Bool m.paused
    ; ( "latched_reason"
      , match m.latched_reason with
        | Some reason -> Keeper_latched_reason.Stable.to_yojson reason
        | None -> `Null )
    ; ( "current_task_id"
      , Json_util.string_opt_to_json
          (Option.map Keeper_id.Task_id.to_string m.current_task_id) )
    ; ( "keeper_id"
      , match m.keeper_id with
        | Some uid -> Keeper_id.uid_to_yojson uid
        | None -> `Null )
    ; "oas_env", `Assoc (List.map (fun (k, v) -> k, `String v) m.oas_env)
    ; "meta_version", `Int m.meta_version
    ]
;;

include Keeper_meta_json_parse

(* Seed round-trip: parse a minimal canonical JSON then serialize to derive
   the canonical key set. *)
let canonical_keeper_meta_key_names =
  let seed_json =
    `Assoc
      [ "name", `String "__keeper-meta-key-seed__"
      ; "agent_name", `String "__keeper-meta-key-seed__"
      ; "persona", `String "__keeper-meta-key-seed__"
      ; "trace_id", `String "__keeper-meta-key-seed__"
      ]
  in
  match meta_of_json seed_json with
  | Ok meta ->
    (match meta_to_json meta with
     | `Assoc fields -> fields |> List.map fst |> dedupe_keep_order
     | _ -> invalid_arg "Keeper_meta_json.meta_to_json must return an object")
  | Error msg ->
    invalid_arg ("Keeper_meta_json canonical seed is invalid: " ^ msg)
;;

let unknown_keeper_meta_keys (json : Yojson.Safe.t) : string list =
  match json with
  | `Assoc fields ->
    fields
    |> List.filter_map (fun (key, _) ->
      if List.mem key canonical_keeper_meta_key_names
      then None
      else Some key)
    |> dedupe_keep_order
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> []
;;

let warn_unknown_keeper_meta_keys ~path (json : Yojson.Safe.t) =
  match unknown_keeper_meta_keys json with
  | [] -> ()
  | unknown ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string MetaJsonFailures)
      ~labels:[("site", "unknown_keys")]
      ();
    Log.Keeper.warn
      "keeper meta %s has unknown keys: %s"
      path
      (String.concat ", " unknown)
;;
