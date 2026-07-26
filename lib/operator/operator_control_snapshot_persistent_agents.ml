(** Persistent (keeper) agents snapshot row builder, extracted from
    [operator_control_snapshot.ml] (godfile decomp).

    [persistent_agents_json ~discovery ~keeper_rows]
    produces a `{ count; items; unavailable }` JSON object describing the
    persistent keeper agents:

    Projects the already-decoded canonical current-meta discovery onto the
    operator snapshot schema. Values are forwarded through [field_or_null];
    there is no secondary discovery/read path.

    Both paths emit the same wire shape — `runtime_class="keeper"`
    plus the standard operator-dashboard keeper fields. *)

include Operator_control_context_snapshot

let persistent_agents_json
      ~(discovery : Keeper_meta_store.current_meta_discovery)
      ~keeper_rows
  =
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
                 ; ( "context_metrics_unavailable"
                   , field_or_null "context_metrics_unavailable" )
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
    rows_from_keeper_rows discovery.persistent_keeper_names keeper_rows
  in
  `Assoc
    [ "count", `Int (List.length rows)
    ; "items", `List rows
    ; ( "unavailable"
      , Keeper_meta_store.current_meta_unavailable_collection_to_yojson
          (Keeper_meta_store.Current_meta_observed discovery.unavailable) )
    ]
;;
