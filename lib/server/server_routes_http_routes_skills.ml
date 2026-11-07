(* server_routes_http_routes_skills — HTTP routes for the Skill editor
   dashboard surface.

   The writable-source list, the authoring tool list, preview, create, save,
   delete and read of one Skill package, the evidence projection, and the
   catalog snapshot refresh. Server_routes_http_routes_dashboard.add_routes
   registers this group in the middle of its own pipeline. *)

module Http = Http_server_eio
module Keeper_api_types = Server_dashboard_http_keeper_api_types

type skill_editor_body =
  { reference : Skill_reference.t
  ; source_text : string option
  ; confirmed : bool option
  }

let parse_skill_editor_body body_str =
  Result.bind (Server_json_object_body.fields body_str) (fun fields ->
      let json = `Assoc fields in
      (match Json_util.assoc_member_opt "reference" json with
       | None -> Error "reference required"
       | Some reference_json ->
         (match Skill_reference.of_yojson reference_json with
          | Error _ -> Error "reference must be an exact Skill reference"
          | Ok reference ->
            let ( let* ) = Result.bind in
            let* source_text =
              match Json_util.assoc_member_opt "source_text" json with
              | None -> Ok None
              | Some (`String source_text) -> Ok (Some source_text)
              | Some _ -> Error "source_text must be a string"
            in
            let* confirmed =
              match Json_util.assoc_member_opt "confirmed" json with
              | None -> Ok None
              | Some (`Bool confirmed) -> Ok (Some confirmed)
              | Some _ -> Error "confirmed must be a boolean"
            in
            Ok { reference; source_text; confirmed })))

type skill_create_body =
  { expected_kind : Server_skill_editor.expected_kind
  ; source_id : Skill_source_config.source_id
  ; package_id : string
  ; source_text : string
  }

let parse_skill_create_body body_str =
  Result.bind (Server_json_object_body.fields body_str) (fun fields ->
      let json = `Assoc fields in
      let ( let* ) = Result.bind in
      let required name =
        match Json_util.assoc_member_opt name json with
        | Some (`String value) when not (String.equal (String.trim value) "") ->
          Ok (String.trim value)
        | Some (`String _) -> Error (name ^ " must not be empty")
        | Some _ -> Error (name ^ " must be a string")
        | None -> Error (name ^ " required")
      in
      let* source_id_text = required "source_id" in
      let* source_id =
        Skill_source_config.source_id_of_string source_id_text
        |> Result.map_error (fun detail -> "invalid source_id: " ^ detail)
      in
      let* package_id = required "package_id" in
      let* expected_kind = match Json_util.assoc_member_opt "kind" json with
        | Some (`String "instruction") -> Ok Server_skill_editor.Instruction_kind
        | Some (`String "composition") -> Ok Server_skill_editor.Composition_kind
        | _ -> Error "kind must be instruction or composition" in
      let* source_text =
        match Json_util.assoc_member_opt "source_text" json with
        | Some (`String value) when not (String.equal value "") -> Ok value
        | Some (`String _) -> Error "source_text must not be empty"
        | Some _ -> Error "source_text must be a string"
        | None -> Error "source_text required"
      in
      Ok { expected_kind; source_id; package_id; source_text })

let skill_editor_error_status = function
  | Server_skill_editor.Source_read_only -> `Forbidden
  | Revision_conflict _ | Delete_revision_conflict _ | Recovery_required _
  | Package_already_exists ->
    `Conflict
  | Snapshot_not_registered | Snapshot_uninitialized | Reference_not_current
  | Source_not_ready _ | Source_file_missing ->
    `Not_found
  | Invalid_workspace | Source_read_failed | Write_failed _ | Quarantine_failed _ ->
    `Internal_server_error
  | Source_too_large _ -> `Payload_too_large
  | Source_path_rejected _ | Confirmation_required | Invalid_package_id _
  | Validation_failed _ ->
    `Bad_request

(* [audit_status] reports whether the audit append itself returned
   ("audit_call_returned" | "unconfirmed", matching [Workspace_skill_publish]),
   whereas the audit entry's own [status] field ("write_outcome_unknown", etc.)
   records the skill package disk-write outcome. *)
let skill_audit_status_to_string = function
  | Workspace_skill_publish.Audit_call_returned -> "audit_call_returned"
  | Workspace_skill_publish.Audit_unconfirmed -> "unconfirmed"
;;

let with_skill_audit_status audit json =
  match audit, json with
  | None, json -> json
  | Some audit, `Assoc fields ->
    `Assoc (fields @ [ "audit_status", `String (skill_audit_status_to_string audit) ])
  | Some _, json -> json
;;

let respond_skill_editor_error ?audit ~request reqd error =
  Http.Response.json_value
    ~status:(skill_editor_error_status error)
    ~request
    (with_skill_audit_status audit (Server_skill_editor.error_to_yojson error))
    reqd
;;

let audit_skill_write state agent_name ~reference ~source_text ~status ~outcome =
  Server_skill_write_audit.record
    (Mcp_server.workspace_config state)
    ~agent_id:agent_name
    ~subject:(Server_skill_write_audit.Published reference)
    ~source_text
    ~status
    ~outcome
    ()
;;

let audit_skill_create_attempt state agent_name ~source_id ~package_id ~source_text ~error =
  match Server_keeper_skill_publish.cause_of_editor_error error with
  | Workspace_skill_publish.Write_outcome_unknown ->
    Some
      (Server_skill_write_audit.record
         (Mcp_server.workspace_config state)
         ~agent_id:agent_name
         ~subject:
           (Server_skill_write_audit.Attempted
              { source_id = Skill_source_config.source_id_to_string source_id
              ; package_id
              })
         ~source_text
         ~status:"write_outcome_unknown"
         ~outcome:(Audit_log.Failure (Server_skill_editor.error_to_string error))
         ())
  | Workspace_skill_publish.Request_refused
  | Workspace_skill_publish.Source_unavailable -> None
;;

(* [package_directory] is kept in the audit row because a later create for
   the same id answers [package_already_exists] when the folder stayed, and
   the WARN log line that also says so rotates away. *)
let skill_delete_audit_details ~reference ~status ~recovery ~package_directory =
  `Assoc
    ([ "reference", Skill_reference.to_yojson reference
     ; "status", `String status
     ]
     @ (match recovery with
        | None -> []
        | Some (recovery_id, disposition) ->
          [ "recovery_id", `String recovery_id
          ; "recovery_disposition", `String disposition
          ])
     @ match package_directory with
       | None -> []
       | Some package_directory ->
         [ ( "package_directory"
           , Server_skill_editor.package_directory_to_yojson package_directory )
         ])
;;

(* The row for a delete that went through is read off the outcome here, not in
   the handler, so a field the outcome carries cannot be dropped on the way to
   the audit. *)
let skill_delete_audit_of_outcome outcome =
  let recovery recovery_id disposition =
    Some (recovery_id, Server_skill_editor.recovery_disposition_to_string disposition)
  in
  match outcome with
  | Server_skill_editor.Deleted_and_published
      { reference; recovery_id; disposition; package_directory; _ } ->
    ( Audit_log.Success
    , skill_delete_audit_details
        ~reference
        ~status:"deleted_and_published"
        ~recovery:(recovery recovery_id disposition)
        ~package_directory:(Some package_directory) )
  | Deleted_but_unpublished
      { reference; reason; recovery_id; disposition; package_directory } ->
    ( Audit_log.Failure (Server_skill_editor.delete_unpublished_reason_to_string reason)
    , skill_delete_audit_details
        ~reference
        ~status:"deleted_but_unpublished"
        ~recovery:(recovery recovery_id disposition)
        ~package_directory:(Some package_directory) )
;;

let audit_skill_delete state agent_name ~details ~outcome =
  try
    Audit_log.log_action
      (Mcp_server.workspace_config state)
      ~agent_id:agent_name
      ~action:(Audit_log.Custom "skill_delete")
      ~details
      ~outcome
      ()
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Dashboard.warn "Skill delete audit failed: %s" (Printexc.to_string exn)
;;

let skill_error_recovery error =
  Server_skill_editor.error_recovery error
  |> Option.map (fun (recovery_id, disposition) ->
    ( recovery_id
    , Server_skill_editor.recovery_disposition_to_string disposition ))
;;

let add_routes router =
  router
  |> Server_route.get (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/skills/editor/sources" (fun state _agent_name req reqd ->
           match
             Server_skill_editor.writable_sources
               ~base_path:(Mcp_server.workspace_config state).base_path
           with
           | Error error -> respond_skill_editor_error ~request:req reqd error
           | Ok sources ->
             Http.Response.json_value
               ~compress:true
               ~request:req
               (`Assoc
                 [ "status", `String "ready"
                 ; ( "sources"
                   , `List
                       (List.map Server_skill_editor.writable_source_to_yojson sources) )
                 ])
               reqd)
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/skills/evidence" (fun state _agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body_str ->
             match Server_skill_evidence.request_of_string body_str with
             | Error message ->
               Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd message
             | Ok (reference, composition_run_id) ->
               Http.Response.json_value
                 ~compress:true
                 ~request:req
                 (Server_skill_evidence.project
                    ?composition_run_id
                    ~config:(Mcp_server.workspace_config state)
                    reference)
                 reqd))
  |> Server_route.get (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/skills/editor/tools" (fun state _agent_name req reqd ->
           let descriptors = Server_skill_editor.authoring_descriptors
             ~config:(Mcp_server.workspace_config state) ~access:Lane_addon_sources.Operator_configuration in
           Http.Response.json_value ~compress:true ~request:req
             (Server_skill_editor.authoring_tools_to_yojson descriptors) reqd)
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/skills/editor/preview-new" (fun state _agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body_str ->
             match parse_skill_create_body body_str with
             | Error message -> Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd message
             | Ok { expected_kind; source_id; package_id; source_text } ->
               (match Server_skill_editor.preview_new
                 ~expected_kind:(Some expected_kind)
                 ~descriptors:(Server_skill_editor.authoring_descriptors
                   ~config:(Mcp_server.workspace_config state) ~access:Lane_addon_sources.Operator_configuration)
                 ~source_id ~package_id source_text with
                | Error error -> respond_skill_editor_error ~request:req reqd error
                | Ok preview -> Http.Response.json_value ~compress:true ~request:req
                    (`Assoc [ "ok", `Bool true; "status", `String "valid"
                            ; "preview", Server_skill_editor.preview_to_yojson preview ]) reqd)))
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/skills/editor/create" (fun state agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body_str ->
             match parse_skill_create_body body_str with
             | Error message ->
               Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd message
             | Ok { expected_kind; source_id; package_id; source_text } ->
               let base_path = (Mcp_server.workspace_config state).base_path in
               let refresh () =
                 match Runtime.load_config_observation () with
                 | Error message -> Error message
                 | Ok observation ->
                   Server_skill_snapshot_runtime.refresh_from_observation
                     ~base_path
                     observation
                   |> Result.map_error Server_skill_snapshot_runtime.error_to_string
               in
               (match
                  Server_skill_editor.create
                    ~expected_kind:(Some expected_kind)
                    ~descriptors:(Server_skill_editor.authoring_descriptors
                      ~config:(Mcp_server.workspace_config state) ~access:Lane_addon_sources.Operator_configuration)
                    ~base_path
                    ~source_id
                    ~package_id
                    ~source_text
                    ~refresh
                with
                | Error error ->
                  let audit =
                    audit_skill_create_attempt
                      state
                      agent_name
                      ~source_id
                      ~package_id
                      ~source_text
                      ~error
                  in
                  respond_skill_editor_error ?audit ~request:req reqd error
                | Ok outcome ->
                  let preview, status, audit_outcome =
                    match outcome with
                    | Server_skill_editor.Created_and_published
                        { preview; snapshot_revision = _ } ->
                      preview, "created_and_published", Audit_log.Success
                    | Created_but_shadowed { preview; snapshot_revision = _; winner = _ } ->
                      preview, "created_but_shadowed", Audit_log.Success
                    | Created_but_unpublished { preview; reason } ->
                      preview, "created_but_unpublished", Audit_log.Failure reason
                  in
                  let audit =
                    audit_skill_write
                      state
                      agent_name
                      ~reference:preview.profile.reference
                      ~source_text
                      ~status
                      ~outcome:audit_outcome
                  in
                  Http.Response.json_value
                    ~compress:true
                    ~request:req
                    (with_skill_audit_status
                       (Some audit)
                       (Server_skill_editor.create_outcome_to_yojson outcome))
                    reqd)))
  |> Server_route.add (Server_route.Token_permission Masc_domain.CanAdmin)
       ~path:"/api/v1/skills/editor"
       ~methods:[ `DELETE ]
       (fun state agent_name req reqd ->
             Http.Request.read_body_async reqd (fun body_str ->
               match parse_skill_editor_body body_str with
               | Error message ->
                 Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd message
               | Ok { reference; source_text = _; confirmed } ->
                 let base_path = (Mcp_server.workspace_config state).base_path in
                 let refresh () =
                   match Runtime.load_config_observation () with
                   | Error message -> Error message
                   | Ok observation ->
                     Server_skill_snapshot_runtime.refresh_from_observation
                       ~base_path
                       observation
                     |> Result.map_error Server_skill_snapshot_runtime.error_to_string
                 in
                 let result =
                   Server_skill_editor.delete
                     ~base_path
                     ~reference
                     ~confirmed:(Option.value confirmed ~default:false)
                     ~refresh
                 in
                 Eio.Cancel.protect (fun () ->
                  match result with
                  | Error error ->
                    audit_skill_delete state agent_name
                      ~details:
                        (skill_delete_audit_details ~reference
                           ~status:(Server_skill_editor.error_code error)
                           ~recovery:(skill_error_recovery error)
                           ~package_directory:None)
                      ~outcome:
                        (Audit_log.Failure (Server_skill_editor.error_to_string error));
                    respond_skill_editor_error ~request:req reqd error
                  | Ok outcome ->
                    let audit_outcome, details = skill_delete_audit_of_outcome outcome in
                    audit_skill_delete state agent_name ~details ~outcome:audit_outcome;
                    Http.Response.json_value
                      ~compress:true
                      ~request:req
                      (Server_skill_editor.delete_outcome_to_yojson outcome)
                      reqd))
             )
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/skills/editor/read" (fun state _agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body_str ->
             match parse_skill_editor_body body_str with
             | Error message ->
               Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd message
             | Ok { reference; source_text = _; confirmed = _ } ->
               (match
                  Server_skill_editor.load
                    ~base_path:(Mcp_server.workspace_config state).base_path
                    reference
                with
                | Ok loaded ->
                  Http.Response.json_value
                    ~compress:true
                    ~request:req
                    (Server_skill_editor.loaded_to_yojson loaded)
                    reqd
                | Error error -> respond_skill_editor_error ~request:req reqd error)))
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/skills/editor/preview" (fun state _agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body_str ->
             match parse_skill_editor_body body_str with
             | Error message ->
               Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd message
             | Ok { reference; source_text = None; confirmed = _ } ->
               Keeper_api_types.respond_error
                 ~status:`Bad_request
                 ~request:req
                 reqd
                 "source_text required"
             | Ok { reference; source_text = Some source_text; confirmed = _ } ->
               (match
                  Server_skill_editor.preview
                    ~descriptors:(Server_skill_editor.authoring_descriptors
                      ~config:(Mcp_server.workspace_config state) ~access:Lane_addon_sources.Operator_configuration)
                    ~base_path:(Mcp_server.workspace_config state).base_path
                    reference
                    ~source_text
                with
                | Ok preview ->
                  Http.Response.json_value
                    ~compress:true
                    ~request:req
                    (`Assoc
                      [ "ok", `Bool true
                      ; "status", `String "valid"
                      ; "preview", Server_skill_editor.preview_to_yojson preview
                      ])
                    reqd
                | Error error -> respond_skill_editor_error ~request:req reqd error)))
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/skills/editor/save" (fun state agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body_str ->
             match parse_skill_editor_body body_str with
             | Error message ->
               Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd message
             | Ok { reference; source_text = None; confirmed = _ } ->
               Keeper_api_types.respond_error
                 ~status:`Bad_request
                 ~request:req
                 reqd
                 "source_text required"
             | Ok { reference; source_text = Some source_text; confirmed = _ } ->
               let base_path = (Mcp_server.workspace_config state).base_path in
               let refresh () =
                 match Runtime.load_config_observation () with
                 | Error message -> Error message
                 | Ok observation ->
                   Server_skill_snapshot_runtime.refresh_from_observation
                     ~base_path
                     observation
                   |> Result.map_error Server_skill_snapshot_runtime.error_to_string
               in
               (match
                  Server_skill_editor.save
                    ~descriptors:(Server_skill_editor.authoring_descriptors
                      ~config:(Mcp_server.workspace_config state) ~access:Lane_addon_sources.Operator_configuration)
                    ~base_path
                    ~reference
                    ~source_text
                    ~refresh
                with
                | Error error ->
                  let audit =
                    audit_skill_write state agent_name ~reference ~source_text
                      ~status:(Server_skill_editor.error_code error)
                      ~outcome:(Audit_log.Failure (Server_skill_editor.error_to_string error))
                  in
                  respond_skill_editor_error ~audit ~request:req reqd error
                | Ok outcome ->
                  let status, audit_outcome =
                    match outcome with
                    | Server_skill_editor.Unchanged _ ->
                      "unchanged", Audit_log.Success
                    | Saved_and_published _ ->
                      "saved_and_published", Audit_log.Success
                    | Saved_but_unpublished { reason; _ } ->
                      "saved_but_unpublished", Audit_log.Failure reason
                  in
                  let audit =
                    audit_skill_write state agent_name ~reference ~source_text
                      ~status
                      ~outcome:audit_outcome
                  in
                  Http.Response.json_value
                    ~compress:true
                    ~request:req
                    (with_skill_audit_status
                       (Some audit)
                       (Server_skill_editor.save_outcome_to_yojson outcome))
                    reqd)))
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/skills/refresh" (fun state agent_name req reqd ->
           let base_path = (Mcp_server.workspace_config state).base_path in
           match Runtime.load_config_observation () with
           | Error message ->
             Keeper_api_types.respond_error ~status:`Internal_server_error ~request:req reqd message
           | Ok observation ->
             (match
                Server_skill_snapshot_runtime.refresh_from_observation
                  ~base_path
                  observation
              with
              | Error error ->
                Keeper_api_types.respond_error
                  ~status:`Internal_server_error
                  ~request:req
                  reqd
                  (Server_skill_snapshot_runtime.error_to_string error)
              | Ok publication ->
                let snapshot =
                  match publication with
                  | Skill_catalog_snapshot_service.Published s
                  | Skill_catalog_snapshot_service.Unchanged s -> Some s
                  | Skill_catalog_snapshot_service.Workspace_retired -> None
                in
                let snapshot_revision =
                  match snapshot with
                  | Some s ->
                    Skill_catalog_snapshot.snapshot_revision_to_string
                      (Skill_catalog_snapshot.snapshot_revision s)
                  | None -> ""
                in
                let publication_status =
                  match publication with
                  | Skill_catalog_snapshot_service.Published _ -> "published"
                  | Skill_catalog_snapshot_service.Unchanged _ -> "unchanged"
                  | Skill_catalog_snapshot_service.Workspace_retired -> "retired"
                in
                Log.Server.info
                  "Skill snapshot refreshed by operator=%s revision=%s status=%s"
                  agent_name
                  snapshot_revision
                  publication_status;
                Http.Response.json_value
                  ~compress:true
                  ~request:req
                  (`Assoc
                     [ "ok", `Bool true
                     ; "snapshot_revision", `String snapshot_revision
                     ; "publication", `String publication_status
                     ])
                  reqd))

module For_testing = struct
  let skill_delete_audit_of_outcome = skill_delete_audit_of_outcome
end
