module Pool = Masc_http_client.Pool

(* Control DNS while retaining real Unix sockets and their capabilities.
   Piaf uses the Unix descriptor for socket options during construction. *)
module Routed_net = struct
  type tag = [ `Generic | `Unix ]
  type t = {
    net : tag Eio.Net.ty Eio.Resource.t;
    resolve : service:string -> string -> Eio.Net.Sockaddr.stream list;
    attempted : Eio.Net.Sockaddr.stream list ref;
  }

  let connect t ~sw address =
    t.attempted := address :: !(t.attempted);
    Eio.Net.connect ~sw t.net address
  let getaddrinfo t ~service host =
    (t.resolve ~service host :> Eio.Net.Sockaddr.t list)
  let getnameinfo t = Eio.Net.getnameinfo t.net
  let listen t ~reuse_addr ~reuse_port ~backlog ~sw address =
    Eio.Net.listen t.net ~reuse_addr ~reuse_port ~backlog ~sw address
  let datagram_socket t ~reuse_addr ~reuse_port ~sw address =
    Eio.Net.datagram_socket t.net ~reuse_addr ~reuse_port ~sw address
end

let routed_env (env : Eio_unix.Stdenv.base) ~resolve ~attempted =
  let net = Eio.Resource.T
    ({ Routed_net.net = env#net; resolve; attempted },
     Eio.Net.Pi.network (module Routed_net)) in
  object
    method net = net
    method stdin = env#stdin
    method stdout = env#stdout
    method stderr = env#stderr
    method domain_mgr = env#domain_mgr
    method process_mgr = env#process_mgr
    method clock = env#clock
    method mono_clock = env#mono_clock
    method fs = env#fs
    method cwd = env#cwd
    method secure_random = env#secure_random
    method debug = env#debug
    method backend_id = env#backend_id
  end

let with_runtime f () =
  Eio_main.run (fun env ->
    (* Bound ordinary fixture I/O; CI's process timeout covers protected
       cleanup if a resource-ownership regression deadlocks. *)
    Eio.Time.with_timeout_exn env#clock 5.0 (fun () ->
      Eio.Switch.run (fun sw -> f env sw)))

let start_server ~sw ~net callback =
  let listener = Eio.Net.listen ~sw ~backlog:8 net
    (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
  let server = Cohttp_eio.Server.make ~callback () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Cohttp_eio.Server.run listener server ~on_error:raise);
  Eio.Net.listening_addr listener

let refused_address ~sw ~net =
  let listener = Eio.Net.listen ~sw ~backlog:1 net
    (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
  let address = Eio.Net.listening_addr listener in
  Eio.Resource.close listener;
  address

let address_strings addresses =
  List.map (Format.asprintf "%a" Eio.Net.Sockaddr.pp) addresses

let check_attempts expected attempted =
  Alcotest.(check (list string)) "actual TCP destinations"
    (address_strings expected) (address_strings (List.rev !attempted))

let check_dns ~service queries =
  Alcotest.(check (pair string string)) "original DNS authority"
    ("provider.test", service) queries

let post ?(url = "http://provider.test:8080/request?turn=1") pool =
  match Pool.request pool ~method_:`POST
    ~url ~body:"one request" () with
  | Ok response -> response
  | Error msg -> Alcotest.fail msg

let read_request requests request body =
  let payload = Eio.Buf_read.(of_flow ~max_size:4096 body |> take_all) in
  requests := (Cohttp.Request.meth request, Cohttp.Request.resource request,
    Cohttp.Header.get (Cohttp.Request.headers request) "host", payload) :: !requests

let check_request_identity ~host:expected_host requests =
  match !requests with
  | [method_, target, host, body] ->
    Alcotest.(check string) "HTTP method preserved" "POST"
      (Cohttp.Code.string_of_method method_);
    Alcotest.(check string) "request target preserved" "/request?turn=1" target;
    Alcotest.(check (option string)) "original Host header preserved"
      (Some expected_host) host;
    Alcotest.(check string) "request body preserved" "one request" body
  | _ -> Alcotest.fail "expected exactly one HTTP dispatch"

let test_selected_address_handles_http = with_runtime (fun env sw ->
  let requests = ref [] in
  let healthy = start_server ~sw ~net:env#net (fun _ request body ->
    read_request requests request body;
    Cohttp_eio.Server.respond_string ~status:`Service_unavailable
      ~body:"selected server" ()) in
  let refused = refused_address ~sw ~net:env#net in
  let attempted = ref [] in
  let queries = ref [] in
  let resolve ~service host =
    queries := (host, service) :: !queries;
    [refused; healthy] in
  let pool = Pool.create ~sw ~env:(routed_env env ~resolve ~attempted) () in
  let response = post pool in
  Alcotest.(check int) "HTTP failure response returned without replay" 503 response.status;
  Alcotest.(check string) "response came from selected address"
    "selected server" response.body;
  check_request_identity ~host:"provider.test:8080" requests;
  check_attempts [refused; healthy; healthy] attempted;
  (match !queries with
   | [query] -> check_dns ~service:"8080" query
   | _ -> Alcotest.fail "Piaf creation must use the successful probe address");
  Pool.shutdown pool)

let test_reconnect_resolves_original_host_again = with_runtime (fun env sw ->
  let first_requests = ref [] in
  let second_requests = ref [] in
  let close_headers = Cohttp.Header.init_with "connection" "close" in
  let second = start_server ~sw ~net:env#net (fun _ request body ->
    read_request second_requests request body;
    Cohttp_eio.Server.respond_string ~headers:close_headers ~status:`OK
      ~body:"new DNS address" ()) in
  let addresses = ref [] in
  let first = start_server ~sw ~net:env#net (fun _ request body ->
    read_request first_requests request body;
    addresses := [second];
    Cohttp_eio.Server.respond_string ~headers:close_headers ~status:`OK
      ~body:"first DNS address" ()) in
  addresses := [first];
  let attempted = ref [] in
  let queries = ref [] in
  let resolve ~service host =
    queries := (host, service) :: !queries;
    !addresses in
  let pool = Pool.create ~sw ~env:(routed_env env ~resolve ~attempted) () in
  let post pool = post ~url:"http://provider.test/request?turn=1" pool in
  Alcotest.(check string) "initial request" "first DNS address" (post pool).body;
  Alcotest.(check string) "reconnect follows changed original-host DNS"
    "new DNS address" (post pool).body;
  check_request_identity ~host:"provider.test" first_requests;
  check_request_identity ~host:"provider.test" second_requests;
  check_attempts [first; first; second] attempted;
  Alcotest.(check int) "original resolver consulted again after construction"
    2 (List.length !queries);
  List.iter (check_dns ~service:"80") !queries;
  let stats = Pool.stats pool in
  Alcotest.(check int) "reconnect uses the existing Piaf client" 1 stats.create_count_total;
  Alcotest.(check int) "second request acquired that client" 1 stats.reuse_count_total;
  Pool.shutdown pool)

let () =
  Alcotest.run "Pool address selection"
    ["real HTTP",
     [Alcotest.test_case "selected probe address handles one HTTP request" `Quick
        test_selected_address_handles_http;
      Alcotest.test_case "construction address override ends before reconnect" `Quick
        test_reconnect_resolves_original_host_again]]
