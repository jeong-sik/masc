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
      [?keeper_names]), reads each keeper meta, and derives the canonical
      keeper status from its diagnostic projection.

    Both paths emit the same wire shape — `runtime_class="keeper"`
    plus the standard operator-dashboard keeper fields. *)

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
                ([ "runtime_class", `String "keeper"
                 ; "name", field_or_null "name"
                 ; "agent_name", field_or_null "agent_name"
                 ; "trace_id", field_or_null "trace_id"
                 ; "goal", field_or_null "goal"
                 ; "status", field_or_null "status"
                 ; "generation", field_or_null "generation"
                 ; "turn_count", field_or_null "turn_count"
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
                 ; "updated_at", field_or_null "updated_at"
                 ; "created_at", field_or_null "created_at"
                 ]
                 (* Lossless filter (module contract): keeper_rows is the
                    freshly computed keepers projection, so the measured
                    context fields forward verbatim like every other field —
                    synthesizing typed absence here would contradict the
                    canonical row and trip false diagnostics. *)
                 @ [ "context_ratio", field_or_null "context_ratio"
                   ; "context_tokens", field_or_null "context_tokens"
                   ; "context_max", field_or_null "context_max"
                   ; "context_source", field_or_null "context_source"
                   ; ( "context_metrics_unavailable"
                     , field_or_null "context_metrics_unavailable" )
                   ; "context", field_or_null "context"
                   ]
                 @ [ "last_turn_usage", field_or_null "last_turn_usage" ]))
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
      List.filter_map
        (fun name ->
           match Keeper_meta_store.read_meta config name with
           | Error _ | Ok None -> None
           | Ok (Some meta) ->
             let keepalive_running =
               Keeper_status_bridge.runtime_keepalive_running config meta
             in
             let now_ts = Time_compat.now () in
             let diagnostic =
               Keeper_status_runtime.keeper_diagnostic_json
                 ~config
                 ~meta
                 ~keepalive_running
                 ~history_items:[]
                 ~now_ts
               |> Keeper_status_runtime.augment_keeper_diagnostic_json
                    ~keepalive_running
                    ~keepalive_started_at:
                      (Keeper_status_bridge.runtime_keepalive_started_at config meta)
                    ~now_ts
             in
             let status =
               Keeper_status_runtime.keeper_surface_status ~diagnostic
             in
             Some
               (`Assoc
                   ([ "runtime_class", `String "keeper"
                    ; "name", `String meta.name
                    ; "agent_name", `String meta.name
                    ; ( "trace_id"
                      , `String (Keeper_id.Trace_id.to_string meta.runtime.trace_id) )
                    ; "status", `String status
                    ; "turn_count", `Int meta.runtime.usage.total_turns
                    ; "last_model_used", `Null
                    ; "active_model", `Null
                    ; "next_model_hint", `Null
                    ; "updated_at", `String meta.updated_at
                    ; "created_at", `String meta.created_at
                    ]
                    @ Keeper_context_observation_projection.context_fields
                        ~config
                        ~keeper_name:meta.name
                        ~current_trace_id:
                          (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
                    @ [ ( "last_turn_usage"
                        , Keeper_context_observation_projection
                          .last_turn_usage_json
                            ~base_path:config.base_path
                            meta )
                      ])))
        names
  in
  `Assoc [ "count", `Int (List.length rows); "items", `List rows ]
;;
