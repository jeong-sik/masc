open Alcotest

let closable_headers = Cohttp.Header.of_list [ "connection", "close" ]

let count_open_fds () =
  let fd_dir =
    if Sys.file_exists "/dev/fd"
    then "/dev/fd"
    else if Sys.file_exists "/proc/self/fd"
    then "/proc/self/fd"
    else Alcotest.fail "no fd directory available for regression test"
  in
  Sys.readdir fd_dir |> Array.length
;;

let find_free_port () =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close socket)
    (fun () ->
       Unix.setsockopt socket Unix.SO_REUSEADDR true;
       (match Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0)) with
        | () -> ()
        | exception Unix.Unix_error ((Unix.EPERM | Unix.EACCES), "bind", _) ->
          Alcotest.skip ());
       match Unix.getsockname socket with
       | Unix.ADDR_INET (_, port) -> port
       | _ -> failwith "unexpected socket family")
;;

let start_mock_server ~sw ~net ~port =
  let handler _conn _req body =
    let _ = Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) in
    Cohttp_eio.Server.respond_string ~status:`OK ~body:"ok" ()
  in
  let socket =
    Eio.Net.listen
      net
      ~sw
      ~backlog:8
      ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let server = Cohttp_eio.Server.make ~callback:handler () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()))
;;

let rec wait_for_fd_baseline ~clock ~baseline ~allowed_extra_fds ~attempts_left =
  let current = count_open_fds () in
  if current <= baseline + allowed_extra_fds || attempts_left <= 0
  then current
  else (
    Eio.Time.sleep clock 0.01;
    wait_for_fd_baseline
      ~clock
      ~baseline
      ~allowed_extra_fds
      ~attempts_left:(attempts_left - 1))
;;

let wrap_with_close_counter
      close_count
      (flow : [ `Close | `Flow | `R | `Shutdown | `W ] Eio.Resource.t)
  =
  let (Eio.Resource.T (resource, ops)) = flow in
  let close_resource = Eio.Resource.get ops Eio.Resource.Close in
  let wrapped_ops =
    Eio.Resource.handler
      (Eio.Resource.H
         ( Eio.Resource.Close
         , fun value ->
             Atomic.incr close_count;
             close_resource value )
       :: Eio.Resource.bindings ops)
  in
  (Eio.Resource.T (resource, wrapped_ops)
   : [ `Close | `Flow | `R | `Shutdown | `W ] Eio.Resource.t)
;;

let exercise_client ~sw ~net ~https ~request_count ~url =
  let client = Masc_http_client.make_closing_client ~sw ~net ~https in
  let uri = Uri.of_string url in
  for _ = 1 to request_count do
    let resp, body = Cohttp_eio.Client.get client ~sw ~headers:closable_headers uri in
    Alcotest.(check int)
      "status"
      200
      (Cohttp.Response.status resp |> Cohttp.Code.code_of_status);
    let body_text = Eio.Buf_read.(parse_exn take_all) body ~max_size:1024 in
    Alcotest.(check string) "body" "ok" body_text
  done
;;

let test_release_closes_all_tracked_connections () =
  Eio_main.run
  @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run
  @@ fun server_sw ->
  let port = find_free_port () in
  start_mock_server ~sw:server_sw ~net ~port;
  let baseline = count_open_fds () in
  Eio.Switch.run (fun client_sw ->
    exercise_client
      ~sw:client_sw
      ~net
      ~https:None
      ~request_count:12
      ~url:(Printf.sprintf "http://127.0.0.1:%d/repeat" port));
  let after_release =
    wait_for_fd_baseline ~clock ~baseline ~allowed_extra_fds:1 ~attempts_left:50
  in
  (* The same-process mock server can briefly retain one accepted fd while the
     daemon server fiber drains the final request. Client-side leaks should not
     exceed that slack after the request switch releases. *)
  check
    bool
    "fd count returns to baseline (+1 transient server slack)"
    true
    (after_release <= baseline + 1)
;;

let test_https_wrapper_close_is_invoked_for_each_connection () =
  Eio_main.run
  @@ fun env ->
  let net = Eio.Stdenv.net env in
  let close_count = Atomic.make 0 in
  let wrap _uri raw =
    wrap_with_close_counter
      close_count
      (raw :> [ `Close | `Flow | `R | `Shutdown | `W ] Eio.Resource.t)
  in
  Eio.Switch.run
  @@ fun server_sw ->
  let port = find_free_port () in
  start_mock_server ~sw:server_sw ~net ~port;
  let request_count = 5 in
  Eio.Switch.run (fun client_sw ->
    exercise_client
      ~sw:client_sw
      ~net
      ~https:(Some wrap)
      ~request_count
      ~url:(Printf.sprintf "https://127.0.0.1:%d/wrapped" port));
  check
    int
    "wrapper close count matches request count"
    request_count
    (Atomic.get close_count)
;;

let () =
  run
    "masc_http_client"
    [ ( "closing"
      , [ test_case
            "release closes all tracked connections"
            `Quick
            test_release_closes_all_tracked_connections
        ; test_case
            "https wrapper close is invoked for each connection"
            `Quick
            test_https_wrapper_close_is_invoked_for_each_connection
        ] )
    ]
;;
