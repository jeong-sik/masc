(* The wrappers of [Server_auth], handed to the router's typed registration. The
   router applies the one that goes with a route's kind; this module is the only
   place that supplies them. *)
module Wrappers = struct
  type state = Mcp_server.server_state

  let with_public_read = Server_auth.with_public_read
  let with_read_auth = Server_auth.with_read_auth
  let with_permission_auth = Server_auth.with_permission_auth
  let with_token_permission_auth = Server_auth.with_token_permission_auth

  let with_private_token_permission_auth =
    Server_auth.with_private_token_permission_auth
  ;;

  let with_tool_auth = Server_auth.with_tool_auth
  let with_tool_actor_auth = Server_auth.with_tool_actor_auth
  let with_canonical_loopback_host = Server_canonical_host.with_canonical_loopback_host
end

include Http_server_eio.Router.Make_typed (Wrappers)
