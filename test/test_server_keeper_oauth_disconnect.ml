(** Detaching one Keeper from one provider, over the route the TUI calls.

    The operator asked how to disconnect a service and there was no road: the
    five identity routes only ever wrote credentials. This suite drives the
    route the same way the TUI does -- an authenticated POST with the Keeper
    and the provider -- and reads the world afterwards: the refresh token is
    gone from the Keeper's secret scope, the tool catalog written for that
    provider is gone, and a receipt records what was removed and what the
    provider was asked to revoke. *)

open Alcotest

module Http = Masc.Http_server_eio

let check = Alcotest.check

let base_path () =
  let path =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-disconnect-route-%d-%d" (Unix.getpid ())
         (Random.int 1_000_000))
  in
  Unix.mkdir path 0o700;
  path

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter
      (fun name -> remove_tree (Filename.concat path name))
      (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let loopback_request_authority () =
  match Server_request_authority.of_host_port ~host:"127.0.0.1" ~port:8935 with
  | Ok authority -> authority
  | Error `Malformed -> fail "failed to construct loopback request authority"
;;

let dispatch_response ?(meth = "POST") ?token ~router ~path ~body () =
  Server_request_authority.with_current
    (loopback_request_authority ())
    (fun () ->
      let output = Buffer.create 1024 in
      let connection =
        Httpun.Server_connection.create (fun reqd ->
          Http.Router.dispatch router (Httpun.Reqd.request reqd) reqd)
      in
      let authorization =
        Option.fold
          ~none:""
          ~some:(fun token -> "Authorization: Bearer " ^ token ^ "\r\n")
          token
      in
      let raw_request =
        Printf.sprintf
          "%s %s HTTP/1.1\r\n\
           Host: 127.0.0.1:8935\r\n\
           Origin: http://127.0.0.1:8935\r\n\
           %s\
           Content-Type: application/json\r\n\
           Content-Length: %d\r\n\
           \r\n\
           %s"
          meth path authorization (String.length body) body
      in
      let input =
        Bigstringaf.of_string ~off:0 ~len:(String.length raw_request) raw_request
      in
      ignore
        (Httpun.Server_connection.read_eof connection input ~off:0
           ~len:(Bigstringaf.length input));
      let rec drain () =
        match Httpun.Server_connection.next_write_operation connection with
        | `Write iovecs ->
          let bytes =
            List.fold_left
              (fun total (iov : Bigstringaf.t Httpun.IOVec.t) ->
                Buffer.add_string output
                  (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
                total + iov.len)
              0 iovecs
          in
          Httpun.Server_connection.report_write_result connection (`Ok bytes);
          drain ()
        | `Yield | `Close _ -> ()
      in
      drain ();
      let raw = Buffer.contents output in
      let status = int_of_string (List.nth (String.split_on_char ' ' raw) 1) in
      let rec body_offset index =
        if index + 4 > String.length raw then fail ("no HTTP body: " ^ raw)
        else if String.sub raw index 4 = "\r\n\r\n" then index + 4
        else body_offset (index + 1)
      in
      let offset = body_offset 0 in
      status, String.sub raw offset (String.length raw - offset))
;;

let dispatch_json ?meth ?token ~router ~path ~body () =
  let status, body = dispatch_response ?meth ?token ~router ~path ~body () in
  status, Yojson.Safe.from_string body
;;

let member json key =
  match json with
  | `Assoc pairs -> List.assoc_opt key pairs
  | _ -> Alcotest.fail "the answer is not an object"
;;

let provider_or_fail id =
  match Keeper_oauth_declarations.find id with
  | Some (Keeper_oauth_declarations.Declared provider) -> provider
  | Some (Keeper_oauth_declarations.Unreadable { problem; _ }) ->
    Alcotest.failf "the %s declaration does not read: %s" id problem
  | None -> Alcotest.failf "no provider is declared as %s" id
;;

let keeper = "disconnect-route-fixture"

let with_disconnect_router f =
  let base_path = base_path () in
  let previous_state = Server_auth.For_testing.snapshot_server_state () in
  Fun.protect
    ~finally:(fun () ->
      Server_auth.For_testing.restore_server_state previous_state;
      remove_tree base_path)
    (fun () ->
      Eio_main.run
      @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Eio.Switch.run
      @@ fun sw ->
      let state = Masc.Mcp_server.For_testing.create_state ~base_path in
      let config = Masc.Mcp_server.workspace_config state in
      ignore (Masc.Workspace.init config ~agent_name:(Some "test"));
      Server_auth.For_testing.restore_server_state (Some state);
      Auth.save_auth_config base_path
        { Masc_domain.default_auth_config with enabled = true; require_token = true };
      let token =
        match
          Auth.create_token base_path ~agent_name:"disconnect-owner"
            ~role:Masc_domain.Admin
        with
        | Ok (token, _) -> token
        | Error error -> fail (Masc_domain.masc_error_to_string error)
      in
      let clock = Eio.Stdenv.clock env in
      let router =
        Server_keeper_oauth_http.add_routes ~clock (Http.Router.create ())
      in
      f ~base_path ~clock ~router ~token)
;;

(* Put a Keeper in the state the login route would have left it in: a refresh
   token on file, an access token in the environment scope, and the tool
   catalog written for the provider. *)
let seed_attachment base_path provider =
  let scope = Masc.Keeper_secret_projection.Keeper_secret in
  (match
     Masc.Keeper_secret_projection.set_file_entry ~base_path ~keeper_name:keeper ~scope
       ~container_path:provider.Keeper_oauth_provider.refresh_token_file
       ~value:"a-refresh-token"
   with
   | Ok () -> ()
   | Error message -> Alcotest.failf "seeding the refresh token failed: %s" message);
  (match
     Masc.Keeper_secret_projection.set_env_entry ~base_path ~keeper_name:keeper ~scope
       ~name:provider.Keeper_oauth_provider.access_token_env
       ~value:"an-access-token"
   with
   | Ok () -> ()
   | Error message -> Alcotest.failf "seeding the access token failed: %s" message);
  match
    Masc.Keeper_identity_tools.save ~base_path ~keeper_name:keeper
      { Masc.Keeper_identity_tools.provider_id = provider.Keeper_oauth_provider.id
      ; provider_label = provider.Keeper_oauth_provider.label
      ; discovered_at = 0.
      ; tools = []
      }
  with
  | Ok () -> ()
  | Error message -> Alcotest.failf "seeding the catalog failed: %s" message
;;

let test_the_route_removes_the_token_the_catalog_and_writes_a_receipt () =
  with_disconnect_router
  @@ fun ~base_path ~clock:_ ~router ~token ->
  let provider = provider_or_fail "slack" in
  seed_attachment base_path provider;
  let status, answer =
    dispatch_json ~router ~token
      ~path:"/api/v1/keepers/oauth/disconnect"
      ~body:
        (Yojson.Safe.to_string
           (`Assoc
             [ "keeper", `String keeper
             ; "provider", `String provider.Keeper_oauth_provider.id
             ]))
      ()
  in
  check int "the route answers 200" 200 status;
  check bool "and the answer names the provider" true
    (member answer "provider" = Some (`String provider.Keeper_oauth_provider.id));
  (* The refresh token is gone from the Keeper's secret scope. *)
  (match
     Masc.Keeper_secret_projection.read_file_entry ~base_path ~keeper_name:keeper
       ~scope:Masc.Keeper_secret_projection.Keeper_secret
       ~container_path:provider.Keeper_oauth_provider.refresh_token_file
   with
   | Ok None -> ()
   | Ok (Some _) -> Alcotest.fail "the refresh token is still on file"
   | Error message -> Alcotest.failf "reading the refresh token failed: %s" message);
  (* The tool catalog is gone, so the next turn stops offering its tools. *)
  (match
     Masc.Keeper_identity_tools.load ~base_path ~keeper_name:keeper
       ~provider_id:provider.Keeper_oauth_provider.id
   with
   | Ok None -> ()
   | Ok (Some _) -> Alcotest.fail "the tool catalog is still on file"
   | Error message -> Alcotest.failf "reading the catalog failed: %s" message);
  (* A receipt records what was removed. *)
  let receipt_path =
    Filename.concat
      (Filename.concat
         (Filename.concat
            (Filename.concat
               (Filename.concat base_path ".masc")
               "identity")
            "disconnects")
         keeper)
      (provider.Keeper_oauth_provider.id ^ ".json")
  in
  check bool "a receipt was written" true (Sys.file_exists receipt_path);
  let receipt =
    Yojson.Safe.from_file receipt_path
  in
  check bool "it names the provider" true
    (member receipt "provider" = Some (`String provider.Keeper_oauth_provider.id));
  check bool "and says the refresh token was deleted" true
    (match member receipt "deleted" with
     | Some (`Assoc fields) -> List.assoc_opt "refresh_token" fields = Some (`Bool true)
     | _ -> false)
;;

let test_an_unknown_keeper_or_provider_is_refused () =
  with_disconnect_router
  @@ fun ~base_path:_ ~clock:_ ~router ~token ->
  let status, answer =
    dispatch_json ~router ~token
      ~path:"/api/v1/keepers/oauth/disconnect"
      ~body:
        (Yojson.Safe.to_string
           (`Assoc [ "keeper", `String keeper; "provider", `String "not-a-provider" ]))
      ()
  in
  check int "an undeclared provider is a bad request" 400 status;
  check bool "with a reason" true (member answer "error" <> None)
;;

let () =
  Alcotest.run "server_keeper_oauth_disconnect"
    [ ( "detaching a Keeper from a provider",
        [ Alcotest.test_case
            "the route removes the token, the catalog and writes a receipt"
            `Quick test_the_route_removes_the_token_the_catalog_and_writes_a_receipt;
          Alcotest.test_case "an undeclared provider is refused" `Quick
            test_an_unknown_keeper_or_provider_is_refused;
        ] );
    ]
