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
     public or that judge a browser session or a personal access token themselves"
    path
    (Yojson.Safe.to_string (Route_access.to_json access))
;;

(* A route of any other kind reads the credentials of a single user, through
   a wrapper of [Server_auth] or in its own handler. *)
let served : Route_access.t -> bool = function
  | Route_access.Always_public
  | Route_access.Self_authenticated (Route_access.Browser_session | Route_access.Person_mcp) -> true
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

(* A router is one shared table that a registration changes in place, and
   the registration function can keep the router it was given. The table is a
   copy made after the routes are judged: nothing outside this module holds
   it, so no route is added to it and none of its routes is replaced. *)
let checked register =
  let router = register (Http.Router.create ()) in
  match
    List.find_opt
      (fun (route : Http.Router.route) -> not (served route.access))
      (Http.Router.routes router)
  with
  | Some (route : Http.Router.route) -> Error { path = route.path; access = route.access }
  | None -> Ok (Http.Router.copy router)
;;

let route_count = Http.Router.route_count
let stays_with_connection table request =
  match Http.Router.resolve table request with
  | `Matched { Http.Router.handler = Http.Router.Ws _ | Http.Router.Serving _; _ } -> true
  | `Matched { Http.Router.handler = Http.Router.Owner _; _ }
  | `Method_not_allowed
  | `Not_found -> false
;;

let dispatch = Http.Router.dispatch
