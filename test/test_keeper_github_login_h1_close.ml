(* #32910, the way it was reproduced: an HTTP/1.1 client opens the GitHub
   login stream, reads the one-time code, and goes away while gh waits for
   the device approval. The route, the identity stream and the local login
   lane are the real ones; [gh] is a stand-in on PATH that prints a code and
   then waits, as the real one does.

   HTTP/1.1 tells the server about a client that left only through a write
   that is not taken, and a waiting login writes nothing. The route's
   keepalive is what turns the departure into a closed response. Its interval
   runs on a mock clock here, so the test moves time instead of waiting it
   out. *)
open Alcotest

let require = function
  | Ok value -> value
  | Error detail -> fail detail
;;

(* Bounds a test that would otherwise hang on a process nothing stops. It is a
   fixture bound, not a login policy. *)
let patience_s = 10.0
let poll_s = 0.05

(* Ten times as long as the login takes to look at its response again, and
   longer than a SIGTERM to the stand-in gh takes to land. A response seen
   closed in this time would have stopped gh within it. *)
let unnoticed_window_s = 1.0
let one_time_code = "FAKE-CODE"

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK ->
    Unix.unlink path
;;

let write_file path content =
  Out_channel.with_open_bin path (fun out -> output_string out content)
;;

let shell_quote s = "'" ^ String.concat "'\\''" (String.split_on_char '\'' s) ^ "'"

(* Publishes its pid whole (by rename), prints the code on stderr as gh does,
   and then waits as gh does for the operator's approval. [exec] keeps the
   pid the server's child. *)
let fake_gh ~pid_path =
  Printf.sprintf
    "#!/bin/sh\n\
     case \"${1-}:${2-}\" in\n\
    \  auth:login)\n\
    \    printf '%%s' \"$$\" > %s\n\
    \    mv %s %s\n\
    \    printf '! First copy your one-time code: %s\\n' >&2\n\
    \    exec sleep 600\n\
    \    ;;\n\
    \  *) echo \"unexpected fake gh argv: $*\" >&2; exit 64 ;;\n\
     esac\n"
    (shell_quote (pid_path ^ ".partial"))
    (shell_quote (pid_path ^ ".partial"))
    (shell_quote pid_path)
    one_time_code
;;

let process_alive pid =
  match Unix.kill pid 0 with
  | () -> true
  | exception Unix.Unix_error (Unix.ESRCH, _, _) -> false
;;

let contains ~needle text =
  let n = String.length needle and m = String.length text in
  let rec at i = i + n <= m && (String.sub text i n = needle || at (i + 1)) in
  at 0
;;

let read_until flow needle =
  let buf = Cstruct.create 4096 and seen = Buffer.create 4096 in
  while not (contains ~needle (Buffer.contents seen)) do
    let n = Eio.Flow.single_read flow buf in
    Buffer.add_string seen (Cstruct.to_string ~len:n buf)
  done
;;

let with_docker_keeper run =
  let base_path = Filename.temp_dir "h1-github-login-" "" in
  let previous_fs = Fs_compat.get_fs_opt () in
  let previous_path = Sys.getenv "PATH" in
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "PATH" previous_path;
      (match previous_fs with
       | Some fs -> Fs_compat.set_fs fs
       | None -> Fs_compat.clear_fs ());
      remove_tree base_path)
    (fun () ->
       let fake_bin = Filename.concat base_path "fake-bin" in
       Unix.mkdir fake_bin 0o700;
       let pid_path = Filename.concat base_path "gh.pid" in
       let gh = Filename.concat fake_bin "gh" in
       write_file gh (fake_gh ~pid_path);
       Unix.chmod gh 0o700;
       Unix.putenv "PATH" (fake_bin ^ ":" ^ previous_path);
       Eio_main.run (fun env ->
         Fs_compat.set_fs (Eio.Stdenv.fs env);
         Process_eio.init
           ~cwd_default:Eio.Path.(Eio.Stdenv.fs env / Sys.getcwd ())
           ~proc_mgr:(Eio.Stdenv.process_mgr env)
           ~clock:(Eio.Stdenv.clock env);
         Fun.protect ~finally:Process_eio.reset_for_testing (fun () ->
           Eio.Switch.run (fun sw ->
             Eio_context.with_test_env
               ~net:(Eio.Stdenv.net env)
               ~clock:(Eio.Stdenv.clock env)
               ~mono_clock:(Eio.Stdenv.mono_clock env)
               ~sw
               (fun () ->
                  let state = Masc.Mcp_server.For_testing.create_state ~base_path in
                  let config = Masc.Mcp_server.workspace_config state in
                  ignore (Masc.Workspace.init config ~agent_name:None);
                  let keeper_name = "h1-login-fixture" in
                  let keeper_toml =
                    Keeper_sandbox_config.keeper_toml_path ~base_path ~agent_name:keeper_name
                  in
                  Fs_compat.mkdir_p (Filename.dirname keeper_toml);
                  write_file
                    keeper_toml
                    "[keeper]\ninstructions = \"GitHub login fixture\"\n\
                     sandbox_profile = \"docker\"\nsandbox_image = \"base\"\n";
                  let meta =
                    Masc_test_deps.meta_of_json_fixture
                      (`Assoc [ "name", `String keeper_name ])
                    |> require
                  in
                  Masc.Keeper_meta_store.replace_snapshot config meta |> require;
                  run env sw ~state ~keeper_name ~pid_path)))))
;;

let test_a_client_gone_from_a_quiet_login_stops_its_gh () =
  with_docker_keeper
  @@ fun env sw ~state ~keeper_name ~pid_path ->
  let clock = Eio.Stdenv.clock env in
  let mock = Eio_mock.Clock.make () in
  let route_clock = (mock :> float Eio.Time.clock_ty Eio.Resource.t) in
  let socket =
    Eio.Net.listen
      ~reuse_addr:true
      ~backlog:4
      ~sw
      (Eio.Stdenv.net env)
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port
    | `Unix _ -> fail "the test listens on TCP"
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Server_bootstrap_http.serve
      ~sw
      ~clock
      ~socket
      ~addr_label:"github login h1 close test"
      ~request_handler:(fun _addr (gluten_reqd : Httpun.Reqd.t Gluten.Reqd.t) ->
        let reqd = gluten_reqd.Gluten.Reqd.reqd in
        Server_dashboard_http_keeper_api_post.handle_keeper_github_login_post
          ~clock:route_clock
          state
          (Httpun.Reqd.request reqd)
          (Masc.Http_reqd.of_gluten gluten_reqd));
    `Stop_daemon);
  let within what f =
    match Eio.Time.with_timeout clock patience_s (fun () -> Ok (f ())) with
    | Ok value -> value
    | Error `Timeout -> failf "gave up waiting for %s" what
  in
  let pid =
    Eio.Switch.run (fun client_sw ->
      let flow =
        Eio.Net.connect
          ~sw:client_sw
          (Eio.Stdenv.net env)
          (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
      in
      Eio.Flow.copy_string
        (Printf.sprintf
           "POST /api/v1/keepers/%s/github-login HTTP/1.1\r\n\
            Host: 127.0.0.1\r\nContent-Length: 0\r\n\r\n"
           keeper_name)
        flow;
      within "the one-time code" (fun () -> read_until flow one_time_code);
      let pid = int_of_string (String.trim (In_channel.with_open_bin pid_path In_channel.input_all)) in
      check bool "gh waits for the approval while the client reads" true (process_alive pid);
      (* The operator closes the window. *)
      Eio.Flow.close flow;
      pid)
  in
  (* No keepalive is due yet, and the route writes nothing else while gh
     waits: the departure is not seen. *)
  Eio.Time.sleep clock unnoticed_window_s;
  check bool "before a keepalive is written the client's departure is not seen" true
    (process_alive pid);
  (* gh stops before its 600-second timeout only through the login's watch,
     which reads the response's [is_closed]. A stopped gh therefore says the
     keepalive write that failed closed the response. *)
  within "the server to stop the gh of a client that left" (fun () ->
    while process_alive pid do
      (* Each step is one keepalive interval on the route's clock. *)
      Eio_mock.Clock.set_time
        mock
        (Eio.Time.now route_clock +. Server_mcp_transport_http_headers.sse_ping_interval_s);
      Eio.Time.sleep clock poll_s
    done);
  check bool "the gh of a client that left was stopped and reaped" false (process_alive pid)
;;

let () =
  run
    "GitHub login over HTTP/1.1"
    [ ( "client gone"
      , [ test_case
            "a client gone from a quiet login stops its gh"
            `Quick
            test_a_client_gone_from_a_quiet_login_stops_its_gh
        ] )
    ]
;;
