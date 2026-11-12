type self_authenticated_reason =
  | Mcp_transport
  | Oauth_protocol
  | Websocket_upgrade
  | Browser_session
  | Person_mcp
  | Loopback_dev_token
  | Subpath_dispatch

type strict_reading =
  | Credential_when_strict
  | Open_when_strict

type t =
  | Always_public
  | Public_read of strict_reading
  | Read_auth
  | Permission of Masc_domain.permission
  | Token_permission of Masc_domain.permission
  | Private_token_permission of Masc_domain.permission
  | Tool of { tool_name : string }
  | Tool_observation of { tool_name : string }
  | Tool_actor of { tool_name : string }
  | Manage_own_provider
  | Manage_own_keeper
  | Self_authenticated of self_authenticated_reason

let reason_to_string = function
  | Mcp_transport -> "mcp_transport"
  | Oauth_protocol -> "oauth_protocol"
  | Websocket_upgrade -> "websocket_upgrade"
  | Browser_session -> "browser_session"
  | Person_mcp -> "person_mcp"
  | Loopback_dev_token -> "loopback_dev_token"
  | Subpath_dispatch -> "subpath_dispatch"
;;

let to_json t =
  let kind name fields = `Assoc (("kind", `String name) :: fields) in
  let permission name p =
    kind name [ "permission", `String (Masc_domain.permission_to_string p) ]
  in
  match t with
  | Always_public -> kind "always_public" []
  | Public_read when_strict ->
    let reading =
      match when_strict with
      | Credential_when_strict -> "credential"
      | Open_when_strict -> "open"
    in
    kind "public_read" [ "when_strict", `String reading ]
  | Read_auth -> kind "read_auth" []
  | Permission p -> permission "permission" p
  | Token_permission p -> permission "token_permission" p
  | Private_token_permission p -> permission "private_token_permission" p
  | Tool { tool_name } -> kind "tool" [ "tool_name", `String tool_name ]
  | Tool_observation { tool_name } -> kind "tool_observation" [ "tool_name", `String tool_name ]
  | Tool_actor { tool_name } -> kind "tool_actor" [ "tool_name", `String tool_name ]
  | Manage_own_provider -> kind "manage_own_provider" []
  | Manage_own_keeper -> kind "manage_own_keeper" []
  | Self_authenticated reason ->
    kind "self_authenticated" [ "reason", `String (reason_to_string reason) ]
;;
