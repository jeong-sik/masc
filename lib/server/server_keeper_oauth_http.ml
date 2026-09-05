(** See server_keeper_oauth_http.mli. *)

module Http = Http_server_eio

let escape = Server_oauth_service.html_escape

let page ~title ~heading ~detail =
  Printf.sprintf
    {|<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>%s</title>
<style>
 :root { color-scheme: light dark; }
 body { font: 15px/1.6 ui-sans-serif, system-ui, sans-serif;
        margin: 0; min-height: 100vh; display: grid; place-items: center; }
 main { max-width: 34rem; padding: 2rem; }
 h1 { font-size: 1.25rem; margin: 0 0 .5rem; }
 p { margin: 0; opacity: .8; }
</style></head>
<body><main><h1>%s</h1><p>%s</p></main></body></html>
|}
    (escape title) (escape heading) (escape detail)
;;

let respond_page ?status reqd ~title ~heading ~detail =
  Http.Response.html ?status (page ~title ~heading ~detail) reqd
;;

let handle_callback request reqd =
  let query name = Server_utils.query_param request name in
  match Server_auth.current_server_state () with
  | None ->
    respond_page ~status:`Service_unavailable reqd ~title:"masc"
      ~heading:"This server is still starting"
      ~detail:"Start the login again once it is up."
  | Some state ->
    let base_path = (Mcp_server.workspace_config state).Workspace.base_path in
    (match query "error", query "code", query "state" with
     (* The provider says the operator declined, or it refused the request.
        Its own words, because ours would be a guess at what happened on a
        screen we never saw. *)
     | Some provider_error, _, _ ->
       respond_page ~status:`Bad_request reqd ~title:"masc"
         ~heading:"The provider did not grant this"
         ~detail:
           (match query "error_description" with
            | Some description -> description
            | None -> provider_error)
     | None, Some code, Some state_value
       when String.trim code <> "" && String.trim state_value <> "" ->
       (match
          Server_keeper_oauth.finish ~base_path ~state:state_value ~code
            ~now:(Unix.gettimeofday ())
        with
        | Ok attached ->
          respond_page reqd ~title:"masc"
            ~heading:
              (Printf.sprintf "%s is attached to %s" attached.Server_keeper_oauth.keeper
                 attached.Server_keeper_oauth.provider_label)
            ~detail:
              (let outcome =
                 match attached.Server_keeper_oauth.tool_discovery with
                 | Ok count ->
                   Printf.sprintf
                     "%d tools are now on that Keeper's surface. You can close this tab."
                     count
                 (* Attached, but the tool list did not come back. Saying so
                    beats a page that reads like success and a Keeper with no
                    new tools. *)
                 | Error problem ->
                   Printf.sprintf
                     "The credentials are stored, but asking what tools exist did \
                      not work: %s"
                     problem
               in
               (* Ahead of the outcome, because this is the page the operator
                  reads before closing the tab and what it says happens later
                  is the part they cannot come back to find. *)
               match attached.Server_keeper_oauth.warning with
               | None -> outcome
               | Some warning -> warning ^ " " ^ outcome)
        | Error message ->
          respond_page ~status:`Bad_request reqd ~title:"masc"
            ~heading:"That login could not be finished" ~detail:message)
     | None, _, _ ->
       respond_page ~status:`Bad_request reqd ~title:"masc"
         ~heading:"This is not a callback"
         ~detail:"A provider sends a code and the state it was given; this request carries neither.")
;;

(* What an operator can attach a Keeper to. Names and labels of files that
   ship with the binary, plus whether this install already has a client for
   each -- nothing about any Keeper -- so it reads like the rest of the
   operator snapshot. *)
let handle_providers request reqd =
  Server_auth.with_public_read
    (fun state req reqd ->
      Http.Response.json_value ~compress:true ~request:req
        (`Assoc
          [ ( "providers"
            , Server_keeper_oauth.declarations_json
                ~base_path:
                  (Mcp_server.workspace_config state).Workspace.base_path )
          ])
        reqd)
    request reqd
;;

(* What each declared provider currently offers one Keeper. Names only --
   the same reason the secret projection reports names: a screen has no use
   for a credential and every use for knowing whether one is there. *)
let handle_attached_tools request reqd =
  Server_auth.with_public_read
    (fun state req reqd ->
      let base_path = (Mcp_server.workspace_config state).Workspace.base_path in
      match Server_utils.query_param req "keeper" with
      | None ->
        Http.Response.json_value ~compress:true ~request:req
          (`Assoc [ "error", `String "keeper is required" ])
          reqd
      | Some keeper ->
        Http.Response.json_value ~compress:true ~request:req
          (`Assoc
            [ "keeper", `String keeper
            ; "providers", Server_keeper_oauth.attached_tools_json ~base_path ~keeper
            ])
          reqd)
    request reqd
;;

(* Recording an app an operator made themselves. Admin, because what it
   writes is what redeems a code: an id that is not theirs would send the
   consent somewhere else. Not scoped to a Keeper -- the client belongs to
   the install, the same as one this server registered. *)
let handle_set_client request reqd =
  (* The same authority as starting a login, and for the same reason the
     login route gives: what this writes is what redeems a code. A stricter
     tier here refused the operator token the TUI carries, which is the one
     that is allowed to begin the flow this feeds. *)
  Server_auth.with_token_permission_auth ~permission:Masc_domain.CanAdmin
    (fun state _agent_name req reqd ->
      let base_path = (Mcp_server.workspace_config state).Workspace.base_path in
      Http.Request.read_body_async reqd (fun body_str ->
        let answer =
          match Yojson.Safe.from_string body_str with
          | exception Yojson.Json_error detail -> Error detail
          | `Assoc pairs ->
            let field key =
              match List.assoc_opt key pairs with
              | Some (`String value) -> Some value
              | Some _ | None -> None
            in
            (match field "provider" with
             | None -> Error "provider is required"
             | Some provider_id ->
               (match field "client_id" with
                | None -> Error "client_id is required"
                | Some client_id ->
                  Server_keeper_oauth.set_client ~base_path ~provider_id
                    ~client_id ~client_secret:(field "client_secret")
                    ~scopes:(Option.value (field "scopes") ~default:"")))
          | _ -> Error "the request body is not an object"
        in
        match answer with
        | Error message ->
          Http.Response.json_value ~status:`Bad_request ~compress:true ~request:req
            (`Assoc [ "error", `String message ])
            reqd
        | Ok payload ->
          Http.Response.json_value ~compress:true ~request:req payload reqd))
    request reqd
;;

let add_routes router =
  router
  |> Http.Router.get Server_keeper_oauth.callback_path handle_callback
  |> Http.Router.get "/api/v1/keepers/oauth/providers" handle_providers
  |> Http.Router.get "/api/v1/keepers/oauth/attached-tools" handle_attached_tools
  |> Http.Router.post "/api/v1/keepers/oauth/client" handle_set_client
;;
