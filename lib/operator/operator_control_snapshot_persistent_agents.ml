(** Persistent (keeper) agents snapshot row builder, extracted from
    [operator_control_snapshot.ml] (godfile decomp).

    [persistent_agents_json ?keeper_names ?keeper_rows config]
    produces a `{ count; items }` JSON object describing the
    persistent keeper agents:

    - When [keeper_rows] is given, projects the row fields onto the
      operator snapshot schema (lossless filter — values are forwarded
      through `field_or_null`, no field synthesis).
    - When [keeper_rows] is absent, walks
      [Keeper_meta_store.persistent_agent_names config] (or the explicit
      [?keeper_names]), reads each keeper meta, asks
      [Dashboard_cache.get_or_compute] for a 2s-cached
      [Keeper_status_runtime.parse_agent_status] view, and assembles the
      operator schema rows from disk meta + the cached agent status.

    Both paths emit the same wire shape — `runtime_class="keeper"`
    plus the standard operator-dashboard keeper fields. *)

include Operator_control_context_snapshot

let persistent_agents_json ?keeper_names ?keeper_rows config =
  let rows_from_keeper_rows names rows =
    let wanted = List.sort_uniq String.compare names in
    let wanted_tbl = Hashtbl.create (List.length wanted) in
    List.iter (fun name -> Hashtbl.replace wanted_tbl name ()) wanted;
    rows
    |> List.filter_map (function
      | `Assoc fields ->
        (match List.assoc_opt "name" fields with
         | Some (`String name) when Hashtbl.mem wanted_tbl name ->
           let field_or_null key =
             match List.assoc_opt key fields with
             | Some value -> value
             | None -> `Null
           in
           Some
             (`Assoc
                 [ "runtime_class", `String "keeper"
                 ; "name", field_or_null "name"
                 ; "agent_name", field_or_null "agent_name"
                 ; "trace_id", field_or_null "trace_id"
                 ; "goal", field_or_null "goal"
                 ; "status", field_or_null "status"
                 ; "generation", field_or_null "generation"
                 ; "turn_count", field_or_null "turn_count"
                 ; "context_ratio", field_or_null "context_ratio"
                 ; "context_tokens", field_or_null "context_tokens"
                 ; "context_max", field_or_null "context_max"
                 ; "context_source", field_or_null "context_source"
                 ; "last_model_used", field_or_null "last_model_used"
                 ; "active_model", field_or_null "active_model"
                 ; "active_model_label", field_or_null "active_model_label"
                 ; "last_model_used_label", field_or_null "last_model_used_label"
                 ; "runtime_id", field_or_null "runtime_id"
                 ; "runtime_canonical", field_or_null "runtime_canonical"
                 ; ( "selected_runtime_canonical"
                   , field_or_null "selected_runtime_canonical" )
                 ; "primary_model", field_or_null "primary_model"
                 ; "next_model_hint", field_or_null "next_model_hint"
                 ; "active_goal_ids", field_or_null "active_goal_ids"
                 ; "last_autonomous_action_at", field_or_null "last_autonomous_action_at"
                 ; "autonomous_action_count", field_or_null "autonomous_action_count"
                 ; "updated_at", field_or_null "updated_at"
                 ; "created_at", field_or_null "created_at"
                 ])
         | _ -> None)
      | _ -> None)
  in
  let rows =
    match keeper_rows with
    | Some rows ->
      let names =
        match keeper_names with
        | Some names -> names
        | None -> Keeper_meta_store.persistent_agent_names config
      in
      rows_from_keeper_rows names rows
    | None ->
      let names =
        match keeper_names with
        | Some names -> names
        | None -> Keeper_meta_store.persistent_agent_names config
      in
      let agent_status_cache_ttl_s = 2.0 in
      List.filter_map
        (fun name ->
           match Keeper_meta_store.read_meta config name with
           | Error _ | Ok None -> None
           | Ok (Some meta) ->
             let agent_json =
               let cache_key = "kas:" ^ meta.agent_name in
               Dashboard_cache.get_or_compute cache_key ~ttl:agent_status_cache_ttl_s (fun () ->
                 Keeper_status_runtime.parse_agent_status config ~agent_name:meta.agent_name)
             in
             let agent_status =
               match agent_json with
               | `Assoc _ ->
                 Json_util.get_string agent_json "status" |> Option.value ~default:"unknown"
               | _ -> "unknown"
             in
             let context_snapshot = keeper_context_snapshot_of_meta config meta in
             Some
               (`Assoc
                   ([ "runtime_class", `String "keeper"
                    ; "name", `String meta.name
                    ; "agent_name", `String meta.agent_name
                    ; ( "trace_id"
                      , `String (Keeper_id.Trace_id.to_string meta.runtime.trace_id) )
                    ; "status", `String agent_status
                    ; "generation", `Int meta.runtime.generation
                    ; "turn_count", `Int meta.runtime.usage.total_turns
                    ; "last_model_used", `Null
                    ; "active_model", `Null
                    ; "next_model_hint", `Null
                    ; ( "active_goal_ids"
                      , `List
                          (List.map (fun goal_id -> `String goal_id) meta.active_goal_ids)
                      )
                    ; ( "last_autonomous_action_at"
                      , if String.trim meta.runtime.last_autonomous_action_at = ""
                        then `Null
                        else `String meta.runtime.last_autonomous_action_at )
                    ; "autonomous_action_count", `Int meta.runtime.autonomous_action_count
                    ; "updated_at", `String meta.updated_at
                    ; "created_at", `String meta.created_at
                    ]
                    @ keeper_context_snapshot_fields context_snapshot)))
        names
  in
  `Assoc [ "count", `Int (List.length rows); "items", `List rows ]
;;
