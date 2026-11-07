(* server_routes_http_routes_runtime_config — HTTP routes that edit runtime.toml
   from the dashboard.

   The raw source (read, preview, save), the fusion table, memory recall,
   routing, Keeper assignment, the model setup resume, and the [tui]
   preferences. Server_routes_http_routes_dashboard.add_routes registers this
   group in the middle of its own pipeline. *)

open Server_runtime_config_editor

module Http = Http_server_eio
module Runtime_request = Server_dashboard_runtime_request
module Keeper_api_types = Server_dashboard_http_keeper_api_types

(* RFC fusion-seat-routes §2.5 — the typed fusion write. The client sends the
   revision it read with the settings; the edit re-checks it inside the config
   lock, so a write that landed in between is refused rather than overwritten. *)
let parse_fusion_edit_body body_str =
  Result.bind (Server_json_object_body.fields body_str) (fun fields ->
    (match
       List.find_opt
         (fun (key, _) -> not (List.mem key [ "expected_revision"; "operation" ]))
         fields
     with
     | Some (key, _) -> Error (Printf.sprintf "unknown key %S" key)
     | None ->
       (match List.assoc_opt "expected_revision" fields, List.assoc_opt "operation" fields with
        | Some (`String revision), Some operation ->
          Result.map
            (fun operation -> revision, operation)
            (Fusion_config_edit.operation_of_yojson operation)
        | Some (`String _), None -> Error "operation required"
        | Some _, _ -> Error "expected_revision must be a string"
        | None, _ -> Error "expected_revision required")))
;;

let runtime_config_source_text fields =
  match List.filter (fun (key, _) -> String.equal key "source_text") fields with
  | [_, `String source_text] -> Ok source_text
  | [_] -> Error "source_text must be a string"
  | [] -> Error "source_text required"
  | _ -> Error "source_text must occur exactly once"

let parse_runtime_config_raw_body body_str =
  Result.bind (Server_json_object_body.fields body_str) runtime_config_source_text

let parse_runtime_config_raw_save_body body_str =
  let open Result.Syntax in
  let* fields = Server_json_object_body.fields body_str in
  let* source_text = runtime_config_source_text fields in
  (* Require one revision: duplicate revision fields cannot identify an editor base. *)
  let* revision = match List.filter (fun (key, _) -> String.equal key "expected_source_revision") fields with
   | [_, `String revision] when String_util.is_lowercase_sha256_hex revision -> Ok revision
   | [] -> Error "expected_source_revision required"
   | [_] -> Error "expected_source_revision must be lowercase SHA-256 hex"
   | _ -> Error "expected_source_revision must occur exactly once" in
  let* path = match List.filter (fun (key, _) -> String.equal key "expected_source_path") fields with
   | [_, `String path] when path <> "" && not (String.contains path '\000') -> Ok path
   | [] -> Error "expected_source_path required"
   | [_] -> Error "expected_source_path must be a nonempty path without NUL"
   | _ -> Error "expected_source_path must occur exactly once" in
  Ok (source_text, revision, path)
;;

let runtime_config_path_error_status message =
  if String.equal message Runtime.runtime_config_path_missing_message
  then `Not_found
  else `Internal_server_error

let keeper_validation_error_message report =
  match
    List.find_opt
      (fun issue -> issue.Keeper_runtime_config.severity = Keeper_runtime_config.Error)
      report.Keeper_runtime_config.issues
  with
  | Some issue -> Printf.sprintf "%s: %s" issue.key issue.detail
  | None -> "Keeper runtime setting validation failed"
;;

let respond_keeper_validation_error ~request reqd report =
  Http.Response.json_value
    ~status:`Bad_request
    ~request
    (`Assoc
      [ "ok", `Bool false
      ; "error", `String (keeper_validation_error_message report)
      ; "validation", Keeper_runtime_config.validation_report_to_yojson report
      ; "keeper_setting_schema", Keeper_runtime_config.setting_schema_to_yojson ()
      ])
    reqd
;;

let handle_runtime_config_raw_post state agent_name req reqd body_str =
  match parse_runtime_config_raw_save_body body_str with
  | Error msg ->
    Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd msg
  | Ok (source_text, expected_source_revision, expected_source_path) ->
    (* Audit metadata excludes the source, which can contain provider secrets. *)
    (match Keeper_runtime_config.validate_source_text source_text with
     | Error msg ->
       audit_runtime_config_write state agent_name
         ~operation:Runtime_config_raw_save ~text:source_text
         ~outcome:(Audit_log.Failure msg) ();
       Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd
         ("runtime config parse failed: " ^ msg)
     | Ok report when not (Keeper_runtime_config.validation_report_is_valid report) ->
       let detail = keeper_validation_error_message report in
       audit_runtime_config_write state agent_name
         ~operation:Runtime_config_raw_save ~text:source_text
         ~outcome:(Audit_log.Failure detail) ();
       respond_keeper_validation_error ~request:req reqd report
     | Ok _ ->
       (match Runtime.save_config_text_if_current ~expected_source_path ~expected_source_revision source_text with
        | Error (Runtime.Config_edit_failed msg) ->
          audit_runtime_config_write state agent_name
            ~operation:Runtime_config_raw_save ~text:source_text
            ~outcome:(Audit_log.Failure msg) ();
          Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd msg
        | Error (Runtime.Config_source_conflict current) ->
          Http.Response.json_value ~status:`Conflict ~request:req
            (`Assoc
              [ "error", `String "runtime configuration changed; reload before saving"
              ; "code", `String "revision_conflict"
              ; "current", `Assoc
                  [ "source_path", `String current.path
                  ; "source_text", `String current.source_text
                  ; "source_revision", `String
                      (Runtime.config_source_revision_to_string current.source_revision)
                  ]
              ]) reqd
        | Ok receipt ->
          respond_runtime_config_commit state agent_name
            ~operation:Runtime_config_raw_save ~receipt req reqd))
;;

let handle_runtime_assignment_post_with ~set_assignment state agent_name req reqd
    body_str =
  match Runtime_request.parse_runtime_assignment_body body_str with
  | Error msg ->
    Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd msg
  | Ok (keeper_name, runtime_id, expected) ->
    (match
       set_assignment
         ~runtime_config_path:
           (Config_dir_resolver.runtime_toml_path_for_base_path
              ~base_path:
                (Mcp_server.workspace_config state).Workspace.base_path)
         ~keeper_name ~runtime_id ~expected ()
     with
     | Error (Runtime.Assignment_io_error msg) ->
       audit_runtime_config_write state agent_name
         ~operation:(Runtime_config_assignment (keeper_name, runtime_id))
         ~text:body_str ~outcome:(Audit_log.Failure msg) ();
       Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd msg
     | Error (Runtime.Assignment_revision_conflict observed) ->
       audit_runtime_config_write state agent_name
         ~operation:(Runtime_config_assignment (keeper_name, runtime_id))
         ~text:body_str
         ~outcome:(Audit_log.Failure "runtime assignment revision conflict")
         ();
       Http.Response.json_value ~status:`Conflict ~request:req
         (`Assoc
            [ "ok", `Bool false
            ; ( "error"
              , `Assoc
                  [ "code", `String "runtime_assignment_revision_conflict"
                  ; "expected", Runtime.keeper_assignment_revision_to_yojson expected
                  ; "observed", Runtime.keeper_assignment_revision_to_yojson observed
                  ] )
            ])
         reqd
     | Ok locked ->
       (match locked.Runtime.value with
        | Runtime.Assignment_unchanged revision ->
          audit_runtime_config_write state agent_name
            ~operation:(Runtime_config_assignment (keeper_name, runtime_id))
            ~text:body_str ~outcome:Audit_log.Success ();
          Http.Response.json_value ~request:req
            (`Assoc
               [ "ok", `Bool true
               ; "applied", `Bool false
               ; "assignment_revision", Runtime.keeper_assignment_revision_to_yojson revision
               ; ( "warnings"
                 , `List
                     (List.map Runtime.config_lock_warning_to_yojson
                        locked.warnings) )
               ])
            reqd
        | Runtime.Assignment_committed { receipt; _ } ->
          respond_runtime_config_commit state agent_name
            ~operation:(Runtime_config_assignment (keeper_name, runtime_id))
            ~receipt req reqd))

let handle_runtime_assignment_post state agent_name req reqd body_str =
  handle_runtime_assignment_post_with
    ~set_assignment:(fun ~runtime_config_path ~keeper_name ~runtime_id
                          ~expected () ->
      Runtime.set_keeper_assignment_if_revision ~runtime_config_path
        ~keeper_name ~runtime_id ~expected ())
    state agent_name req reqd body_str

(* GET /api/v1/tui/preferences, after authentication: the [tui] settings of
   the runtime.toml this server writes. *)
let handle_tui_preferences_get state req reqd =
  let base_path = (Mcp_server.workspace_config state).Workspace.base_path in
  Http.Response.json_value ~request:req
    (Tui_preference.settings_to_yojson
       (Tui_preference.read_settings
          ~path:(Config_dir_resolver.runtime_toml_path_for_base_path ~base_path)))
    reqd

(* POST /api/v1/tui/preferences, after authentication: one change to the
   [tui] table of runtime.toml, parsed at the door (RFC-0482 §3.1). The edit
   goes through Runtime's config write lock and commit, so the commit
   announces runtime_config_changed like every other save. A change that
   leaves the text as it is -- a second visit to the same chat, a hint
   already retired -- writes, audits and announces nothing. The [tui] keys
   are not read by the Skill catalog, so, as when the terminal wrote them
   itself, the commit does not republish it. The answer carries the commit
   receipt and not the file: the reader already holds its choice. *)
let handle_tui_preference_post state agent_name req reqd body_str =
  match
    match Yojson.Safe.from_string body_str with
    | json -> Tui_preference.change_of_yojson json
    | exception Yojson.Json_error detail -> Error ("invalid JSON: " ^ detail)
  with
  | Error msg -> Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd msg
  | Ok change ->
    let operation = Runtime_config_tui_preference change in
    let base_path = (Mcp_server.workspace_config state).Workspace.base_path in
    (match
       Runtime.edit_config_text_if_changed
         ~runtime_config_path:(Config_dir_resolver.runtime_toml_path_for_base_path ~base_path)
         (Tui_preference.edit change)
     with
     | Error msg ->
       audit_runtime_config_write state agent_name ~operation ~text:body_str
         ~outcome:(Audit_log.Failure msg) ();
       Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd msg
     | Ok (Runtime.Config_text_unchanged { observation; lock_warnings }) ->
       Http.Response.json_value ~request:req
         (`Assoc
            [ "ok", `Bool true
            ; "state", `String "unchanged"
            ; "change", Tui_preference.change_to_yojson change
            ; ( "source_revision"
              , `String (Runtime.config_source_revision_to_string observation.source_revision) )
            ; "warnings", `List (List.map Runtime.config_lock_warning_to_yojson lock_warnings)
            ])
         reqd
     | Ok (Runtime.Config_text_committed receipt) ->
       let observation = receipt.Runtime.observation in
       Eio.Cancel.protect (fun () ->
         audit_runtime_config_write state agent_name ~path:observation.path ~receipt ~operation
           ~text:observation.source_text ~outcome:Audit_log.Success ());
       Http.Response.json_value ~request:req
         (`Assoc
            [ "ok", `Bool true
            ; "state", `String "committed"
            ; "change", Tui_preference.change_to_yojson change
            ; "commit", Runtime.config_commit_receipt_to_yojson receipt
            ])
         reqd)

(* POST /api/v1/runtime/config/routing, after authentication: one routing
   body, parsed to a variant, answered by the Runtime writer it names. *)
let handle_runtime_routing_post state agent_name req reqd body_str =
  let open Runtime_request in
  match parse_runtime_route_body body_str with
  | Error msg ->
    Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd msg
  | Ok (Runtime_route_runtime_id (Runtime_default, Some runtime_id)) ->
    (match Runtime.set_runtime_default ~runtime_id () with
     | Error msg ->
       audit_runtime_config_write state agent_name
         ~operation:(Runtime_config_routing (Runtime_default, Some runtime_id))
         ~text:body_str
         ~outcome:(Audit_log.Failure msg) ();
       Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd msg
     | Ok receipt ->
       respond_runtime_config_commit state agent_name
         ~operation:(Runtime_config_routing (Runtime_default, Some runtime_id))
         ~receipt req reqd)
  | Ok (Runtime_route_runtime_id (Runtime_default, None)) ->
    Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd
      "default runtime_id required"
  | Ok (Runtime_route_runtime_id (Runtime_media_failover, _)) ->
    Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd
      "media_failover runtime_ids required"
  | Ok (Runtime_route_runtime_ids (Runtime_media_failover, runtime_ids)) ->
    (match Runtime.set_runtime_media_failover ~runtime_ids () with
     | Error msg ->
       audit_runtime_config_write state agent_name
         ~operation:
           (Runtime_config_routing_list (Runtime_media_failover, runtime_ids))
         ~text:body_str
         ~outcome:(Audit_log.Failure msg) ();
       Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd msg
     | Ok receipt ->
       respond_runtime_config_commit state agent_name
         ~operation:
           (Runtime_config_routing_list (Runtime_media_failover, runtime_ids))
         ~receipt req reqd)
  | Ok (Runtime_route_runtime_id (Runtime_named_lane lane_id, _)) ->
    Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd
      (Printf.sprintf "%s runtime_ids required" lane_id)
  | Ok (Runtime_route_runtime_ids (Runtime_named_lane lane_id, runtime_ids))
    ->
    (match Runtime.set_runtime_lane_candidates ~lane_id ~runtime_ids () with
     | Error error ->
       let msg = Runtime.lane_set_error_to_string error in
       audit_runtime_config_write state agent_name
         ~operation:
           (Runtime_config_routing_list
              (Runtime_named_lane lane_id, runtime_ids))
         ~text:body_str
         ~outcome:(Audit_log.Failure msg) ();
       Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd msg
     | Ok receipt ->
       respond_runtime_config_commit state agent_name
         ~operation:
           (Runtime_config_routing_list
              (Runtime_named_lane lane_id, runtime_ids))
         ~receipt req reqd)
  | Ok (Runtime_route_named_lane_set_if_revision (lane_id, runtime_ids, revision)) ->
    let operation = Runtime_config_routing_list (Runtime_named_lane lane_id, runtime_ids) in
    (match Runtime.set_runtime_lane_candidates ~lane_id ~runtime_ids
             ~expected_source_revision:revision () with
     | Error error ->
       let msg = Runtime.lane_set_error_to_string error in
       audit_runtime_config_write state agent_name ~operation ~text:body_str
         ~outcome:(Audit_log.Failure msg) ();
       Keeper_api_types.respond_error
         ~status:(match error with
                  | Runtime.Lane_set_revision_conflict _ -> `Conflict
                  | Runtime.Lane_set_invalid _ -> `Bad_request)
         ~request:req reqd msg
     | Ok receipt ->
       respond_runtime_config_commit state agent_name ~operation ~receipt req reqd)
  | Ok (Runtime_route_runtime_id (Runtime_exact_lane _, _)) ->
    Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd
      "exact-output lane runtime_ids required"
  | Ok (Runtime_route_runtime_ids (Runtime_exact_lane exact, slots))
    ->
    (match Runtime.set_exact_output_lane_slots ~lane:exact ~slots () with
     | Error msg ->
       audit_runtime_config_write state agent_name
         ~operation:
           (Runtime_config_routing_list
              (Runtime_exact_lane exact, slots))
         ~text:body_str
         ~outcome:(Audit_log.Failure msg) ();
       Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd msg
     | Ok receipt ->
       respond_runtime_config_commit state agent_name
         ~operation:
           (Runtime_config_routing_list
              (Runtime_exact_lane exact, slots))
         ~receipt req reqd)
  | Ok (Runtime_route_runtime_ids (lane, _)) ->
    Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd
      (Printf.sprintf
         "%s runtime_id required"
         (runtime_route_lane_to_string lane))
  | Ok (Runtime_route_lane_created (lane_id, runtime_ids)) ->
    let operation = Runtime_config_lane_created (lane_id, runtime_ids) in
    (match Runtime.create_runtime_lane ~lane_id ~runtime_ids () with
     | Error msg ->
       audit_runtime_config_write state agent_name ~operation ~text:body_str
         ~outcome:(Audit_log.Failure msg) ();
       Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd msg
     | Ok receipt ->
       respond_runtime_config_commit state agent_name ~operation ~receipt req reqd)
  | Ok (Runtime_route_lane_removed lane_id) ->
    let operation = Runtime_config_lane_removed lane_id in
    (match Runtime.remove_runtime_lane ~lane_id () with
     | Error msg ->
       audit_runtime_config_write state agent_name ~operation ~text:body_str
         ~outcome:(Audit_log.Failure msg) ();
       Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd msg
     | Ok receipt ->
       respond_runtime_config_commit state agent_name ~operation ~receipt req reqd)
  | Ok (Runtime_route_lane_renamed (lane_id, new_lane_id)) ->
    let operation = Runtime_config_lane_renamed (lane_id, new_lane_id) in
    (match Runtime.rename_runtime_lane ~lane_id ~new_lane_id () with
     | Error msg ->
       audit_runtime_config_write state agent_name ~operation ~text:body_str
         ~outcome:(Audit_log.Failure msg) ();
       Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd msg
     | Ok receipt ->
       respond_runtime_config_commit state agent_name ~operation ~receipt req reqd)
  | Ok (Runtime_route_exact_slot_appended (exact, runtime_id)) ->
    let operation = Runtime_config_exact_slot_appended (exact, runtime_id) in
    (match Runtime.append_exact_output_lane_slot ~lane:exact ~slot:runtime_id () with
     | Error msg ->
       audit_runtime_config_write state agent_name ~operation ~text:body_str
         ~outcome:(Audit_log.Failure msg) ();
       Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd msg
     | Ok receipt ->
       respond_runtime_config_commit state agent_name ~operation ~receipt req reqd)
  | Ok (Runtime_route_exact_slot_dropped (exact, runtime_id)) ->
    let operation = Runtime_config_exact_slot_dropped (exact, runtime_id) in
    (match Runtime.drop_exact_output_lane_slot ~lane:exact ~slot:runtime_id () with
     | Error msg ->
       audit_runtime_config_write state agent_name ~operation ~text:body_str
         ~outcome:(Audit_log.Failure msg) ();
       Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd msg
     | Ok receipt ->
       respond_runtime_config_commit state agent_name ~operation ~receipt req reqd)
  | Ok (Runtime_route_exact_slot_moved (exact, runtime_id, move)) ->
    let operation = Runtime_config_exact_slot_moved (exact, runtime_id, move) in
    (match
       Runtime.move_exact_output_lane_slot ~lane:exact ~slot:runtime_id ~move ()
     with
     | Error msg ->
       audit_runtime_config_write state agent_name ~operation ~text:body_str
         ~outcome:(Audit_log.Failure msg) ();
       Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd msg
     | Ok receipt ->
       respond_runtime_config_commit state agent_name ~operation ~receipt req reqd)
  | Ok (Runtime_route_exact_slot_replaced (exact, runtime_id, replacement)) ->
    let operation = Runtime_config_exact_slot_replaced (exact, runtime_id, replacement) in
    (match Runtime.replace_exact_output_lane_slot ~lane:exact ~slot:runtime_id ~replacement () with
     | Error msg ->
       audit_runtime_config_write state agent_name ~operation ~text:body_str
         ~outcome:(Audit_log.Failure msg) ();
       Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd msg
     | Ok receipt ->
       respond_runtime_config_commit state agent_name ~operation ~receipt req reqd)

let add_routes router =
  router
  |> Server_route.get (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/runtime/config/raw" (fun _state _agent_name req reqd ->
           match Runtime.load_config_observation () with
           | Ok observation ->
             Http.Response.json_value ~compress:true ~request:req
               (runtime_config_raw_json
                  ~source_revision:observation.source_revision
                  ~path:observation.path
                  ~source_text:observation.source_text
                  ~operation:"read"
                  ~routing_applied_at:None
                  ())
               reqd
           | Error msg ->
             Keeper_api_types.respond_error
               ~status:(runtime_config_path_error_status msg)
               ~request:req reqd msg)
  (* RFC-0306 §3.1 — typed read of the active fusion config for the settings
     editor. [Fusion_config_loader.load] returns [Ok disabled] when runtime.toml
     or its [fusion] section is absent, and [Error] only when an existing section
     fails to parse/validate (a broken on-disk config), which surfaces as 500. *)
  |> Server_route.get (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/runtime/config/fusion" (fun state _agent_name req reqd ->
           let base_path = (Mcp_server.workspace_config state).base_path in
           let runtime_config_path = Fusion_config_loader.runtime_toml_path ~base_path in
           (* The config and its revision come from one read, so the revision a
              client sends back names exactly the text it was shown. *)
           match Runtime.load_config_observation ~runtime_config_path () with
           | Error msg ->
             Keeper_api_types.respond_error
               ~status:(runtime_config_path_error_status msg)
               ~request:req reqd msg
           | Ok observation ->
             (match Otoml.Parser.from_string observation.source_text with
              | exception Otoml.Parse_error (_, msg) ->
                Keeper_api_types.respond_error ~status:`Internal_server_error ~request:req reqd
                  ("runtime.toml parse error: " ^ msg)
              | toml ->
                (match Fusion_config.of_toml toml with
                 | Ok config ->
                   Http.Response.json_value ~compress:true ~request:req
                     (`Assoc
                       [ ("generated_at", `String (Masc_domain.now_iso ()))
                       ; ( "source_revision"
                         , `String
                             (Runtime.config_source_revision_to_string
                                observation.source_revision) )
                       ; ("config", Fusion_config_json.to_yojson config)
                       ])
                     reqd
                 | Error errors ->
                   Keeper_api_types.respond_error ~status:`Internal_server_error ~request:req reqd
                     ("fusion config invalid: "
                      ^ String.concat "; "
                          (List.map Fusion_config.config_error_message errors)))))
  (* The memory recall gate as this server reads it now, per declared Keeper
     (see [Server_memory_recall_standing]): a settings form shows what a choice
     would change, and this is what stands today. *)
  |> Server_route.get (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/runtime/config/memory-recall" (fun state _agent_name req reqd ->
           let base_path = (Mcp_server.workspace_config state).base_path in
           let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
           match Server_memory_recall_standing.read ~keepers_dir with
           | Error detail ->
             Keeper_api_types.respond_error ~status:`Internal_server_error ~request:req reqd
               ("keeper declarations could not be read: " ^ detail)
           | Ok standing ->
             Http.Response.json_value ~compress:true ~request:req
               (Server_memory_recall_standing.to_yojson
                  ~generated_at:(Masc_domain.now_iso ())
                  standing)
               reqd)
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/runtime/config/fusion" (fun state agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body_str ->
             match parse_fusion_edit_body body_str with
             | Error msg ->
               Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd msg
             | Ok (expected_revision, operation) ->
               let base_path = (Mcp_server.workspace_config state).base_path in
               let runtime_config_path =
                 Fusion_config_loader.runtime_toml_path ~base_path
               in
               let audit_operation =
                 Runtime_config_fusion (Fusion_config_edit.operation_label operation)
               in
               (match
                  Fusion_config_edit.apply ~runtime_config_path ~expected_revision operation
                with
                | Ok receipt ->
                  respond_runtime_config_commit state agent_name ~operation:audit_operation
                    ~receipt req reqd
                | Error error ->
                  audit_runtime_config_write state agent_name ~operation:audit_operation
                    ~text:body_str
                    ~outcome:(Audit_log.Failure (Fusion_config_edit.error_message error))
                    ();
                  let status =
                    match error with
                    | Fusion_config_edit.Configuration_changed -> `Conflict
                    | Fusion_config_edit.Configuration_unavailable _ -> `Internal_server_error
                    | Fusion_config_edit.Preset_invalid _
                    | Fusion_config_edit.Route_unresolved _
                    | Fusion_config_edit.Name_invalid _
                    | Fusion_config_edit.Default_preset_deleted _
                    | Fusion_config_edit.Edit_refused _
                    | Fusion_config_edit.Fusion_invalid _
                    | Fusion_config_edit.Configuration_rejected _ -> `Bad_request
                  in
                  Http.Response.json_value ~status ~request:req
                    (`Assoc
                       [ "ok", `Bool false
                       ; "error", Fusion_config_edit.error_to_yojson error
                       ])
                    reqd)))
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/runtime/config/raw/preview" (fun _state _agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body_str ->
             match parse_runtime_config_raw_body body_str with
             | Error msg ->
               Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd msg
             | Ok source_text ->
               (match Keeper_runtime_config.validate_source_text source_text with
                | Error msg ->
                  Keeper_api_types.respond_error
                    ~status:`Bad_request
                    ~request:req
                    reqd
                    ("runtime config parse failed: " ^ msg)
                | Ok report ->
                  let schema_ok =
                    Keeper_runtime_config.validation_report_is_valid report
                  in
                  (* The raw-save path (Runtime.save_config_text) rejects text
                     that parses and passes the keeper schema but fails the
                     runtime parser. Run that same precondition here so can_save
                     cannot advertise a save guaranteed to fail. Mirror the save
                     order: the runtime check only runs once the schema is
                     valid. *)
                  let runtime_error =
                    if schema_ok
                    then (
                      match Runtime.validate_config_text source_text with
                      | Ok () -> None
                      | Error msg -> Some msg)
                    else None
                  in
                  let can_save = schema_ok && Option.is_none runtime_error in
                  Http.Response.json_value
                    ~compress:true
                    ~request:req
                    (`Assoc
                      [ "ok", `Bool true
                      ; "can_save", `Bool can_save
                      ; "validation", Keeper_runtime_config.validation_report_to_yojson report
                      ; ( "runtime_validation"
                        , match runtime_error with
                          | None -> `Null
                          | Some msg -> `String msg )
                      ; "keeper_setting_schema", Keeper_runtime_config.setting_schema_to_yojson ()
                      ])
                    reqd)))
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/runtime/setup/resume" (fun state _agent_name req reqd ->
           match Server_model_setup_resume.request
             ~base_path:(Mcp_server.workspace_config state).base_path with
           | Error error -> Keeper_api_types.respond_error ~status:`Service_unavailable
               ~request:req reqd (Server_model_setup_resume.error_message error)
           | Ok authority_available -> Server_auth.respond_json_value_with_cors req reqd
               (`Assoc ["runtime_ready", `Bool true;
                 "exact_output_authority_available", `Bool authority_available;
                 "model_setup", Runtime_startup_state.to_json ()]))
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/runtime/config/raw" (fun state agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body_str ->
             handle_runtime_config_raw_post state agent_name req reqd body_str))
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/runtime/config/routing" (fun state agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body_str ->
             handle_runtime_routing_post state agent_name req reqd body_str
           )
         )
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/runtime/config/assignment" (fun state agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body_str ->
             handle_runtime_assignment_post state agent_name req reqd body_str
           )
         )
  (* RFC-0482 §3.1: a terminal reader starts from the [tui] table the server
     writes, not from whichever runtime.toml its own environment finds. Only
     the settings are sent; the file carries provider configuration. *)
  |> Server_route.get (Server_route.Token_permission Masc_domain.CanReadState) "/api/v1/tui/preferences" (fun state _agent_name req reqd ->
         handle_tui_preferences_get state req reqd)
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/tui/preferences" (fun state agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body_str ->
             handle_tui_preference_post state agent_name req reqd body_str))

module For_testing = struct
  (* The request decoder is private to the server library; the named-lane
     array shape is a wire contract, so the parser test asserts it directly
     instead of through an HTTP round trip. *)
  let lane_string = Runtime_request.runtime_route_lane_to_string

  let parse_runtime_route_body body =
    let open Runtime_request in
    match Runtime_request.parse_runtime_route_body body with
    | Error detail -> Error detail
    | Ok (Runtime_route_runtime_id (lane, runtime_id)) ->
        Ok
          ( lane_string lane
          , "runtime_id"
          , match runtime_id with None -> [] | Some value -> [ value ] )
    | Ok (Runtime_route_runtime_ids (lane, runtime_ids)) ->
        Ok (lane_string lane, "runtime_ids", runtime_ids)
    | Ok (Runtime_route_named_lane_set_if_revision (lane_id, runtime_ids, _)) ->
        Ok (lane_id, "runtime_ids_if_revision", runtime_ids)
    | Ok (Runtime_route_lane_created (lane_id, runtime_ids)) ->
        Ok (lane_id, "create", runtime_ids)
    | Ok (Runtime_route_lane_removed lane_id) -> Ok (lane_id, "remove", [])
    | Ok (Runtime_route_lane_renamed (lane_id, new_lane_id)) ->
        Ok (lane_id, "rename", [ new_lane_id ])
    | Ok (Runtime_route_exact_slot_appended (exact, runtime_id)) ->
        Ok (runtime_route_lane_to_string (Runtime_exact_lane exact), "append", [ runtime_id ])
    | Ok (Runtime_route_exact_slot_dropped (exact, runtime_id)) ->
        Ok (runtime_route_lane_to_string (Runtime_exact_lane exact), "drop", [ runtime_id ])
    | Ok (Runtime_route_exact_slot_replaced (exact, runtime_id, replacement)) ->
        Ok (runtime_route_lane_to_string (Runtime_exact_lane exact), "replace", [runtime_id; replacement])
    | Ok (Runtime_route_exact_slot_moved (exact, runtime_id, move)) ->
        Ok
          ( runtime_route_lane_to_string (Runtime_exact_lane exact)
          , "move"
          , [ runtime_id
            ; (match move with
               | Runtime.Move_slot_up -> "up"
               | Runtime.Move_slot_down -> "down"
               | Runtime.Move_slot_first -> "first")
            ] )

  let handle_runtime_assignment_post = handle_runtime_assignment_post
  let handle_runtime_assignment_post_with = handle_runtime_assignment_post_with
  let handle_runtime_routing_post = handle_runtime_routing_post
  let handle_runtime_config_raw_post = handle_runtime_config_raw_post
  let handle_tui_preference_post = handle_tui_preference_post
  let handle_tui_preferences_get = handle_tui_preferences_get
end
