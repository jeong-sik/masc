(* HTTP routes for prompt presets (#32777).

   GET  /api/v1/presets          — manifests under <base>/.masc/presets
   POST /api/v1/presets          — {name, description?}: snapshot the live state
   POST /api/v1/presets/restore  — {name}: autosave, then apply the preset

   Writes need CanAdmin, like the runtime assignment route. *)

open Server_auth
module Http = Http_server_eio

let base_path_of state = (Mcp_server.workspace_config state).Workspace.base_path

type save_request =
  { name : string
  ; description : string
  }

let name_field fields =
  match List.assoc_opt "name" fields with
  | Some (`String raw) ->
    let name = String.trim raw in
    if Prompt_preset.is_valid_name name then Ok name else Error ("invalid preset name: " ^ raw)
  | Some _ -> Error "name must be a string"
  | None -> Error "name missing"
;;

let object_of_body body =
  match Yojson.Safe.from_string body with
  | `Assoc fields -> Ok fields
  | _ -> Error "body must be a JSON object"
  | exception Yojson.Json_error message -> Error ("invalid JSON: " ^ message)
;;

let decode_save body =
  match object_of_body body with
  | Error _ as error -> error
  | Ok fields ->
    (match name_field fields with
     | Error _ as error -> error
     | Ok name ->
       (match List.assoc_opt "description" fields with
        | None -> Ok { name; description = "" }
        | Some (`String description) -> Ok { name; description }
        | Some _ -> Error "description must be a string"))
;;

let decode_restore body =
  match object_of_body body with
  | Error _ as error -> error
  | Ok fields -> name_field fields
;;

let ok_json fields : Yojson.Safe.t = `Assoc (("ok", `Bool true) :: fields)
let error_json message : Yojson.Safe.t = `Assoc [ "ok", `Bool false; "error", `String message ]

let listing_json (listing : Prompt_preset.listing) =
  ok_json
    [ "presets", `List (List.map Prompt_preset.manifest_to_json listing.Prompt_preset.presets)
    ; ( "unreadable"
      , `List
          (List.map
             (fun (name, reason) -> `Assoc [ "name", `String name; "reason", `String reason ])
             listing.Prompt_preset.unreadable) )
    ]
;;

let add_routes router =
  router
  |> Http.Router.get "/api/v1/presets" (fun request reqd ->
       with_read_auth
         (fun state _req reqd ->
           respond_json_value_with_cors
             request
             reqd
             (listing_json (Prompt_preset.list ~base_path:(base_path_of state))))
         request
         reqd)
  |> Http.Router.post "/api/v1/presets" (fun request reqd ->
       with_permission_auth
         ~permission:Masc_domain.CanAdmin
         (fun state _req reqd ->
           Http.Request.read_body_async reqd (fun body ->
             match decode_save body with
             | Error message ->
               respond_json_value_with_cors ~status:`Bad_request request reqd (error_json message)
             | Ok { name; description } ->
               let base_path = base_path_of state in
               let saved =
                 match Prompt_preset.capture ~base_path ~name ~description with
                 | Error _ as error -> error
                 | Ok snapshot ->
                   (match Prompt_preset.save ~base_path snapshot with
                    | Ok () -> Ok snapshot
                    | Error _ as error -> error)
               in
               (match saved with
                | Ok snapshot ->
                  respond_json_value_with_cors
                    request
                    reqd
                    (ok_json
                       [ ( "preset"
                         , Prompt_preset.manifest_to_json
                             (Prompt_preset.manifest_of_snapshot snapshot) )
                       ])
                | Error message ->
                  Log.Pages.error "preset save %s failed: %s" name message;
                  respond_json_value_with_cors
                    ~status:`Internal_server_error
                    request
                    reqd
                    (error_json message))))
         request
         reqd)
  |> Http.Router.post "/api/v1/presets/restore" (fun request reqd ->
       with_permission_auth
         ~permission:Masc_domain.CanAdmin
         (fun state _req reqd ->
           Http.Request.read_body_async reqd (fun body ->
             match decode_restore body with
             | Error message ->
               respond_json_value_with_cors ~status:`Bad_request request reqd (error_json message)
             | Ok name ->
               (match Prompt_preset.restore ~base_path:(base_path_of state) name with
                | Ok report ->
                  respond_json_value_with_cors
                    request
                    reqd
                    (ok_json [ "report", Prompt_preset.report_to_json report ])
                | Error message ->
                  Log.Pages.error "preset restore %s failed: %s" name message;
                  respond_json_value_with_cors
                    ~status:`Internal_server_error
                    request
                    reqd
                    (error_json message))))
         request
         reqd)
;;
