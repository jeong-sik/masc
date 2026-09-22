(* An H2 response larger than the client's flow-control window reaches the
   client whole. h2 0.13.0 ends the stream at the window when the body writer
   was closed with bytes still unsent (anmonteiro/ocaml-h2#278), so a client
   that keeps the default window got a 200 carrying only the first 65535
   bytes. Every case runs a real H2 exchange in memory, an h2 client
   connection pumped against a server connection whose handler answers
   through the gateway helpers, so what is checked is what a peer sees on the
   wire. *)

open Alcotest

module Helpers = Server_h2_gateway_helpers

(* The window every stream starts with until the peer's SETTINGS change it
   (RFC 9113 6.9.2). h2's own client default advertises 2^27, which hides the
   cut, so the client here states this value. *)
let default_window = 65535

(* Two windows: the first flush can carry only half of the body, and the rest
   has to wait for the client's WINDOW_UPDATE. *)
let response_size = 2 * default_window

type reply = { status : int; body : string }

(* Bytes one side wrote that the other side's [read] has not taken yet. h2
   reads whole frames, and a frame can be split across iovecs or writes, so
   the unconsumed tail is offered again together with the next bytes. *)
type lane = { mutable pending : string }

let transfer lane next_write report_write read =
  let rec drain progressed =
    match next_write () with
    | `Write iovecs ->
      let chunk = Buffer.create 4096 in
      Buffer.add_string chunk lane.pending;
      let written =
        List.fold_left
          (fun total (iov : Bigstringaf.t H2.IOVec.t) ->
            Buffer.add_string chunk
              (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
            total + iov.len)
          0 iovecs
      in
      report_write (`Ok written);
      let data = Buffer.contents chunk in
      let length = String.length data in
      let consumed =
        read (Bigstringaf.of_string data ~off:0 ~len:length) ~off:0 ~len:length
      in
      lane.pending <- String.sub data consumed (length - consumed);
      drain true
    | `Yield | `Close _ -> progressed
  in
  drain false

(* The client reads every byte as it arrives, which is what makes it send
   WINDOW_UPDATE. A server that ends the stream early completes the exchange
   with a short body; a server that never sends the rest, or never ends the
   stream, stops making progress and the pump fails instead of hanging. *)
let exchange ?error_handler ~handler target =
  let status = ref None in
  let body = Buffer.create response_size in
  let complete = ref false in
  let client =
    H2.Client_connection.create
      ~config:
        { H2.Config.default with
          H2.Config.initial_window_size = Int32.of_int default_window
        }
      ~error_handler:(fun _ -> fail "H2 connection error")
      ()
  in
  let request =
    H2.Request.create ~scheme:"http" `GET target
      ~headers:(H2.Headers.of_list [ ":authority", "localhost:8935" ])
  in
  let writer =
    H2.Client_connection.request client request
      ~error_handler:(fun _ -> fail "H2 stream error")
      ~response_handler:(fun response reader ->
        status := Some (H2.Status.to_code response.H2.Response.status);
        let rec consume () =
          H2.Body.Reader.schedule_read reader
            ~on_eof:(fun () -> complete := true)
            ~on_read:(fun buffer ~off ~len ->
              Buffer.add_string body (Bigstringaf.substring buffer ~off ~len);
              consume ())
        in
        consume ())
  in
  H2.Body.Writer.close writer;
  let server = H2.Server_connection.create ?error_handler handler in
  let to_server = { pending = "" } in
  let to_client = { pending = "" } in
  let rec pump () =
    let sent =
      transfer to_server
        (fun () -> H2.Client_connection.next_write_operation client)
        (H2.Client_connection.report_write_result client)
        (H2.Server_connection.read server)
    in
    let received =
      transfer to_client
        (fun () -> H2.Server_connection.next_write_operation server)
        (H2.Server_connection.report_write_result server)
        (H2.Client_connection.read client)
    in
    if !complete then ()
    else if sent || received then pump ()
    else fail "H2 exchange stalled before the response completed"
  in
  pump ();
  match !status with
  | Some status -> { status; body = Buffer.contents body }
  | None -> fail "the response carried no headers"

(* A repeating alphabet rather than one byte over and over, so a body pasted
   together in the wrong order shows up in the comparison unless the pieces
   happen to be multiples of 26. What catches a missing stretch is the length
   check. *)
let payload =
  let alphabet = "abcdefghijklmnopqrstuvwxyz" in
  String.init response_size (fun index ->
    alphabet.[index mod String.length alphabet])

let test_response_over_the_window_arrives_whole () =
  let reply =
    exchange
      ~handler:(fun reqd ->
        Helpers.h2_respond_bytes ~content_type:"application/octet-stream" reqd
          payload)
      "/large"
  in
  check int "answered" 200 reply.status;
  check int "every byte arrived" response_size (String.length reply.body);
  check bool "the bytes are the ones written" true
    (String.equal payload reply.body)

(* The close now waits for a flush. With nothing written, the flush has
   nothing to wait for and the stream still has to end. *)
let test_empty_response_still_ends_its_stream () =
  let reply =
    exchange ~handler:(fun reqd -> Helpers.h2_respond_text reqd "") "/empty"
  in
  check int "answered" 200 reply.status;
  check string "no body" "" reply.body

(* The gateway's error handler writes its message and closes the body the same
   way, and it is the one site where h2 has already set the stream's error
   code, so the stream ends with RST_STREAM once the body is out. Its message
   is the exception's text, which is how this case gets an error body larger
   than the window. The text goes to the log too, so the console writer is
   swapped for one that keeps it out of the test output. *)
let test_error_handler_body_arrives_whole () =
  let expected = Printexc.to_string (Failure payload) in
  Console_sink.For_testing.reset ();
  Console_sink.For_testing.set_writer (Some (fun _line -> ()));
  let reply =
    Fun.protect ~finally:Console_sink.For_testing.reset (fun () ->
      exchange
        ~error_handler:(Server_h2_gateway.make_error_handler () ())
        ~handler:(fun reqd -> H2.Reqd.report_exn reqd (Failure payload))
        "/boom")
  in
  check int "answered as an internal error" 500 reply.status;
  check int "every byte arrived" (String.length expected)
    (String.length reply.body);
  check bool "the bytes are the ones written" true
    (String.equal expected reply.body)

let () =
  run "H2 response window"
    [ ( "flow control"
      , [ test_case "a response over the client's window arrives whole" `Quick
            test_response_over_the_window_arrives_whole
        ; test_case "an empty response still ends its stream" `Quick
            test_empty_response_still_ends_its_stream
        ; test_case "an error handler's body arrives whole" `Quick
            test_error_handler_body_arrives_whole
        ] )
    ]
