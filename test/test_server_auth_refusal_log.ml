(** A refused request must leave a line naming the endpoint that produced it.

    A 401/403 is about the credential the client presented, and the client is
    not where it is decided: the TUI's refresh path, the MCP transport and the
    h2 gateway all reach [Server_auth.respond_auth_error] or its h2 twin, and a
    refusal that came and went in a refresh used to leave no line naming the
    endpoint. Both protocols now emit one line through
    [Server_auth.log_auth_refusal], whose details carry the protocol, the path
    and the status. The raw bearer is never part of it. *)

open Alcotest

let test_details_carry_path_and_status () =
  let details =
    Server_auth.auth_refusal_details ~protocol:"h1" ~path:"/api/v1/keeper/chat" ~status:401
  in
  let open Yojson.Safe.Util in
  check string "protocol" "h1" (details |> member "protocol" |> to_string);
  check string "path" "/api/v1/keeper/chat" (details |> member "path" |> to_string);
  check int "status" 401 (details |> member "status" |> to_int)

let test_message_names_both () =
  check string
    "message names the protocol, the path and the status"
    "HTTP auth rejected: h2 /mcp -> 403"
    (Server_auth.auth_refusal_message ~protocol:"h2" ~path:"/mcp" ~status:403)

let () =
  run "server_auth_refusal_log"
    [ ( "refusal_line"
      , [ test_case "details carry protocol, path and status" `Quick
            test_details_carry_path_and_status
        ; test_case "message names the path and the status" `Quick
            test_message_names_both
        ] )
    ]
