(** A refused request must leave a line naming the endpoint that produced it.

    A 401/403 is about the credential the client presented, and the client is
    not where it is decided: the TUI's refresh path reaches
    [Server_auth.respond_auth_error] (h1) and the h2 gateway reaches its twin,
    so both protocols emit one line through [Server_auth.log_auth_refusal],
    whose details carry the protocol, the path and the status. The raw bearer
    is never part of it. *)

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

(* A fresh test process starts the ring empty with [total = 0], so the first
   entry pushed here gets seq 0. A [since_seq] cursor of 0 means "strictly
   newer than 0" and would drop that very entry, so only pass a cursor when
   the ring already held something. The baseline is read before the emit, or
   the cursor would name the line the test is looking for. *)
let baseline_seq () =
  match Log.Ring.recent ~limit:1 () with
  | (entry : Log.Ring.entry) :: _ -> Some entry.seq
  | [] -> None

let auth_lines_since baseline =
  match baseline with
  | Some seq -> Log.Ring.recent ~limit:10 ~module_filter:"Auth" ~since_seq:seq ()
  | None -> Log.Ring.recent ~limit:10 ~module_filter:"Auth" ()

let refusal_line = "HTTP auth rejected: h1 /api/v1/keeper/chat -> 401"

let has_refusal_line entries =
  List.exists
    (fun (entry : Log.Ring.entry) -> String.equal entry.message refusal_line)
    entries

(* The emit itself, not just the pure helpers: a refused request must reach the
   dashboard log ring the operator reads. *)
let test_log_auth_refusal_emits_line () =
  let baseline = baseline_seq () in
  Server_auth.log_auth_refusal ~protocol:"h1" ~path:"/api/v1/keeper/chat" ~status:401;
  let entries = auth_lines_since baseline in
  check bool "refusal line reached the log ring" true (has_refusal_line entries);
  match
    List.find_opt
      (fun (entry : Log.Ring.entry) -> String.equal entry.message refusal_line)
      entries
  with
  | None -> ()
  | Some (entry : Log.Ring.entry) ->
    let open Yojson.Safe.Util in
    check string "details carry the path" "/api/v1/keeper/chat"
      (entry.details |> member "path" |> to_string);
    check int "details carry the status" 401 (entry.details |> member "status" |> to_int)

(* The responder, not just the helper: this drives [respond_auth_error] itself
   over a real [Httpun.Reqd], so deleting its logging call fails the test. The
   responder reads the request authority through a fiber-local, so it runs
   inside an Eio context. *)
let test_respond_auth_error_emits_line () =
  let baseline = baseline_seq () in
  Eio_main.run (fun _env ->
    let reqd_ref = ref None in
    let conn =
      Httpun.Server_connection.create (fun reqd -> reqd_ref := Some reqd)
    in
    let request_text = "GET /api/v1/keeper/chat HTTP/1.1\r\nHost: localhost\r\n\r\n" in
    let len = String.length request_text in
    let bs = Bigstringaf.of_string request_text ~off:0 ~len in
    ignore (Httpun.Server_connection.read conn bs ~off:0 ~len);
    let reqd = Option.get !reqd_ref in
    let request = Httpun.Reqd.request reqd in
    Server_auth.respond_auth_error request reqd
      (Masc_domain.Auth (Masc_domain.Auth_error.InvalidToken "stale-token-x")));
  check bool "respond_auth_error left a refusal line" true
    (has_refusal_line (auth_lines_since baseline))

let () =
  run "server_auth_refusal_log"
    [ ( "refusal_line"
      , [ test_case "details carry protocol, path and status" `Quick
            test_details_carry_path_and_status
        ; test_case "message names the path and the status" `Quick
            test_message_names_both
        ; test_case "the emit reaches the log ring" `Quick
            test_log_auth_refusal_emits_line
        ; test_case "respond_auth_error reaches the log ring" `Quick
            test_respond_auth_error_emits_line
        ] ) ]
