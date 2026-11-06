let usage_rows ~config ~trace_id catalog =
  List.filter_map
    (fun (skill : Keeper_skill_catalog.skill) ->
       match skill.reference with
       | None -> None
       | Some reference ->
         Server_skill_usage_runtime.usage_for_reference ~config ~trace_id ~reference
         |> Option.map (fun (usage : Keeper_skill_activation_ledger.catalog_usage) ->
           `Assoc
             [ "reference", Skill_reference.to_yojson reference
             ; "invocations", `Int usage.invocations
             ; "deliveries", `Int usage.received_invocations
             ; "actions", `Int usage.observed_actions
             ; "last_used_at", `String usage.last_activated_at
             ]))
    catalog
;;

let resolve ~config ~keeper_name =
  match Keeper_meta_store.read_meta config keeper_name with
  | Error detail ->
    None, Keeper_skill_activation_projection.Unavailable
      { keeper_name; reason = "keeper_meta_unreadable"; detail }
  | Ok None -> None, No_session { keeper_name }
  | Ok (Some meta) ->
    (match Server_skill_usage_runtime.read_sessions ~config [ keeper_name, meta.runtime.trace_id ] with
     | [ (_, ledger) ], [] ->
       Some meta.runtime.trace_id,
       Keeper_skill_activation_projection.Available { keeper_name; ledger }
     | _, errors ->
       let detail = match errors with
         | [] -> "the session ledger is unavailable"
         | details -> String.concat "; " details
       in
       Some meta.runtime.trace_id,
       Unavailable { keeper_name; reason = "activation_ledger_unreadable"; detail })
;;

let activations_json ~config ~keeper_name =
  `Assoc
    [ "schema", `String "masc.keeper-skill-activations/v1"
    ; "keeper", `String keeper_name
    ; ( "skill_activations"
      , Keeper_skill_activation_projection.to_yojson (snd (resolve ~config ~keeper_name)) )
    ]
;;

let usage_of_outcome ~(config : Workspace.config) (trace_id, outcome) =
  match trace_id, outcome with
  | Some trace_id, Keeper_skill_activation_projection.Available { ledger = _; keeper_name = _ } ->
    (match Server_skill_snapshot_runtime.lookup ~base_path:config.base_path with
     | Ok (Server_skill_snapshot_runtime.Ready { snapshot; config_path = _ }) ->
       let catalog, _diagnostics = Keeper_skill_catalog.all_entries_of_snapshot snapshot in
       `Assoc [ "state", `String "ready"; "rows", `List (usage_rows ~config ~trace_id (Keeper_skill_catalog.skills catalog)) ]
     | Ok (Server_skill_snapshot_runtime.Not_registered | Server_skill_snapshot_runtime.Uninitialized)
     | Error (Server_skill_snapshot_runtime.Invalid_workspace _) ->
       `Assoc [ "state", `String "no_catalog" ])
  | _, Keeper_skill_activation_projection.No_session { keeper_name = _ } ->
    `Assoc [ "state", `String "no_session" ]
  | _, Keeper_skill_activation_projection.Unavailable { reason; detail; keeper_name = _ } ->
    `Assoc
      [ "state", `String "unavailable"
      ; "reason", `String reason
      ; "detail", `String detail
      ]
  | _, Keeper_skill_activation_projection.Available _ ->
    `Assoc [ "state", `String "unavailable"; "reason", `String "trace_unavailable"; "detail", `String "No current trace is recorded" ]
;;

let usage_json ~config ~keeper_name =
  `Assoc
    [ "schema", `String "masc.keeper-skill-usage/v1"
    ; "keeper", `String keeper_name
    ; ( "usage" , usage_of_outcome ~config (resolve ~config ~keeper_name) )
    ]
;;
