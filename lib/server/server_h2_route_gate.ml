type gate =
  | Open
  | Public_read
  | Read_auth
  | Token_permission of Masc_domain.permission

type refusal =
  | No_route
  | Wrong_method
  | Kind_not_served of Route_access.t
  | Actor_not_provided of Route_access.t

let access_of_resolution : Http_server_eio.Router.resolution -> _ = function
  | `Matched route -> Ok route.Http_server_eio.Router.access
  | `Method_not_allowed -> Error Wrong_method
  | `Not_found -> Error No_route
;;

(* Every kind and every reason is named, so one added to [Route_access] does not
   compile until this decides what HTTP/2 does with it. The reasons with an HTTP/2
   arm are the ones that open: the arm authenticates in its own code, as the HTTP/1
   handler does. The others have no HTTP/2 arm, so they are refused until someone
   reads the HTTP/1 handler and writes one. *)
let plan (kind : Route_access.t) =
  match kind with
  | Always_public -> Ok Open
  | Self_authenticated (Mcp_transport | Oauth_protocol | Websocket_upgrade) -> Ok Open
  | Self_authenticated (Browser_lane | Loopback_dev_token | Subpath_dispatch) ->
    Error (Kind_not_served kind)
  | Public_read -> Ok Public_read
  | Read_auth -> Ok Read_auth
  | Token_permission permission -> Ok (Token_permission permission)
  | Permission _ | Private_token_permission _ | Tool _ | Tool_actor _ ->
    Error (Kind_not_served kind)
;;

let plan_actor kind =
  match plan kind with
  | Ok (Token_permission permission) -> Ok permission
  | Ok (Open | Public_read | Read_auth) -> Error (Actor_not_provided kind)
  | Error _ as refusal -> refusal
;;

let kind_to_string kind = Yojson.Safe.to_string (Route_access.to_json kind)

let refusal_to_string = function
  | No_route -> "the HTTP/1 router has no route for the path"
  | Wrong_method -> "the HTTP/1 router has no route for the method"
  | Kind_not_served kind ->
    Printf.sprintf "HTTP/2 has no gate for the kind %s" (kind_to_string kind)
  | Actor_not_provided kind ->
    Printf.sprintf "the arm needs an actor but the kind %s does not authenticate one" (kind_to_string kind)
;;
