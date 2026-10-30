(* The response body flow cohttp-eio hands back must deliver the bytes the
   server sent, in order, whatever buffer sizes the reader asks with.

   masc reads every provider stream through [Cohttp_eio.Client.post] and an
   [Eio.Buf_read] over the body flow. Buf_read asks for whatever free space its
   buffer has at that moment, so one HTTP chunk is routinely handed over in
   several [single_read] calls. cohttp-eio 6.2.1's [Reader_flow.single_read]
   copies the second and later partial deliveries from offset 0 of the chunk
   instead of from the position it has already delivered up to: the chunk's
   first bytes appear again where the next bytes should have been, and those
   bytes are lost. On the wire this reads as an SSE frame with a span repeated
   right after itself ("system_fingerprint","system_fingerprint":...), which the
   JSON decoder rejects as sse/malformed_payload (masc#28761).

   This test drives the public client over a mock socket carrying one chunked
   response and reads the body with a buffer smaller than the chunk. It pins
   the contract masc depends on, not cohttp-eio's internals: whichever version
   is linked must pass it. *)

let response_with_one_chunk payload =
  Printf.sprintf
    "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n%x\r\n%s\r\n0\r\n\r\n"
    (String.length payload)
    payload
;;

(* Every 8 bytes name their own offset, so a misplaced copy names where it
   came from. *)
let payload_of_length n =
  let b = Buffer.create n in
  let i = ref 0 in
  while Buffer.length b < n do
    Buffer.add_string b (Printf.sprintf "%07d|" !i);
    incr i
  done;
  Buffer.sub b 0 n
;;

let read_body_with ~buffer_size body =
  let out = Buffer.create 4096 in
  let cs = Cstruct.create buffer_size in
  let rec loop () =
    match Eio.Flow.single_read body cs with
    | n ->
      Buffer.add_string out (Cstruct.to_string ~len:n cs);
      loop ()
    | exception End_of_file -> ()
  in
  loop ();
  Buffer.contents out
;;

let first_mismatch expected actual =
  let n = min (String.length expected) (String.length actual) in
  let rec go i = if i < n && expected.[i] = actual.[i] then go (i + 1) else i in
  go 0
;;

let body_through_client ~buffer_size payload =
  Eio_mock.Backend.run @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let socket = Eio_mock.Flow.make "socket" in
  Eio_mock.Flow.on_read socket [ `Return (response_with_one_chunk payload); `Raise End_of_file ];
  let client = Cohttp_eio.Client.make_generic (fun ~sw:_ _uri -> socket) in
  let _response, body = Cohttp_eio.Client.get ~sw client (Uri.of_string "http://mock/stream") in
  read_body_with ~buffer_size body
;;

let check_delivery ~chunk_length ~buffer_size () =
  let payload = payload_of_length chunk_length in
  let actual = body_through_client ~buffer_size payload in
  if not (String.equal actual payload)
  then (
    let at = first_mismatch payload actual in
    Alcotest.failf
      "body diverges from the chunk at byte %d (buffer %d, chunk %d): expected %S, got %S"
      at
      buffer_size
      chunk_length
      (String.sub payload at (min 32 (String.length payload - at)))
      (String.sub actual at (min 32 (String.length actual - at))))
;;

let test_chunk_delivered_in_one_read () = check_delivery ~chunk_length:3000 ~buffer_size:4096 ()

let test_chunk_delivered_across_two_reads () =
  check_delivery ~chunk_length:3000 ~buffer_size:2000 ()
;;

let test_chunk_delivered_across_many_reads () =
  check_delivery ~chunk_length:3000 ~buffer_size:100 ()
;;

let () =
  Alcotest.run
    "cohttp_eio_body_flow"
    [ ( "chunked body reaches the reader intact"
      , [ Alcotest.test_case "one read takes the whole chunk" `Quick test_chunk_delivered_in_one_read
        ; Alcotest.test_case "two reads split the chunk" `Quick test_chunk_delivered_across_two_reads
        ; Alcotest.test_case
            "thirty reads split the chunk"
            `Quick
            test_chunk_delivered_across_many_reads
        ] )
    ]
;;
