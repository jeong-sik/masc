(* HIGH-RISK-UNREVIEWED: see the interface. *)

module Http = Http_server_eio

type t = Http.Router.t

type refusal =
  { path : string
  ; access : Route_access.t
  }

let refusal_to_string { path; access } =
  Printf.sprintf
    "the route %s is registered as %s, and the account server serves only routes that are \
     public or that authenticate a browser session themselves"
    path
    (Yojson.Safe.to_string (Route_access.to_json access))
;;

(* A route of any other kind reads the credentials of a single user, through
   a wrapper of [Server_auth] or in its own handler. *)
let served : Route_access.t -> bool = function
  | Route_access.Always_public
  | Route_access.Self_authenticated Route_access.Browser_session -> true
  | Route_access.Public_read
      (Route_access.Credential_when_strict | Route_access.Open_when_strict)
  | Route_access.Read_auth
  | Route_access.Permission (_ : Masc_domain.permission)
  | Route_access.Token_permission (_ : Masc_domain.permission)
  | Route_access.Private_token_permission (_ : Masc_domain.permission)
  | Route_access.Tool { tool_name = _ }
  | Route_access.Tool_observation { tool_name = _ }
  | Route_access.Tool_actor { tool_name = _ }
  | Route_access.Manage_own_provider
  | Route_access.Manage_own_keeper
  | Route_access.Self_authenticated
      ( Route_access.Mcp_transport
      | Route_access.Oauth_protocol
      | Route_access.Websocket_upgrade
      | Route_access.Loopback_dev_token
      | Route_access.Subpath_dispatch ) -> false
;;

let checked register =
  let router = register (Http.Router.create ()) in
  match
    List.find_opt
      (fun (route : Http.Router.route) -> not (served route.access))
      (Http.Router.routes router)
  with
  | Some (route : Http.Router.route) -> Error { path = route.path; access = route.access }
  | None -> Ok router
;;

let route_count = Http.Router.route_count
let is_websocket table request =
  match Http.Router.resolve table request with
  | `Matched (route : Http.Router.route) ->
    (match served route.access, route.handler with
     | true, (Http.Router.Ws _ | Http.Router.Serving _) -> true
     | false, (Http.Router.Owner _ | Http.Router.Serving _ | Http.Router.Ws _)
     | true, Http.Router.Owner _ -> false)
  | `Method_not_allowed
  | `Not_found -> false
;;

(* The router is one shared table that a registration changes in place, and
   the registration function can keep the router it was given, so a route
   that is added after [checked] is in it. The route of each request is
   judged again: one of another kind is not found, as on a table that never
   held it. *)
let dispatch table request reqd =
  match Http.Router.resolve table request with
  | `Not_found -> Http.Response.not_found reqd
  | `Method_not_allowed -> Http.Response.method_not_allowed reqd
  | `Matched (route : Http.Router.route) ->
    (match served route.access, route.handler with
     | false, (Http.Router.Owner _ | Http.Router.Serving _ | Http.Router.Ws _) ->
       Http.Response.not_found reqd
     | true, (Http.Router.Owner handler | Http.Router.Serving handler) -> handler request reqd
     | true, Http.Router.Ws handler -> handler ~upgrade:(Http_reqd.upgrade reqd) request reqd)
;;
