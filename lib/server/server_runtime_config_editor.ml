(* server_runtime_config_editor — what the Setup routes and the runtime
   config routes share when they write runtime.toml.

   The operation a write was, the audit row each write leaves, the JSON the
   editor gets back after a read or a commit, and the commit answer that
   applies the commit to the Skill snapshot. *)

module Http = Http_server_eio
module Runtime_request = Server_dashboard_runtime_request

let runtime_editor_protocol_json (protocol : Runtime_toml.editor_protocol) =
  let transport =
    match protocol.transport with
    | Runtime_toml.Endpoint -> "endpoint"
    | Runtime_toml.Command -> "command"
  in
  let semantics =
    match protocol.semantics with
    | Runtime_toml.Http_provider -> "http_provider"
    | Runtime_toml.Official_client -> "official_client"
  in
  let credential_policy =
    match protocol.credential_policy with
    | Runtime_toml.Credentials_optional -> "optional"
    | Runtime_toml.Credentials_forbidden -> "forbidden"
    | Runtime_toml.Credentials_file_required -> "file_required"
  in
  `Assoc
    [ "protocol", `String protocol.protocol
    ; "transport", `String transport
    ; "semantics", `String semantics
    ; "credential_policy", `String credential_policy
    ; "requires_non_interactive", `Bool protocol.requires_non_interactive
    ; "provider_fields", Json_util.json_string_list protocol.provider_fields
    ; ( "required_provider_fields"
      , Json_util.json_string_list protocol.required_provider_fields )
    ]
;;

let keeper_setting_payload keeper_document =
  match keeper_document with
  | Error detail ->
    ( `Assoc
        [ "valid", `Bool false
        ; "parse_error", `String detail
        ; "issues", `List []
        ]
    , `List []
    , `Assoc
        [ "status", `String "invalid"
        ; "configured_count", `Int 0
        ; "requires_restart", `Bool false
        ; "pending_keys", `List []
        ; "applied_keys", `List []
        ; "preempted_keys", `List []
        ; "applied_at", `Null
        ] )
  | Ok doc ->
    ( Keeper_runtime_config.validation_report_to_yojson
        (Keeper_runtime_config.validate_doc doc)
    , Keeper_runtime_config.settings_projection_to_yojson doc
    , Keeper_runtime_config.overlay_application_to_yojson doc )
;;

let skill_application_json = function
  | Error _ -> `Assoc [ "state", `String "invalid_workspace" ]
  | Ok (Server_skill_snapshot_runtime.Superseded { commit_order; applied_order }) ->
    `Assoc
      [ "state", `String "superseded"
      ; ( "commit_order"
        , `String (Runtime.config_commit_order_to_string commit_order) )
      ; ( "applied_order"
        , `String (Runtime.config_commit_order_to_string applied_order) )
      ]
  | Ok (Server_skill_snapshot_runtime.Applied { input_source_revision; publication }) ->
    let input_revision =
      `String (Runtime.config_source_revision_to_string input_source_revision)
    in
    let ready state snapshot =
      `Assoc
        [ "state", `String state
        ; "input_source_revision", input_revision
        ; ( "snapshot_revision"
          , `String
              (Skill_catalog_snapshot.snapshot_revision snapshot
               |> Skill_catalog_snapshot.snapshot_revision_to_string) )
        ; ( "catalog_revision"
          , `String
              (Skill_catalog_snapshot.catalog_revision snapshot
               |> Skill_catalog_snapshot.catalog_revision_to_string) )
        ; ( "config_state"
          , `String
              (Skill_catalog_snapshot.config_state snapshot
               |> Skill_catalog_snapshot.config_state_to_string) )
        ]
    in
    (match publication with
     | Workspace_retired ->
       `Assoc
         [ "state", `String "workspace_retired"
         ; "input_source_revision", input_revision
         ]
     | Published snapshot -> ready "published" snapshot
     | Unchanged snapshot -> ready "unchanged" snapshot)
;;

let runtime_config_application_json
      ?skill_application
      ?exact_output_registry
      ~operation
      ~routing_applied_at
      overlay
  =
  `Assoc
    ([ "operation", `String operation
    ; ( "routing"
      , `Assoc
          [ "status", `String (if Option.is_some routing_applied_at then "applied" else "active")
          ; "requires_restart", `Bool false
          ; ( "applied_at"
            , match routing_applied_at with
              | Some value -> `String value
              | None -> `Null )
          ] )
    ; "keeper_overlay", overlay
    ]
     @ (match skill_application with
        | None -> []
        | Some application -> [ "skills", skill_application_json application ])
     @ match exact_output_registry with
       | None -> []
       | Some outcome ->
         [ "exact_output_registry", Runtime.exact_output_registry_application_to_yojson outcome ])
;;

let runtime_config_raw_json
      ?commit
      ?skill_application
      ~source_revision
      ~path
      ~source_text
      ~operation
      ~routing_applied_at
      ()
  =
  (* Runtime home expansion, overlay/environment observations and account
     files make this an IO preparation job, not a pure CPU decoder. The auth
     check and response writer remain on the HTTP fiber. *)
  Eio_guard.with_named_switch "runtime-config-response" (fun () ->
    Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
      let source = Server_runtime_config_source.prepare source_text in
      Log.Dashboard.debug "runtime_config_response operation=%s syntax_inputs=%s" operation
        (match source.syntax_inputs with
         | Server_runtime_config_source.Shared_input -> "shared"
         | Reader_specific_inputs -> "reader_specific");
      let validation, keeper_settings, overlay = keeper_setting_payload source.keeper in
      let source_revision_text = Runtime.config_source_revision_to_string source_revision in
      let model_bindings =
        Result.bind
          (Result.map_error (fun errors -> String.concat "; "
             (List.map (fun (error : Runtime_toml.parse_error) -> error.path ^ ": " ^ error.message) errors)) source.runtime)
          Runtime_config_models.of_config
      in
      (* Models identifies the accounts in this exact source observation, which
         may differ from the providers currently loaded by the runtime. *)
      let account_groups, account_emails =
        match source.runtime with
        | Ok config -> Runtime_wizard_inventory.account_groups_json config,
            Runtime_account_email.inventory_json config
        | Error _ -> `Null, `Null
      in
      `Assoc
        ([ ("ok", `Bool true)
        ; ( "source_revision"
          , `String source_revision_text )
        ; ("path", `String path)
        ; ("file_name", `String Config_dir_resolver.runtime_toml_filename)
        ; ("source_text", `String source.source_text)
        ; ("account_groups", account_groups)
        ; ("account_emails", account_emails)
        ; ("model_bindings", Runtime_config_models.to_json ~path
            ~source_revision:source_revision_text model_bindings)
        ; ( "application"
          , runtime_config_application_json
              ?skill_application
              ?exact_output_registry:
                (Option.map
                   (fun (receipt : Runtime.config_commit_receipt) ->
                      receipt.exact_output_registry)
                   commit)
              ~operation
              ~routing_applied_at
              overlay )
        ; "validation", validation
        ; "keeper_setting_schema", Keeper_runtime_config.setting_schema_to_yojson ()
        ; "keeper_settings", keeper_settings
        ; ( "provider_protocols"
          , `List (List.map runtime_editor_protocol_json Runtime_toml.editor_protocols) )
        ; ( "reserved_provider_ids"
          , `List (List.map (fun id -> `String id) Runtime_toml.reserved_provider_ids) )
        ]
         @ match commit with
           | None -> []
           | Some receipt ->
             [ "state", `String "committed"
             ; "commit", Runtime.config_commit_receipt_to_yojson receipt
             ])))

let runtime_config_line_count = Server_skill_write_audit.line_count

type runtime_config_write_operation =
  | Runtime_config_raw_save
  | Runtime_config_routing of Runtime_request.runtime_route_lane * string option
  | Runtime_config_routing_list of Runtime_request.runtime_route_lane * string list
  | Runtime_config_lane_created of string * string list
  | Runtime_config_lane_removed of string
  | Runtime_config_lane_renamed of string * string
  | Runtime_config_exact_slot_appended of Runtime.exact_lane * string
  | Runtime_config_exact_slot_dropped of Runtime.exact_lane * string
  | Runtime_config_exact_slot_replaced of Runtime.exact_lane * string * string
  | Runtime_config_exact_slot_moved of
      Runtime.exact_lane * string * Runtime.exact_slot_move
  | Runtime_config_assignment of string * string option
  | Runtime_config_fusion of string
  | Runtime_config_account_removal of string
  | Runtime_config_tui_preference of Tui_preference.change

let runtime_config_write_operation_details =
  let open Runtime_request in
  function
  | Runtime_config_raw_save -> [ ("operation", `String "raw_save") ]
  | Runtime_config_routing (lane, runtime_id) ->
    [ ("operation", `String "routing")
    ; ("lane", `String (runtime_route_lane_to_string lane))
    ; ( "cleared"
      , `Bool
          (match runtime_id with
           | None -> true
           | Some _ -> false) )
    ]
    @
    (match runtime_id with
     | None -> []
     | Some id -> [ ("runtime_id", `String id) ])

  | Runtime_config_routing_list (lane, runtime_ids) ->
    [ ("operation", `String "routing")
    ; ("lane", `String (runtime_route_lane_to_string lane))
    ; ("cleared", `Bool (List.length runtime_ids = 0))
    ; "runtime_ids", `List (List.map (fun id -> `String id) runtime_ids)
    ]
  | Runtime_config_lane_created (lane_id, runtime_ids) ->
    [ ("operation", `String "routing")
    ; ("lane", `String lane_id)
    ; ("action", `String "create")
    ; "runtime_ids", `List (List.map (fun id -> `String id) runtime_ids)
    ]
  | Runtime_config_lane_removed lane_id ->
    [ ("operation", `String "routing")
    ; ("lane", `String lane_id)
    ; ("action", `String "remove")
    ]
  | Runtime_config_lane_renamed (lane_id, new_lane_id) ->
    [ ("operation", `String "routing")
    ; ("lane", `String lane_id)
    ; ("action", `String "rename")
    ; ("to", `String new_lane_id)
    ]
  | Runtime_config_exact_slot_appended (exact, runtime_id) ->
    [ ("operation", `String "routing")
    ; ("lane", `String (runtime_route_lane_to_string (Runtime_exact_lane exact)))
    ; ("action", `String "append")
    ; ("runtime_id", `String runtime_id)
    ]
  | Runtime_config_exact_slot_dropped (exact, runtime_id) ->
    [ ("operation", `String "routing")
    ; ("lane", `String (runtime_route_lane_to_string (Runtime_exact_lane exact)))
    ; ("action", `String "drop")
    ; ("runtime_id", `String runtime_id)
    ]
  | Runtime_config_exact_slot_moved (exact, runtime_id, move) ->
    [ ("operation", `String "routing")
    ; ("lane", `String (runtime_route_lane_to_string (Runtime_exact_lane exact)))
    ; ("action", `String "move")
    ; ("runtime_id", `String runtime_id)
    ; ( "direction"
      , `String
          (match move with
           | Runtime.Move_slot_up -> "up"
           | Runtime.Move_slot_down -> "down"
           | Runtime.Move_slot_first -> "first") )
    ]
  | Runtime_config_exact_slot_replaced (exact, runtime_id, replacement) ->
    [ "operation", `String "routing"
    ; "lane", `String (runtime_route_lane_to_string (Runtime_exact_lane exact))
    ; "action", `String "replace"
    ; "runtime_id", `String runtime_id
    ; "replacement_runtime_id", `String replacement ]
  | Runtime_config_assignment (keeper_name, runtime_id) ->
    [ ("operation", `String "assignment")
    ; ("keeper_name", `String keeper_name)
    ; ( "cleared"
      , `Bool
          (match runtime_id with
           | None -> true
           | Some _ -> false) )
    ]
    @
    (match runtime_id with
     | None -> []
     | Some id -> [ ("runtime_id", `String id) ])
  | Runtime_config_fusion edit ->
    [ ("operation", `String "fusion"); ("edit", `String edit) ]
  | Runtime_config_account_removal integration_id ->
    [ ("operation", `String "account_removal"); ("integration_id", `String integration_id) ]
  | Runtime_config_tui_preference change ->
    [ ("operation", `String "tui_preference"); ("change", Tui_preference.change_to_yojson change) ]

let runtime_config_write_operation_label = function
  | Runtime_config_raw_save -> "raw_save"
  | Runtime_config_routing _ | Runtime_config_routing_list _
  | Runtime_config_lane_created _ | Runtime_config_lane_removed _
  | Runtime_config_lane_renamed _
  | Runtime_config_exact_slot_appended _ | Runtime_config_exact_slot_dropped _
  | Runtime_config_exact_slot_moved _ | Runtime_config_exact_slot_replaced _ -> "routing"
  | Runtime_config_assignment _ -> "assignment"
  | Runtime_config_fusion _ -> "fusion"
  | Runtime_config_account_removal _ -> "account_removal"
  | Runtime_config_tui_preference _ -> "tui_preference"
;;

let audit_runtime_config_write
      state
      agent_name
      ?path
      ?receipt
      ?skill_application
      ~operation
      ~text
      ~outcome
      ()
  =
  try
    Audit_log.log_action
      (Mcp_server.workspace_config state)
      ~agent_id:agent_name
      ~action:Audit_log.RuntimeConfigWrite
      ~details:
        (`Assoc
           ((match path with
             | Some p -> [ ("path", `String p) ]
             | None -> [])
            @ runtime_config_write_operation_details operation
            @ [ ("bytes", `Int (String.length text))
              ; ("lines", `Int (runtime_config_line_count text))
              ]
            @ (match receipt with
               | None -> []
               | Some (commit : Runtime.config_commit_receipt) ->
                 [ "commit", Runtime.config_commit_receipt_to_yojson commit
                 ; ( "exact_output_registry"
                   , Runtime.exact_output_registry_application_to_yojson commit.exact_output_registry )
                 ])
            @ (match skill_application with
               | None -> []
               | Some application ->
                 [ "skills", skill_application_json application ])))
      ~outcome
      ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Dashboard.warn
      "runtime.toml audit log failed: %s"
      (Printexc.to_string exn)

let respond_runtime_config_commit
      state
      agent_name
      ~operation
      ~receipt
      request
      reqd
  =
  let observation = receipt.Runtime.observation in
  let base_path = (Mcp_server.workspace_config state).Workspace.base_path in
  let response_json =
    Eio.Cancel.protect (fun () ->
      let skill_application =
        Server_skill_snapshot_runtime.apply_commit ~base_path receipt
      in
      audit_runtime_config_write state agent_name ~path:observation.path
        ~receipt ~skill_application ~operation ~text:observation.source_text
        ~outcome:Audit_log.Success ();
      runtime_config_raw_json
        ~commit:receipt
        ~skill_application
        ~source_revision:observation.source_revision
        ~path:observation.path
        ~source_text:observation.source_text
        ~operation:(runtime_config_write_operation_label operation)
        ~routing_applied_at:(Some (Masc_domain.now_iso ()))
        ())
  in
  Http.Response.json_value ~compress:true ~request
    response_json
    reqd
