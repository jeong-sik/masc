(* What a streaming request returns of a successful body. Under [Keep_body]
   the caller gets the whole body at the end as well as every chunk on the
   way; under [Discard_body] it gets the chunks and [()]: the reader keeps
   nothing, and its type gives it no way to return a body. No test here can
   see that no buffer is held. A refused request is read whole either way:
   its body is not in the stream's protocol. *)

module Pool = Masc_http_client.Pool

(* Several reads of Piaf's 16KB read buffer, so the body arrives in pieces. *)
let body_bytes = 64 * 1024

let streamed_body = String.init body_bytes (fun index -> Char.chr (Char.code 'a' + (index mod 26)))

let refusal_body = {|{"error":"refused"}|}

let start_server ~sw ~net =
  let listener = Eio.Net.listen ~sw ~backlog:8 net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
  let callback _ request _body =
    match Cohttp.Request.resource request with
    | "/refused" -> Cohttp_eio.Server.respond_string ~status:`Unauthorized ~body:refusal_body ()
    | _ -> Cohttp_eio.Server.respond_string ~status:`OK ~body:streamed_body ()
  in
  let server = Cohttp_eio.Server.make ~callback () in
  Eio.Fiber.fork_daemon ~sw (fun () -> Cohttp_eio.Server.run listener server ~on_error:raise);
  match Eio.Net.listening_addr listener with
  | `Tcp (_, port) -> Printf.sprintf "http://127.0.0.1:%d" port
  | `Unix _ -> Alcotest.fail "expected a TCP listener"

(* One stream against a fresh server and pool, with a fixture deadline outside
   every pool API. Returns the outcome and the bytes [on_chunk] received. *)
let stream ~retention path =
  Eio_main.run (fun env ->
    Eio.Time.with_timeout_exn env#clock 10.0 (fun () ->
      Eio.Switch.run (fun sw ->
        let base = start_server ~sw ~net:env#net in
        let pool = Pool.create ~sw ~env () in
        let chunks = Buffer.create body_bytes in
        let outcome =
          Pool.request_streaming pool ~retention ~clock:env#clock ~idle_timeout_sec:5.0
            ~method_:`GET ~url:(base ^ path) ~on_chunk:(Buffer.add_string chunks) ()
        in
        Pool.shutdown pool;
        outcome, Buffer.contents chunks)))

let test_keep_body_returns_the_whole_body () =
  match stream ~retention:Pool.Keep_body "/stream" with
  | Ok (Pool.Streamed { status; body; progress; _ }), chunks ->
    Alcotest.(check int) "status" 200 status;
    Alcotest.(check bool) "the whole body" true (String.equal streamed_body body);
    Alcotest.(check bool) "and every chunk on the way" true (String.equal streamed_body chunks);
    Alcotest.(check int) "every byte counted" body_bytes progress.bytes_received
  | Ok (Pool.Buffered response), _ -> Alcotest.failf "refused with %d" response.status
  | Error message, _ -> Alcotest.fail message

let test_discard_body_hands_every_chunk_on () =
  match stream ~retention:Pool.Discard_body "/stream" with
  | Ok (Pool.Streamed { status; body = (); progress; _ }), chunks ->
    Alcotest.(check int) "status" 200 status;
    Alcotest.(check bool) "every chunk reached on_chunk" true (String.equal streamed_body chunks);
    Alcotest.(check int) "every byte counted" body_bytes progress.bytes_received
  | Ok (Pool.Buffered response), _ -> Alcotest.failf "refused with %d" response.status
  | Error message, _ -> Alcotest.fail message

let test_a_refused_stream_is_read_whole_under_discard () =
  match stream ~retention:Pool.Discard_body "/refused" with
  | Ok (Pool.Buffered response), chunks ->
    Alcotest.(check int) "status" 401 response.status;
    Alcotest.(check string) "the refusal body" refusal_body response.body;
    Alcotest.(check string) "no chunk was handed on" "" chunks
  | Ok (Pool.Streamed _), _ -> Alcotest.fail "a 401 was streamed"
  | Error message, _ -> Alcotest.fail message

let () =
  Alcotest.run "Pool stream retention"
    [ "real HTTP/1",
      [ Alcotest.test_case "Keep_body returns the whole body" `Quick
          test_keep_body_returns_the_whole_body
      ; Alcotest.test_case "Discard_body hands every chunk on" `Quick
          test_discard_body_hands_every_chunk_on
      ; Alcotest.test_case "a refused stream is read whole under Discard_body" `Quick
          test_a_refused_stream_is_read_whole_under_discard
      ]
    ]
