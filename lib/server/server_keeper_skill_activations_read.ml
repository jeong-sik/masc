let usage_rows catalog ledger =
  List.filter_map
    (fun (skill : Keeper_skill_catalog.skill) ->
       match skill.reference with
       | None -> None
       | Some reference ->
         Keeper_skill_activation_ledger.usage_for_reference ledger reference
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

let usage_json ~(config : Workspace.config) = function
  | Keeper_skill_activation_projection.Available { ledger; _ } ->
    (match Server_skill_snapshot_runtime.lookup ~base_path:config.base_path with
     | Ok (Server_skill_snapshot_runtime.Ready { snapshot; config_path = _ }) ->
       let catalog, _diagnostics = Keeper_skill_catalog.all_entries_of_snapshot snapshot in
       `Assoc [ "state", `String "ready"; "rows", `List (usage_rows catalog ledger) ]
     | Ok (Server_skill_snapshot_runtime.Not_registered | Server_skill_snapshot_runtime.Uninitialized)
     | Error (Server_skill_snapshot_runtime.Invalid_workspace _) ->
       `Assoc [ "state", `String "no_catalog" ])
  | Keeper_skill_activation_projection.No_session _ | Keeper_skill_activation_projection.Unavailable _ ->
    `Assoc [ "state", `String "no_ledger" ]
;;

let json ~config ~keeper_name =
  let outcome = Keeper_skill_activation_projection.resolve ~config ~keeper_name in
  `Assoc
    [ "schema", `String "masc.keeper-skill-activations/v1"
    ; "keeper", `String keeper_name
    ; "skill_activations", Keeper_skill_activation_projection.to_yojson outcome
    ; "usage", usage_json ~config outcome
    ]
;;
