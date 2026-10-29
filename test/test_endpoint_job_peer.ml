module Peer = Endpoint_job_peer

let require = function Ok value -> value | Error error -> Alcotest.fail (Peer.error_to_string error)
let check label value = Alcotest.(check bool) label true value
let run f () = Eio_main.run (fun _ -> Eio.Switch.run f)

let kernel_identity_does_not_consume_or_trust_request_bytes = run (fun sw ->
  let client,server=Eio_unix.Net.socketpair_stream ~sw () in
  let claimed="{\"uid\":-1,\"keeper\":\"claimed owner\"}" in
  Eio.Flow.copy_string claimed client;
  let peer=Peer.authenticate ~allowed_uid:(Unix.geteuid ()) server |> require in
  let identity=Peer.identity peer in
  check "actual kernel UID matches configured OS account" (identity.uid=Unix.geteuid ());
  check "actual socketpair credentials retain their original process" (identity.process_id=Unix.getpid ());
  check "actual socketpair credentials retain their original group" (identity.gid=Unix.getegid ());
  Peer.revalidate ~allowed_uid:(Unix.geteuid ()) peer |> require;
  let buffer=Cstruct.create (String.length claimed) in
  Eio.Flow.read_exact server buffer;
  Alcotest.(check string) "authentication neither consumes nor parses claimed identity bytes"
    claimed (Cstruct.to_string buffer);
  (match Peer.authenticate ~allowed_uid:(Unix.geteuid ()+1) server with
   | Error error -> check "another configured account is refused" (error=Peer.Uid_mismatch)
   | Ok _ -> Alcotest.fail "a request body substituted another kernel UID");
  match Peer.revalidate ~allowed_uid:(Unix.geteuid ()+1) peer with
  | Error error -> check "existing peer cannot authorize another service account" (error=Peer.Uid_mismatch)
  | Ok () -> Alcotest.fail "peer credentials authorized another configured account")

let unsupported_transports_never_produce_an_identity = run (fun sw ->
  let expect_refused label resource =
    match Peer.authenticate ~allowed_uid:(Unix.geteuid ()) resource with
    | Error error -> check label (error=Peer.Unsupported_transport)
    | Ok _ -> Alcotest.fail (label ^ " yielded a peer identity")
  in
  expect_refused "memory flow has no kernel peer" (Eio.Flow.string_source "claimed UID");
  let source,_=Eio_unix.pipe sw in
  expect_refused "a pipe is not a control connection" source;
  let datagram,_=Eio_unix.Net.socketpair_datagram ~sw () in
  expect_refused "datagram credentials cannot authorize a stream control" datagram;
  let raw=Unix.socket ~cloexec:true Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  let unconnected=Eio_unix.Net.import_socket_stream ~sw ~close_unix:true raw in
  (match Peer.authenticate ~allowed_uid:(Unix.geteuid ()) unconnected with
   | Error error -> check "unconnected stream has no peer" (error=Peer.Not_connected)
   | Ok _ -> Alcotest.fail "an unconnected stream granted control");
  let raw_tcp=Unix.socket ~cloexec:true Unix.PF_INET Unix.SOCK_STREAM 0 in
  let tcp=Eio_unix.Net.import_socket_stream ~sw ~close_unix:true raw_tcp in
  expect_refused "TCP never falls back to a claimed local identity" tcp)

let closed_wrappers_cannot_be_reused_for_a_new_connection = run (fun sw ->
  let _,server=Eio_unix.Net.socketpair_stream ~sw () in
  let peer=Peer.authenticate ~allowed_uid:(Unix.geteuid ()) server |> require in
  Eio.Flow.close server;
  (match Peer.revalidate ~allowed_uid:(Unix.geteuid ()) peer with
   | Error error -> check "closed original wrapper stays closed" (error=Peer.Closed)
   | Ok () -> Alcotest.fail "closed original connection remained authorized");
  let _,replacement=Eio_unix.Net.socketpair_stream ~sw () in
  let fresh=Peer.authenticate ~allowed_uid:(Unix.geteuid ()) replacement |> require in
  Peer.revalidate ~allowed_uid:(Unix.geteuid ()) fresh |> require;
  (match Peer.revalidate ~allowed_uid:(Unix.geteuid ()) peer with
   | Error error -> check "new connection does not restore the original wrapper" (error=Peer.Closed)
   | Ok () -> Alcotest.fail "new connection revived the old peer");
  match Peer.authenticate ~allowed_uid:(Unix.geteuid ()) server with
  | Error error -> check "reauthentication also refuses the closed wrapper" (error=Peer.Closed)
  | Ok _ -> Alcotest.fail "closed socket resource yielded another identity")

let invalid_policy_and_unsupported_platform_are_explicit = run (fun sw ->
  let _,server=Eio_unix.Net.socketpair_stream ~sw () in
  (match Peer.authenticate ~allowed_uid:(-1) server with
   | Error error -> check "invalid account policy is explicit" (error=Peer.Invalid_uid)
   | Ok _ -> Alcotest.fail "negative policy UID granted control");
  if not Peer.supported then
    match Peer.authenticate ~allowed_uid:(Unix.geteuid ()) server with
    | Error error -> check "unsupported platform never accepts claimed credentials" (error=Peer.Unsupported)
    | Ok _ -> Alcotest.fail "unsupported platform fabricated peer credentials")

let () =
  let cases=if Peer.supported then [
    "kernel identity preserves request bytes",kernel_identity_does_not_consume_or_trust_request_bytes;
    "wrong transports do not authenticate",unsupported_transports_never_produce_an_identity;
    "closed original cannot adopt a new connection",closed_wrappers_cannot_be_reused_for_a_new_connection;
  ] else [] in
  Alcotest.run "Endpoint peer credentials" ["actual connection",
    List.map (fun (name,test) -> Alcotest.test_case name `Quick test)
      (("policy and platform refusals",invalid_policy_and_unsupported_platform_are_explicit)::cases)]
