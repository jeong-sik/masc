open Alcotest
open Masc

let request router ~token ~method_ ~path ~body =
  let output = Buffer.create 512 in
  let connection = Httpun.Server_connection.create (fun reqd ->
    Http_server_eio.Router.dispatch router (Httpun.Reqd.request reqd) (Http_reqd.of_httpun reqd)) in
  let authorization = match token with None -> "" | Some token -> "Authorization: Bearer " ^ token ^ "\r\n" in
  let wire = Printf.sprintf "%s %s HTTP/1.1\r\nHost: localhost\r\n%sContent-Length: %d\r\n\r\n%s"
    method_ path authorization (String.length body) body in
  let input = Bigstringaf.of_string ~off:0 ~len:(String.length wire) wire in
  ignore (Httpun.Server_connection.read_eof connection input ~off:0 ~len:(Bigstringaf.length input));
  let rec drain () = match Httpun.Server_connection.next_write_operation connection with
    | `Write iovecs ->
      let bytes = List.fold_left (fun total (iov:Bigstringaf.t Httpun.IOVec.t) ->
        Buffer.add_string output (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
        total+iov.len) 0 iovecs in
      Httpun.Server_connection.report_write_result connection (`Ok bytes); drain ()
    | `Yield | `Close _ -> () in
  drain ();
  match String.split_on_char ' ' (Buffer.contents output) with
  | _ :: code :: _ -> code | _ -> fail "missing HTTP status"

(* A workspace that declares Claude Code and no other client. *)
let declared_toml = {|[runtime]
default = "claude_code.claude-sonnet-5"

[providers.claude_code]
display-name = "Claude Code"
protocol = "claude-code"
command = "claude"
is-non-interactive = true

[models."claude-sonnet-5"]
api-name = "claude-sonnet-5"
max-context = 1000000
tools-support = true
streaming = true

[claude_code."claude-sonnet-5"]
|}

let boundaries () = Eio_main.run (fun env ->
  let base = Filename.temp_dir "masc-login-routes-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base) (fun () ->
    Eio.Switch.run (fun sw ->
      let state = Mcp_server.For_testing.create_state ~base_path:base in
      Auth.save_auth_config base {Masc_domain.default_auth_config with enabled=true;require_token=true};
      let token name role = match Auth.create_token base ~agent_name:name ~role with
        | Ok (token,_) -> token | Error _ -> fail "fixture token creation" in
      let admin = token "login-admin" Masc_domain.Admin in
      let worker = token "login-worker" Masc_domain.Worker in
      let previous = Server_auth.For_testing.snapshot_server_state () in
      Eio.Switch.on_release sw (fun () -> Server_auth.For_testing.restore_server_state previous);
      Server_auth.publish_server_state state;
      let router = Server_routes_http_routes_dashboard.add_routes ~sw ~clock:(Eio.Stdenv.clock env)
        (Http_server_eio.Router.create ()) in
      let paths = ["POST","/api/v1/setup/accounts/login";
        "POST","/api/v1/setup/accounts/login/invalid/input";
        "POST","/api/v1/setup/accounts/login/invalid/cancel";
        "GET","/api/v1/setup/accounts/login/invalid"] in
      List.iter (fun (method_,path) ->
        check string "anonymous denied" "401" (request router ~token:None ~method_ ~path ~body:"{}");
        check string "worker denied" "403" (request router ~token:(Some worker) ~method_ ~path ~body:"{}")) paths;
      List.iter (fun body -> check string "admin malformed login refused" "400"
        (request router ~token:(Some admin) ~method_:"POST" ~path:"/api/v1/setup/accounts/login" ~body))
        ["{"; {|{"integration_id":"codex","home":"/tmp/other"}|};
         {|{"integration_id":"codex","cli-path":"arbitrary"}|};
         {|{"integration_id":"codex","integration_id":"claude"}|};
         {|{"integration_id":"codex","account_ref":"bad"}|}];
      check string "invalid recovery reference refused" "404"
        (request router ~token:(Some admin) ~method_:"GET" ~path:"/api/v1/setup/accounts/login/invalid" ~body:"");
      (* An operator logs in to a client the workspace has not declared yet.
         The login gets past the choice of client and stops where it would
         start one: this process has no environment to start it in. A
         person's login of it is refused before that, with 400. *)
      let config = Filename.concat (Common.masc_dir_from_base_path ~base_path:base) "config" in
      Fs_compat.mkdir_p config;
      Out_channel.with_open_bin (Filename.concat config Config_dir_resolver.runtime_toml_filename)
        (fun out -> output_string out declared_toml);
      check string "an operator's login of an undeclared client" "503"
        (request router ~token:(Some admin) ~method_:"POST" ~path:"/api/v1/setup/accounts/login"
           ~body:{|{"integration_id":"codex"}|}))))
let () = run "setup-account-login-routes" ["boundaries", [test_case "admin and request boundaries" `Quick boundaries]]
