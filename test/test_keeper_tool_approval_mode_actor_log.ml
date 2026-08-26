(** The approval-mode change log records who turned the mode on.

    task-347: the [POST /api/v1/keepers/tool-approval-mode] route used
    [with_tool_auth], which resolved the caller identity and then threw it
    away, so the log line carried only keeper and mode. The route now uses
    [with_tool_actor_auth] and threads the resolved actor into the handler,
    which writes it into the log. This test drives the real route over HTTP
    with a bearer token and asserts the actor appears in the emitted log line.
*)

open Alcotest

module Mcp_server = Masc.Mcp_server
module Http_server_eio = Masc.Http_server_eio
module U = Yojson.Safe.Util

let temp_dir_counter = ref 0

let with_temp_dir f =
  incr temp_dir_counter;
  let base =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "approval-mode-actor-%d-%06d" (Unix.getpid ()) !temp_dir_counter)
  in
  Unix.mkdir base 0o755;
  Fun.protect
    ~finally:(fun () ->
      let rec rm_rf path =
        if Sys.file_exists path then
          if Sys.is_directory path then (
            Sys.readdir path
            |> Array.iter (fun name -> rm_rf (Filename.concat path name));
            Unix.rmdir path
          ) else Sys.remove path
      in
      rm_rf base)
    (fun () -> f base)

let loopback_request_authority () =
  match Server_request_authority.of_host_port ~host:"127.0.0.1" ~port:8935 with
  | Ok authority -> authority
  | Error `Malformed -> Alcotest.fail "failed to construct loopback request authority"

let create_token_exn base_path ~agent_name ~role =
  match Auth.create_token base_path ~agent_name ~role with
  | Ok token_info -> token_info
  | Error msg ->
    Alcotest.failf "create_token failed: %s" (Masc_domain.masc_error_to_string msg)

let make_keeper_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ ("name", `String name)
        ; ("agent_name", `String (Masc.Keeper_identity.keeper_agent_name name))
        ; ("trace_id", `String ("trace-" ^ name))
        ])
  with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("meta_of_json failed: " ^ err)

(* Drive the real dashboard router with a POST carrying a bearer token and a
   JSON body, then return the raw HTTP response. *)
let dispatch_post ~sw ~clock ~state ~token ~keeper ~mode =
  Server_request_authority.with_current (loopback_request_authority ()) (fun () ->
    let router =
      Server_routes_http_routes_dashboard.add_routes
        ~sw
        ~clock
        (Http_server_eio.Router.create ())
    in
    Server_auth.publish_server_state state;
    let response_buf = Buffer.create 1024 in
    let conn =
      Httpun.Server_connection.create (fun reqd ->
        Http_server_eio.Router.dispatch router (Httpun.Reqd.request reqd) reqd)
    in
    let body = Printf.sprintf {|{"name":%S,"mode":%S}|} keeper mode in
    let request_str =
      Printf.sprintf
        "POST /api/v1/keepers/tool-approval-mode HTTP/1.1\r\n\
         Host: 127.0.0.1:8935\r\n\
         Origin: http://127.0.0.1:8935\r\n\
         Authorization: Bearer %s\r\n\
         Content-Type: application/json\r\n\
         Content-Length: %d\r\n\
         \r\n\
         %s"
        token (String.length body) body
    in
    let bytes =
      Bigstringaf.of_string ~off:0 ~len:(String.length request_str) request_str
    in
    ignore
      (Httpun.Server_connection.read_eof
         conn
         bytes
         ~off:0
         ~len:(Bigstringaf.length bytes));
    let rec flush () =
      match Httpun.Server_connection.next_write_operation conn with
      | `Write iovecs ->
        let written =
          List.fold_left
            (fun total (iov : Bigstringaf.t Httpun.IOVec.t) ->
               Buffer.add_string
                 response_buf
                 (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
               total + iov.len)
            0
            iovecs
        in
        Httpun.Server_connection.report_write_result conn (`Ok written);
        flush ()
      | `Yield | `Close _ -> ()
    in
    flush ();
    Server_auth.clear_server_state ();
    Buffer.contents response_buf)

let status_of_response response =
  match String.split_on_char ' ' response with
  | _ :: status :: _ -> int_of_string status
  | _ -> Alcotest.failf "could not parse response status: %S" response

let latest_seq () =
  match Log.Ring.recent ~limit:1 () with
  | entry :: _ -> entry.Log.Ring.seq
  | [] -> 0

let keeper_entries_since seq =
  Log.Ring.recent
    ~limit:1000
    ~since_seq:seq
    ~module_filter:"Keeper"
    ~order:`Oldest_first
    ()

let test_actor_appears_in_approval_mode_log () =
  with_temp_dir (fun base_path ->
    let auth_config =
      { Masc_domain.default_auth_config with enabled = true; require_token = true }
    in
    Auth.save_auth_config base_path auth_config;
    let token, _cred =
      create_token_exn base_path ~agent_name:"mode-operator" ~role:Masc_domain.Admin
    in
    let state = Mcp_server.For_testing.create_state ~base_path in
    let keeper = "approval-mode-canary" in
    ignore (Masc.Keeper_registry.For_testing.register ~base_path keeper (make_keeper_meta keeper));
    Fun.protect
      ~finally:(fun () ->
        Masc.Keeper_registry.For_testing.unregister ~base_path keeper)
      (fun () ->
         Eio_main.run (fun env ->
           let clock = Eio.Stdenv.clock env in
           Eio.Switch.run (fun sw ->
             let before_seq = latest_seq () in
             let response =
               dispatch_post ~sw ~clock ~state ~token ~keeper ~mode:"yolo"
             in
             check int "approval-mode POST succeeds" 200
               (status_of_response response);
             let entries = keeper_entries_since before_seq in
             let matching =
               List.filter
                 (fun (entry : Log.Ring.entry) ->
                    Astring.String.is_infix
                      ~affix:"keeper_tool_approval_mode"
                      entry.message)
                 entries
             in
             check bool "a keeper_tool_approval_mode log line was emitted" true
               (matching <> []);
             check bool
               "the log line carries the resolved actor"
               true
               (List.exists
                  (fun (entry : Log.Ring.entry) ->
                     Astring.String.is_infix
                       ~affix:"actor=mode-operator"
                       entry.message)
                  matching);
             check bool
               "the log line names the keeper and mode"
               true
               (List.exists
                  (fun (entry : Log.Ring.entry) ->
                     Astring.String.is_infix
                       ~affix:(Printf.sprintf "keeper=%s mode=yolo" keeper)
                       entry.message)
                  matching)))))

let () =
  Eio_main.run @@ fun _env ->
  run "keeper_tool_approval_mode_actor_log"
    [ ( "actor log"
      , [ test_case "actor appears in approval-mode change log" `Quick
            test_actor_appears_in_approval_mode_log
        ] )
    ]
