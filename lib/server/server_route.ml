module Router = Http_server_eio.Router

type state_handler =
  Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> unit

type token_handler =
  Mcp_server.server_state -> string -> Httpun.Request.t -> Httpun.Reqd.t -> unit

type actor_handler =
  Mcp_server.server_state -> string -> Httpun.Request.t -> Httpun.Reqd.t -> unit

type _ auth =
  | Always_public : Http_server_eio.request_handler auth
  | Public_read : state_handler auth
  | Read_auth : state_handler auth
  | Permission : Masc_domain.permission -> state_handler auth
  | Token_permission : Masc_domain.permission -> token_handler auth
  | Private_token_permission : Masc_domain.permission -> token_handler auth
  | Tool : { tool_name : string } -> state_handler auth
  | Tool_actor : { tool_name : string } -> actor_handler auth
  | Self_authenticated :
      Route_access.self_authenticated_reason
      -> Http_server_eio.request_handler auth

let access : type h. h auth -> Route_access.t = function
  | Always_public -> Route_access.Always_public
  | Public_read -> Route_access.Public_read
  | Read_auth -> Route_access.Read_auth
  | Permission permission -> Route_access.Permission permission
  | Token_permission permission -> Route_access.Token_permission permission
  | Private_token_permission permission ->
    Route_access.Private_token_permission permission
  | Tool { tool_name } -> Route_access.Tool { tool_name }
  | Tool_actor { tool_name } -> Route_access.Tool_actor { tool_name }
  | Self_authenticated reason -> Route_access.Self_authenticated reason
;;

(* The handler a route runs: [handler] inside the wrapper the kind names. The
   kinds that wrap nothing hand [handler] over unchanged. *)
let wrapped : type h. h auth -> h -> Http_server_eio.request_handler =
  fun auth handler ->
  match auth with
  | Always_public -> handler
  | Self_authenticated _ -> handler
  | Public_read -> Server_auth.with_public_read handler
  | Read_auth -> Server_auth.with_read_auth handler
  | Permission permission -> Server_auth.with_permission_auth ~permission handler
  | Token_permission permission ->
    Server_auth.with_token_permission_auth ~permission handler
  | Private_token_permission permission ->
    Server_auth.with_private_token_permission_auth ~permission handler
  | Tool { tool_name } -> Server_auth.with_tool_auth ~tool_name handler
  | Tool_actor { tool_name } -> Server_auth.with_tool_actor_auth ~tool_name handler
;;

let register auth ~kind ~path ~methods handler routes =
  Router.register
    ~access:(access auth)
    ~kind
    ~path
    ~methods
    ~handler:(Router.Plain (wrapped auth handler))
    routes
;;

let get auth path handler routes =
  register auth ~kind:Router.Exact ~path ~methods:[ `GET ] handler routes
;;

let post auth path handler routes =
  register auth ~kind:Router.Exact ~path ~methods:[ `POST ] handler routes
;;

let add auth ~path ~methods handler routes =
  register auth ~kind:Router.Exact ~path ~methods handler routes
;;

let prefix_get auth prefix handler routes =
  register auth ~kind:Router.Prefix ~path:prefix ~methods:[ `GET ] handler routes
;;

let prefix_post auth prefix handler routes =
  register auth ~kind:Router.Prefix ~path:prefix ~methods:[ `POST ] handler routes
;;

let prefix_put auth prefix handler routes =
  register auth ~kind:Router.Prefix ~path:prefix ~methods:[ `PUT ] handler routes
;;

let prefix_delete auth prefix handler routes =
  register auth ~kind:Router.Prefix ~path:prefix ~methods:[ `DELETE ] handler routes
;;

let ws_get path handler routes =
  Router.register
    ~access:(Route_access.Self_authenticated Route_access.Websocket_upgrade)
    ~kind:Router.Exact
    ~path
    ~methods:[ `GET ]
    ~handler:(Router.Ws handler)
    routes
;;
