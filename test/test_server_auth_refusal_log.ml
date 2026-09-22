(** A refused request must leave a line naming the endpoint that produced it.

    A 401/403 is about the credential the client presented, and the client is
    not where it is decided: the TUI's refresh path reaches
    [Server_auth.respond_auth_error] (h1) and the h2 gateway reaches its twin,
    and a refusal that came and went in a refresh left no line naming the
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

(* The emit itself, not just the pure helpers: a refused request must reach the
   dashboard log ring the operator reads. *)
let test_log_auth_refusal_emits_line () =
  let baseline =
    match Log.Ring.recent ~limit:1 () with
    | (entry : Log.Ring.entry) :: _ -> entry.seq
    | [] -> 0
  in
  Server_auth.log_auth_refusal ~protocol:"h1" ~path:"/api/v1/keeper/chat" ~status:401;
  let entries = Log.Ring.recent ~limit:10 ~module_filter:"Auth" ~since_seq:baseline () in
  let found =
    List.find_opt
      (fun (entry : Log.Ring.entry) ->
        String.equal entry.message "HTTP auth rejected: h1 /api/v1/keeper/chat -> 401")
      entries
  in
  check bool "refusal line reached the log ring" true (Option.is_some found);
  match found with
  | None -> ()
  | Some (entry : Log.Ring.entry) ->
    let open Yojson.Safe.Util in
    check string "details carry the path" "/api/v1/keeper/chat"
      (entry.details |> member "path" |> to_string);
    check int "details carry the status" 401 (entry.details |> member "status" |> to_int)

let () =
  run "server_auth_refusal_log"
    [ ( "refusal_line"
      , [ test_case "details carry protocol, path and status" `Quick
            test_details_carry_path_and_status
        ; test_case "message names the path and the status" `Quick
            test_message_names_both
        ; test_case "the emit reaches the log ring" `Quick
            test_log_auth_refusal_emits_line
        ] )
    ]
