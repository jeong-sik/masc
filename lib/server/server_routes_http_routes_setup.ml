(* server_routes_http_routes_setup — HTTP routes of the Setup surface.

   The /api/v1/setup/* routes: the inventory, the account emails, models,
   accounts (login, select, removal, remove), context, connections, the
   credential and the status. Server_routes_http_routes_dashboard.add_routes
   registers this group in the middle of its own pipeline. The dashboard
   builder's helper module is Server_routes_http_routes_dashboard_setup, a
   different module. *)

open Server_runtime_config_editor

module Http = Http_server_eio
module Keeper_api_types = Server_dashboard_http_keeper_api_types

(* 409 while the file is not the one the preview read, or no longer allows
   the removal it listed; 503 when it cannot be read. *)
let account_removal_status : Runtime_account_removal_setup.error -> Httpun.Status.t = function
  | Runtime_account_removal_setup.Invalid_request
  | Runtime_account_removal_setup.Save_rejected _ -> `Bad_request
  | Runtime_account_removal_setup.Configuration_unavailable _ -> `Service_unavailable
  | Runtime_account_removal_setup.Configuration_changed
  | Runtime_account_removal_setup.Refused _ -> `Conflict
;;

let add_routes ~sw router =
  router
  |> Server_route.get (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/setup/inventory" (fun state _agent_name req reqd ->
           let base_path=(Mcp_server.workspace_config state).base_path in
           match Runtime_setup_batch.observe_inventory ~base_path with
           | Ok (revision,observation) ->
             (match Runtime_toml.parse_string observation.source_text with
              | Error _ -> Http.Response.json_value ~status:`Bad_request ~request:req
                  (`Assoc ["error", `String "Runtime configuration needs correction."]) reqd
              | Ok config -> Http.Response.json_value ~request:req
                  (match Runtime_wizard_inventory.to_json config with
                   | `Assoc fields -> `Assoc (("setup_revision",`String (Runtime_setup_batch.revision_to_string revision))
                       ::("source_revision",`String (Runtime.config_source_revision_to_string observation.source_revision))
                       ::("account_emails",Runtime_account_email.inventory_json config)::fields)
                   | value -> value) reqd)
           | Error _ -> Http.Response.json_value ~status:`Service_unavailable ~request:req
               (`Assoc ["error", `String "Runtime configuration is unavailable."]) reqd)
  (* The Overview reads this on every refresh, so it carries only the
     emails, for the providers the loaded runtimes run on: the same
     runtimes its Plan usage rows group. An email is personal data, so
     the route needs Admin like the setup inventory. *)
  |> Server_route.get (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/setup/account-emails" (fun _state _agent_name req reqd ->
           let _default_route, default, runtimes = Runtime.get_default_route_and_runtimes () in
           let providers =
             List.fold_left
               (fun providers (runtime : Runtime_instance.t) ->
                  if List.exists
                       (fun (known : Runtime_schema.provider) -> String.equal known.id runtime.provider.id)
                       providers
                  then providers
                  else providers @ [ runtime.provider ])
               []
               (Option.to_list default @ runtimes)
           in
           Http.Response.json_value ~request:req
             (`Assoc [ "account_emails", Runtime_account_email.providers_json providers ])
             reqd)
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/setup/models" (fun state _agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body ->
             let result = match Eio_context.get_net_opt () with
               | None -> Error Server_runtime_setup_actions.Network_unavailable
               | Some net ->
                 (match (try Some (Yojson.Safe.from_string body) with Yojson.Json_error _ -> None) with
                  | None -> Error Server_runtime_setup_actions.Invalid_request
                  | Some json -> Server_runtime_setup_actions.discover ~binary:Sys.executable_name ~sw ~net
                      ~base_path:(Mcp_server.workspace_config state).base_path json) in
             match result with
             | Ok json -> Http.Response.json_value ~request:req json reqd
             | Error error -> Http.Response.json_value ~status:(Server_runtime_setup_actions.status_of_error error) ~request:req
                 (`Assoc ["error",`String (Server_runtime_setup_actions.error_message error)]) reqd))
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/setup/accounts/antigravity" (fun state _agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body ->
             let result = match (try Some (Yojson.Safe.from_string body) with Yojson.Json_error _ -> None) with
               | None -> Error Server_runtime_setup_actions.Invalid_request
               | Some json -> Server_runtime_setup_actions.import_account ~binary:Sys.executable_name
                   ~base_path:(Mcp_server.workspace_config state).base_path json in
             match result with
             | Ok json -> Http.Response.json_value ~request:req json reqd
             | Error error -> Http.Response.json_value ~status:(Server_runtime_setup_actions.status_of_error error) ~request:req
                 (`Assoc ["error",`String (Server_runtime_setup_actions.error_message error)]) reqd))
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/setup/accounts/login" (fun state actor req reqd ->
           Http.Request.read_body_async reqd (fun body ->
             Server_setup_account_login.start ~actor
               ~base_path:(Mcp_server.workspace_config state).base_path ~body req reqd))
  |> Server_route.prefix_get (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/setup/accounts/login/" (fun state actor req reqd ->
           Server_setup_account_login.status ~actor
             ~base_path:(Mcp_server.workspace_config state).base_path req reqd)
  |> Server_route.prefix_post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/setup/accounts/login/" (fun state actor req reqd ->
           Http.Request.read_body_async reqd (fun body ->
             Server_setup_account_login.control ~actor
               ~base_path:(Mcp_server.workspace_config state).base_path ~body req reqd))
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/setup/accounts/select" (fun state _agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body ->
             let result = match (try Some (Yojson.Safe.from_string body) with Yojson.Json_error _ -> None) with
               | None -> Error Server_runtime_setup_actions.Invalid_request
               | Some json -> Server_runtime_setup_actions.select_account
                   ~base_path:(Mcp_server.workspace_config state).base_path json in
             match result with
             | Ok json -> Http.Response.json_value ~request:req json reqd
             | Error error -> Http.Response.json_value ~status:(Server_runtime_setup_actions.status_of_error error) ~request:req
                 (`Assoc ["error",`String (Server_runtime_setup_actions.error_message error)]) reqd))
  (* What removing an account changes, answered with the revision it was
     read at; [/remove] commits it only while the file is still that
     revision. *)
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/setup/accounts/removal" (fun state _agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body ->
             let runtime_config_path =
               Config_dir_resolver.runtime_toml_path_for_base_path
                 ~base_path:(Mcp_server.workspace_config state).base_path
             in
             let result =
               match Yojson.Safe.from_string body with
               | json -> Runtime_account_removal_setup.preview ~runtime_config_path json
               | exception Yojson.Json_error _ -> Error Runtime_account_removal_setup.Invalid_request
             in
             match result with
             | Ok json -> Http.Response.json_value ~request:req json reqd
             | Error error ->
               Keeper_api_types.respond_error ~status:(account_removal_status error) ~request:req reqd
                 (Runtime_account_removal_setup.error_message error)))
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/setup/accounts/remove" (fun state agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body ->
             let runtime_config_path =
               Config_dir_resolver.runtime_toml_path_for_base_path
                 ~base_path:(Mcp_server.workspace_config state).base_path
             in
             let json =
               match Yojson.Safe.from_string body with
               | json -> Some json
               | exception Yojson.Json_error _ -> None
             in
             let integration_id =
               match json with
               | Some (`Assoc fields) ->
                 (match List.assoc_opt "integration_id" fields with
                  | Some (`String id) -> id
                  | Some _ | None -> "")
               | Some _ | None -> ""
             in
             let operation = Runtime_config_account_removal integration_id in
             let result =
               match json with
               | Some json -> Runtime_account_removal_setup.remove ~runtime_config_path json
               | None -> Error Runtime_account_removal_setup.Invalid_request
             in
             match result with
             | Ok receipt -> respond_runtime_config_commit state agent_name ~operation ~receipt req reqd
             | Error error ->
               audit_runtime_config_write state agent_name ~operation ~text:body
                 ~outcome:(Audit_log.Failure (Runtime_account_removal_setup.error_message error)) ();
               Keeper_api_types.respond_error ~status:(account_removal_status error) ~request:req reqd
                 (Runtime_account_removal_setup.error_message error)))
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/setup/context" (fun state _agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body ->
             let result = match Eio_context.get_net_opt () with
               | None -> Error Server_runtime_setup_actions.Network_unavailable
               | Some net ->
                 (match (try Some (Yojson.Safe.from_string body) with Yojson.Json_error _ -> None) with
                  | None -> Error Server_runtime_setup_actions.Invalid_request
                  | Some json -> Server_runtime_setup_actions.context ~binary:Sys.executable_name ~net
                      ~base_path:(Mcp_server.workspace_config state).base_path json) in
             match result with
             | Ok json -> Http.Response.json_value ~request:req json reqd
             | Error error -> Http.Response.json_value ~status:(Server_runtime_setup_actions.status_of_error error) ~request:req
                 (`Assoc ["error",`String (Server_runtime_setup_actions.error_message error)]) reqd))
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/setup/connections" (fun state _agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body ->
             let result = match (try Some (Yojson.Safe.from_string body) with Yojson.Json_error _ -> None) with
               | None -> Error Server_runtime_setup_actions.Invalid_request
               | Some json -> Server_runtime_setup_actions.save ~binary:Sys.executable_name
                   ~base_path:(Mcp_server.workspace_config state).base_path json in
             match result with
             | Ok json -> Http.Response.json_value ~request:req json reqd
             | Error error -> Http.Response.json_value ~status:(Server_runtime_setup_actions.status_of_error error) ~request:req
                 (`Assoc ["error",`String (Server_runtime_setup_actions.error_message error)]) reqd))
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/setup/credential" (fun _state _agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body ->
             let reject message = Http.Response.json_value ~status:`Bad_request ~request:req
               (`Assoc ["ok", `Bool false; "error", `String message]) reqd in
             let decoded = try Some (Yojson.Safe.from_string body) with Yojson.Json_error _ -> None in
             match decoded with
             | Some (`Assoc fields) when List.length fields = 3 ->
               (match List.assoc_opt "provider_id" fields, List.assoc_opt "secret" fields, List.assoc_opt "source_revision" fields, Runtime.config_path () with
                | Some (`String provider_id), Some (`String secret), Some (`String expected_source_revision), Some runtime_config_path ->
                  (match Runtime_setup_credentials.save ~secret () with
                   | Error error -> reject (Runtime_setup_credentials.error_message error)
                   | Ok pending -> Eio.Switch.run (fun sw ->
                     Eio.Switch.on_release sw (fun () -> Runtime_setup_credentials.remove_uncommitted pending);
                     match Runtime_setup_credentials.apply_to_provider ~runtime_config_path ~provider_id ~expected_source_revision pending with
                     | Error error -> reject (Runtime_setup_credentials.error_message error)
                     | Ok _ -> Http.Response.json_value ~request:req
                         (`Assoc ["ok", `Bool true; "configured", `Bool true;
                                  "verification", `String "not_run"]) reqd))
                | _ -> reject "Select a configured provider and enter its API key.")
             | _ -> reject "Expected a provider selection and API key."))
  |> Server_route.get (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/setup/status" (fun state _agent_name req reqd ->
           let config = Mcp_server.workspace_config state in
           let observed =
             Onboarding_status.inspect_loaded ~base_path:(Some config.base_path) in
           Http.Response.json_value ~request:req (Onboarding_status.to_json observed) reqd)
