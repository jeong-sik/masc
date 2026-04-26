(** Unit tests for Http_protocol_detect.

    Uses Unix.socketpair to create connected FDs, writes protocol
    prefixes on one end, and verifies detection on the other. *)

open Masc_mcp

let test_detect_h2_preface () =
  let fd_r, fd_w = Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () ->
      Unix.close fd_r;
      Unix.close fd_w)
    (fun () ->
       (* Write the full HTTP/2 connection preface prefix *)
       let preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" in
       let _ = Unix.write_substring fd_w preface 0 (String.length preface) in
       match Http_protocol_detect.detect_from_fd fd_r with
       | Ok Http_protocol_detect.Http2 -> ()
       | Ok Http_protocol_detect.Http1 -> Alcotest.fail "expected Http2 but got Http1"
       | Error msg -> Alcotest.failf "expected Http2 but got Error: %s" msg)
;;

let test_detect_h1_get () =
  let fd_r, fd_w = Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () ->
      Unix.close fd_r;
      Unix.close fd_w)
    (fun () ->
       let req = "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n" in
       let _ = Unix.write_substring fd_w req 0 (String.length req) in
       match Http_protocol_detect.detect_from_fd fd_r with
       | Ok Http_protocol_detect.Http1 -> ()
       | Ok Http_protocol_detect.Http2 -> Alcotest.fail "expected Http1 but got Http2"
       | Error msg -> Alcotest.failf "expected Http1 but got Error: %s" msg)
;;

let test_detect_h1_post () =
  let fd_r, fd_w = Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () ->
      Unix.close fd_r;
      Unix.close fd_w)
    (fun () ->
       let req = "POST /mcp HTTP/1.1\r\nHost: localhost\r\n\r\n" in
       let _ = Unix.write_substring fd_w req 0 (String.length req) in
       match Http_protocol_detect.detect_from_fd fd_r with
       | Ok Http_protocol_detect.Http1 -> ()
       | Ok Http_protocol_detect.Http2 -> Alcotest.fail "expected Http1 but got Http2"
       | Error msg -> Alcotest.failf "expected Http1 but got Error: %s" msg)
;;

let test_detect_partial_read () =
  (* If less than 14 bytes arrive, detect should return Http1
     (partial data cannot be an H2 preface). *)
  let fd_r, fd_w = Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () ->
      Unix.close fd_r;
      Unix.close fd_w)
    (fun () ->
       let short = "GET /" in
       let _ = Unix.write_substring fd_w short 0 (String.length short) in
       (* Close writer so recv returns what's available *)
       Unix.shutdown fd_w Unix.SHUTDOWN_SEND;
       match Http_protocol_detect.detect_from_fd fd_r with
       | Ok Http_protocol_detect.Http1 -> ()
       | Ok Http_protocol_detect.Http2 ->
         Alcotest.fail "expected Http1 for partial data but got Http2"
       | Error _msg ->
         (* Error is also acceptable for partial data + closed connection *)
         ())
;;

let test_detect_closed_connection () =
  let fd_r, fd_w = Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  (* Close writer immediately -- reader sees EOF *)
  Unix.close fd_w;
  Fun.protect
    ~finally:(fun () -> Unix.close fd_r)
    (fun () ->
       match Http_protocol_detect.detect_from_fd fd_r with
       | Error _ -> ()
       | Ok Http_protocol_detect.Http1 ->
         (* recv returning 0 on closed fd maps to Http1 in some edge cases;
         not ideal but acceptable -- connection will fail at protocol level. *)
         ()
       | Ok Http_protocol_detect.Http2 ->
         Alcotest.fail "should not detect Http2 on closed connection")
;;

let test_peek_is_non_destructive () =
  (* After detect_from_fd, the data should still be readable from the socket
     because MSG_PEEK does not consume bytes. *)
  let fd_r, fd_w = Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () ->
      Unix.close fd_r;
      Unix.close fd_w)
    (fun () ->
       let req = "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n" in
       let _ = Unix.write_substring fd_w req 0 (String.length req) in
       (* Detect first *)
       (match Http_protocol_detect.detect_from_fd fd_r with
        | Ok Http_protocol_detect.Http1 -> ()
        | _ -> Alcotest.fail "expected Http1");
       (* Now read normally -- data should still be there *)
       let buf = Bytes.create 14 in
       let n = Unix.recv fd_r buf 0 14 [] in
       let read_str = Bytes.sub_string buf 0 n in
       Alcotest.(check string) "peek preserved data" "GET /health HT" read_str)
;;

let test_protocol_to_string () =
  Alcotest.(check string)
    "Http1 label"
    "HTTP/1.1"
    (Http_protocol_detect.protocol_to_string Http_protocol_detect.Http1);
  Alcotest.(check string)
    "Http2 label"
    "HTTP/2"
    (Http_protocol_detect.protocol_to_string Http_protocol_detect.Http2)
;;

let () =
  Alcotest.run
    "http_protocol_detect"
    [ ( "detection"
      , [ Alcotest.test_case "H2 preface" `Quick test_detect_h2_preface
        ; Alcotest.test_case "H1 GET" `Quick test_detect_h1_get
        ; Alcotest.test_case "H1 POST" `Quick test_detect_h1_post
        ; Alcotest.test_case "partial read" `Quick test_detect_partial_read
        ; Alcotest.test_case "closed connection" `Quick test_detect_closed_connection
        ; Alcotest.test_case "peek non-destructive" `Quick test_peek_is_non_destructive
        ; Alcotest.test_case "protocol_to_string" `Quick test_protocol_to_string
        ] )
    ]
;;
