(** Keeper meta JSON codec facade.

    Included by [Keeper_types] so existing [Keeper_types.*] callers keep
    their public API while guards, parsing, and serialization stay in
    smaller private modules. *)

open Keeper_types_profile
open Keeper_meta_contract
include Keeper_meta_json_current_schema

let meta_to_json (m : keeper_meta) : Yojson.Safe.t =
  let rt = m.runtime in
  (* Most policy fields are TOML-only. Identity/instruction fields are
     persisted as the effective runtime snapshot so dashboards, checkpoint
     writers, and meta readers do not see a blank or downgraded keeper between
     TOML load and prompt render. *)
  object_of_field_values
    [ Schema, `String "masc.keeper_meta.v1"
    ; Name, `String m.name
    ; Instructions, `String m.instructions
    ; Trace_id, `String (Keeper_id.Trace_id.to_string rt.trace_id)
    ; Trace_history, `List (List.map (fun s -> `String s) rt.trace_history)
    ; Last_handoff_ts, `Float rt.last_handoff_ts
    ; Created_at, `String m.created_at
    ; Updated_at, `String m.updated_at
    ; Total_turns, `Int rt.usage.total_turns
    ; Total_input_tokens, `Int rt.usage.total_input_tokens
    ; Total_output_tokens, `Int rt.usage.total_output_tokens
    ; Total_tokens, `Int rt.usage.total_tokens
    ; Total_cost_usd, `Float rt.usage.total_cost_usd
    ; Last_turn_ts, `Float rt.usage.last_turn_ts
    ; Last_input_tokens, `Int rt.usage.last_input_tokens
    ; Last_output_tokens, `Int rt.usage.last_output_tokens
    ; Last_total_tokens, `Int rt.usage.last_total_tokens
    ; Last_latency_ms, `Int rt.usage.last_latency_ms
    ; Proactive_count_total, `Int rt.proactive_rt.count_total
    ; Last_proactive_ts, `Float rt.proactive_rt.last_ts
    ; Proactive_visible_count_total, `Int rt.proactive_rt.visible_count_total
    ; Last_visible_proactive_ts, `Float rt.proactive_rt.last_visible_ts
    ; ( Last_proactive_outcome
      , `String (proactive_cycle_outcome_to_string rt.proactive_rt.last_outcome) )
    ; Last_proactive_reason, `String rt.proactive_rt.last_reason
    ; Last_proactive_preview, `String rt.proactive_rt.last_preview
    ; ( Message_scope_ack_id
      , match rt.message_scope_ack_id with
        | Some id -> `String id
        | None -> `Null )
    ; ( Last_runtime_attempt
      , match rt.last_runtime_attempt with
        | Some record -> runtime_attempt_record_to_json record
        | None -> `Null )
    ; Paused, `Bool m.paused
    ; ( Latched_reason
      , match m.latched_reason with
        | Some reason -> Keeper_latched_reason.Stable.to_yojson reason
        | None -> `Null )
    ; ( Current_task_id
      , Json_util.string_opt_to_json
          (Option.map Keeper_id.Task_id.to_string m.current_task_id) )
    ; ( Keeper_id
      , match m.keeper_id with
        | Some uid -> Keeper_id.uid_to_yojson uid
        | None -> `Null )
    ; Agent_core_env, `Assoc (List.map (fun (k, v) -> k, `String v) m.agent_core_env)
    ]
;;

module Snapshot_digest = struct
  type t = string

  let is_lower_hex = function
    | '0' .. '9'
    | 'a' .. 'f' -> true
    | _ -> false
  ;;

  let of_meta meta =
    meta
    |> meta_to_json
    |> Yojson.Safe.to_string
    |> Digestif.SHA256.digest_string
    |> Digestif.SHA256.to_hex
  ;;

  let of_string value =
    if String.length value = 64 && String.for_all is_lower_hex value
    then Ok value
    else Error "metadata snapshot digest must be exactly 64 lowercase hexadecimal characters"
  ;;

  let to_string value = value
  let equal = String.equal
end

include Keeper_meta_json_parse

let current_write_json meta =
  let json = meta_to_json meta in
  match meta_of_json json with
  | Ok _ -> Ok json
  | Error detail -> Error detail
;;

let canonical_keeper_meta_key_names = current_field_names
