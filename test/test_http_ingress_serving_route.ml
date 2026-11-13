(* E2 of RFC http-transport-runs-on-its-own-domain: a [Serving] route answers
   while the owner domain is stuck, and an [Owner] route waits for it.

   A real httpun connection runs through [Server_http_ingress.http1_handler]
   over a socket pair. One task on the owner's queue then computes for
   [block_s] without yielding. With the connection on a second domain the
   [Serving] route answers during the block; with the connection on the
   owner's domain the same route answers only after it, which is the
   difference the RFC is for. The client is a bare socket on a second domain
   in both placements, so the block never stops the client itself. *)

let block_s = 0.5
let serving_answer_bound_s = 0.05
let serving_requests = 20
let host = "localhost"
let port = 8935

let trust_policy () =
  match
    Server_request_authority.make_trust_policy
      ~bind_host:host
      ~bind_port:port
      ~https_port:None
      ~explicit_base_url:None
  with
  | Ok policy -> policy
  | Error error -> Alcotest.fail (Server_request_authority.trust_policy_error_to_string error)
;;

let respond_text body reqd =
  Masc.Http_reqd.respond_with_string
    reqd
    (Httpun.Response.create
       ~headers:
         (Httpun.Headers.of_list
            [ "content-type", "text/plain"
            ; "content-length", string_of_int (String.length body)
            ])
       `OK)
    body
;;

(* Each handler records the domain it ran on. *)
let routes ~ran =
  let record path = Atomic.set ran ((path, Domain.self ()) :: Atomic.get ran) in
  Masc.Http_server_eio.Router.create ()
  |> Server_route.Serving.get Server_route.Always_public "/beside" (fun _request reqd ->
    record "/beside";
    respond_text "beside" reqd)
  |> Server_route.get Server_route.Always_public "/owner" (fun _request reqd ->
    record "/owner";
    respond_text "owner" reqd)
;;

(* The one error these exchanges meet is the client leaving, and nobody is
   left to answer. *)
let error_handler _client_addr ?request:_ _error _respond = ()

let fixture_client : Eio.Net.Sockaddr.stream = `Tcp (Eio.Net.Ipaddr.V4.loopback, 54321)

(* The connection, on the calling domain, for as long as [sw] lives. *)
let serve_connection ?(client_addr = fixture_client) ~sw ~routes server_fd =
  let trust_policy = trust_policy () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Eio.Switch.run (fun conn_sw ->
      let flow = Eio_unix.Net.import_socket_stream ~sw:conn_sw ~close_unix:true server_fd in
      Masc.Http_reqd.with_connection_switch conn_sw (fun () ->
        Httpun_eio.Server.create_connection_handler
          ~sw:conn_sw
          ~request_handler:(Server_http_ingress.http1_handler ~trust_policy routes)
          ~error_handler
          client_addr
          flow));
    `Stop_daemon)
;;

let read_response reader =
  let status = Eio.Buf_read.line reader in
  let rec content_length found =
    match Eio.Buf_read.line reader with
    | "" -> found
    | line ->
      (match String.index_opt line ':' with
       | Some colon
         when String.lowercase_ascii (String.sub line 0 colon) = "content-length" ->
         let value = String.sub line (colon + 1) (String.length line - colon - 1) in
         content_length (int_of_string_opt (String.trim value))
       | Some _ | None -> content_length found)
  in
  match content_length None with
  | Some length -> status, Eio.Buf_read.take length reader
  | None -> Alcotest.failf "no content-length after %S" status
;;

type answer =
  { body : string
  ; elapsed_s : float
  ; block_done : bool (* the owner's block had ended when this answer arrived *)
  }

type seen =
  { owner_before : answer
  ; beside : answer list (* asked while the owner was blocked *)
  ; owner_after : answer (* asked right after them *)
  }

let client ~clock ~block_started ~block_done client_fd =
  Eio.Switch.run
  @@ fun sw ->
  let flow = Eio_unix.Net.import_socket_stream ~sw ~close_unix:true client_fd in
  let reader = Eio.Buf_read.of_flow flow ~max_size:(1 lsl 16) in
  let ask path =
    let asked = Eio.Time.now clock in
    Eio.Flow.copy_string
      (Printf.sprintf "GET %s HTTP/1.1\r\nhost: %s:%d\r\n\r\n" path host port)
      flow;
    let _status, body = read_response reader in
    { body; elapsed_s = Eio.Time.now clock -. asked; block_done = Atomic.get block_done }
  in
  let owner_before = ask "/owner" in
  let post =
    match Eio_context.owner_post () with
    | Some post -> post
    | None -> Alcotest.fail "the client's domain has no owner to post to"
  in
  post (fun () ->
    Atomic.set block_started true;
    (* NDT-OK: a wall-clock busy wait is the stall under test. *)
    let until = Unix.gettimeofday () +. block_s in
    while Unix.gettimeofday () < until do
      ()
    done;
    Atomic.set block_done true);
  while not (Atomic.get block_started) do
    Eio.Fiber.yield ()
  done;
  let beside = List.init serving_requests (fun _ -> ask "/beside") in
  let owner_after = ask "/owner" in
  { owner_before; beside; owner_after }
;;

type placement =
  | Beside_the_owner (* the connection runs on a second domain *)
  | On_the_owner (* the connection runs on the owner's domain *)

type outcome =
  { seen : seen
  ; ran : (string * Domain.id) list
  ; owner_domain : Domain.id
  }

let run placement =
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let domain_mgr = Eio.Stdenv.domain_mgr env in
  Eio.Time.with_timeout_exn clock 60.0
  @@ fun () ->
  Eio.Switch.run
  @@ fun owner_sw ->
  Eio_context.with_test_env
    ~net:(Eio.Stdenv.net env)
    ~clock
    ~mono_clock:(Eio.Stdenv.mono_clock env)
    ~sw:owner_sw
  @@ fun () ->
  let ran = Atomic.make [] in
  let routes = routes ~ran in
  let block_started = Atomic.make false in
  let block_done = Atomic.make false in
  let server_fd, client_fd = Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  let client () = client ~clock ~block_started ~block_done client_fd in
  let seen =
    match placement with
    | On_the_owner ->
      serve_connection ~sw:owner_sw ~routes server_fd;
      Eio.Domain_manager.run domain_mgr client
    | Beside_the_owner ->
      Eio.Domain_manager.run domain_mgr (fun () ->
        Eio.Switch.run (fun sw ->
          serve_connection ~sw ~routes server_fd;
          Eio.Domain_manager.run domain_mgr client))
  in
  { seen; ran = Atomic.get ran; owner_domain = Domain.self () }
;;

let domains_of path outcome =
  List.filter_map
    (fun (ran_path, domain) -> if String.equal ran_path path then Some domain else None)
    outcome.ran
;;

let test_serving_route_answers_while_the_owner_is_blocked () =
  let outcome = run Beside_the_owner in
  let { owner_before; beside; owner_after } = outcome.seen in
  Alcotest.(check string) "the owner route answers before the block" "owner" owner_before.body;
  Alcotest.(check int) "every serving request is answered" serving_requests (List.length beside);
  List.iteri
    (fun index answer ->
       Alcotest.(check string) (Printf.sprintf "serving answer %d" index) "beside" answer.body;
       Alcotest.(check bool)
         (Printf.sprintf "serving answer %d came while the owner was blocked" index)
         false
         answer.block_done;
       Alcotest.(check bool)
         (Printf.sprintf
            "serving answer %d came within %.0f ms (took %.1f ms)"
            index
            (serving_answer_bound_s *. 1000.0)
            (answer.elapsed_s *. 1000.0))
         true
         (answer.elapsed_s < serving_answer_bound_s))
    beside;
  Alcotest.(check string) "the owner route answers" "owner" owner_after.body;
  Alcotest.(check bool)
    "the owner route answered only after the block ended"
    true
    owner_after.block_done;
  Alcotest.(check bool)
    "the serving handler never ran on the owner's domain"
    true
    (List.for_all (fun domain -> domain <> outcome.owner_domain) (domains_of "/beside" outcome));
  Alcotest.(check bool)
    "the owner handler ran on the owner's domain"
    true
    (List.for_all (fun domain -> domain = outcome.owner_domain) (domains_of "/owner" outcome))
;;

let test_serving_route_waits_when_connections_run_on_the_owner () =
  let outcome = run On_the_owner in
  let { beside; owner_after; _ } = outcome.seen in
  (match beside with
   | first :: _ ->
     Alcotest.(check string) "the serving route answers" "beside" first.body;
     Alcotest.(check bool)
       "its first answer came only after the block ended"
       true
       first.block_done
   | [] -> Alcotest.fail "no serving request was answered");
  Alcotest.(check string) "the owner route answers" "owner" owner_after.body;
  Alcotest.(check bool)
    "both handlers ran on the owner's domain"
    true
    (List.for_all (fun (_path, domain) -> domain = outcome.owner_domain) outcome.ran)
;;

(* A probe is left out of the client address limit only while answering it
   reads no credential. A header is a credential here whatever its value: the
   server has to judge it. *)
let test_a_health_probe_is_exempt_only_while_it_reads_no_credential () =
  let exempt ?(headers = []) path =
    Server_http_ingress.health_probe_exempt
      ~path
      (Httpun.Request.create ~headers:(Httpun.Headers.of_list headers) `GET path)
  in
  let bearer = [ "authorization", "Bearer x" ] in
  let check name expected actual = Alcotest.(check bool) name expected actual in
  check "the health route without a credential" true (exempt Server_health_paths.health);
  check "the health route with a bearer" false (exempt ~headers:bearer Server_health_paths.health);
  check
    "the health route with a header that is not a bearer"
    false
    (exempt ~headers:[ "authorization", "Basic x" ] Server_health_paths.health);
  check
    "the health route with an internal token"
    false
    (exempt ~headers:[ "x-masc-internal-token", "x" ] Server_health_paths.health);
  check "liveness with a bearer" true (exempt ~headers:bearer Server_health_paths.liveness);
  check "readiness with a bearer" true (exempt ~headers:bearer Server_health_paths.readiness);
  check "a route that is not a probe" false (exempt "/api/v1/status")
;;

(* The ingress applies that rule to the limit of a client address. The client
   here has an address no other test uses, so its bucket holds only what this
   test does. A request the limit leaves out never touches the bucket; a
   counted one takes a token from it, and is refused once the bucket is empty. *)
let limited_client : Eio.Net.Sockaddr.stream =
  `Tcp (Eio.Net.Ipaddr.of_raw "\127\000\000\077", 54321)
;;

let probe_routes () =
  List.fold_left
    (fun router path ->
       Server_route.Serving.get Server_route.Always_public path
         (fun _request reqd -> respond_text "probe" reqd)
         router)
    (Masc.Http_server_eio.Router.create ())
    [ Server_health_paths.health; Server_health_paths.liveness; Server_health_paths.readiness ]
;;

let status_code status_line =
  match String.split_on_char ' ' status_line with
  | _ :: code :: _ ->
    (match int_of_string_opt code with
     | Some code -> code
     | None -> Alcotest.failf "unreadable status line %S" status_line)
  | _ -> Alcotest.failf "unreadable status line %S" status_line
;;

(* [ask ?headers path] is the status the ingress answers [limited_client]. *)
let with_limited_client f =
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Time.with_timeout_exn clock 60.0
  @@ fun () ->
  Eio.Switch.run
  @@ fun sw ->
  Eio_context.with_test_env
    ~net:(Eio.Stdenv.net env)
    ~clock
    ~mono_clock:(Eio.Stdenv.mono_clock env)
    ~sw
  @@ fun () ->
  let server_fd, client_fd = Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  serve_connection ~client_addr:limited_client ~sw ~routes:(probe_routes ()) server_fd;
  let flow = Eio_unix.Net.import_socket_stream ~sw ~close_unix:true client_fd in
  let reader = Eio.Buf_read.of_flow flow ~max_size:(1 lsl 16) in
  f (fun ?(headers = []) path ->
    let header_lines =
      List.map (fun (name, value) -> Printf.sprintf "%s: %s\r\n" name value) headers
      |> String.concat ""
    in
    Eio.Flow.copy_string
      (Printf.sprintf "GET %s HTTP/1.1\r\nhost: %s:%d\r\n%s\r\n" path host port header_lines)
      flow;
    let status_line, (_ : string) = read_response reader in
    status_code status_line)
;;

let test_the_ingress_counts_a_health_request_only_when_it_carries_a_credential () =
  with_limited_client
  @@ fun ask ->
  let key = Masc.Rate_limit.key_of_sockaddr limited_client in
  let full = Masc.Rate_limit.burst_of_config () in
  let left () = Masc.Rate_limit.remaining_global ~key in
  let bearer = [ "authorization", "Bearer x" ] in
  Alcotest.(check int) "nothing has been counted for this client" full (left ());
  List.iter
    (fun (name, headers, path) ->
       Alcotest.(check int) (name ^ " is answered") 200 (ask ~headers path);
       Alcotest.(check int) (name ^ " is not counted") full (left ()))
    [ "the health route without a credential", [], Server_health_paths.health
    ; "liveness with a bearer", bearer, Server_health_paths.liveness
    ; "readiness with a bearer", bearer, Server_health_paths.readiness
    ];
  Alcotest.(check int) "the health route with a bearer is answered" 200
    (ask ~headers:bearer Server_health_paths.health);
  Alcotest.(check int) "and takes one token" (full - 1) (left ());
  (* An empty bucket gains a token every few milliseconds, so a round empties
     it and asks at once; one round in which the ask arrives before the next
     token is enough. A request the limit leaves out is answered in every
     round, whatever the bucket holds. *)
  let rec refused_within rounds =
    if rounds = 0
    then false
    else (
      while Masc.Rate_limit.check_global ~key do
        ()
      done;
      Alcotest.(check int) "an empty bucket does not stop a request without a credential" 200
        (ask Server_health_paths.health);
      Alcotest.(check int) "nor a sibling probe" 200
        (ask ~headers:bearer Server_health_paths.liveness);
      match ask ~headers:bearer Server_health_paths.health with
      | 429 -> true
      | 200 -> refused_within (rounds - 1)
      | other -> Alcotest.failf "unexpected status %d for a counted health request" other)
  in
  Alcotest.(check bool) "a health request with a bearer over the limit is refused" true
    (refused_within 200)
;;

let () =
  Alcotest.run
    "http_ingress_serving_route"
    [ ( "owner blocked"
      , [ Alcotest.test_case
            "a Serving route answers while the owner is blocked"
            `Quick
            test_serving_route_answers_while_the_owner_is_blocked
        ; Alcotest.test_case
            "the same route waits when connections run on the owner's domain"
            `Quick
            test_serving_route_waits_when_connections_run_on_the_owner
        ] )
    ; ( "client address limit"
      , [ Alcotest.test_case
            "a health probe is exempt only while it reads no credential"
            `Quick
            test_a_health_probe_is_exempt_only_while_it_reads_no_credential
        ; Alcotest.test_case
            "the ingress counts a health request only when it carries a credential"
            `Quick
            test_the_ingress_counts_a_health_request_only_when_it_carries_a_credential
        ] )
    ]
;;
