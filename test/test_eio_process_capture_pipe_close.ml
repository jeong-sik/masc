(* A piped command whose reader closes early ([head -20]) ends a write with
   EPIPE. [is_downstream_pipe_closed] tells that normal ending apart from a real
   failure by the exception's constructor, never by its text. *)

let unix_epipe = Unix.Unix_error (Unix.EPIPE, "writev", "")

let eio_connection_reset_epipe =
  Eio.Net.err
    (Eio.Net.Connection_reset (Eio_unix.Unix_error (Unix.EPIPE, "writev", "")))
;;

let eio_backend_epipe =
  Eio.Exn.create (Eio.Exn.X (Eio_unix.Unix_error (Unix.EPIPE, "writev", "")))
;;

let eio_connection_failure =
  Eio.Net.err (Eio.Net.Connection_failure Eio.Net.No_matching_addresses)
;;

let closed exn = Eio_process_capture.is_downstream_pipe_closed exn

let () =
  Alcotest.run
    "eio_process_capture_pipe_close"
    [ ( "downstream pipe closed"
      , [ Alcotest.test_case "Unix EPIPE" `Quick (fun () ->
            Alcotest.(check bool) "closed" true (closed unix_epipe))
        ; Alcotest.test_case "Eio Connection_reset carrying EPIPE" `Quick (fun () ->
            Alcotest.(check bool) "closed" true (closed eio_connection_reset_epipe))
        ; Alcotest.test_case "Eio backend error carrying EPIPE" `Quick (fun () ->
            Alcotest.(check bool) "closed" true (closed eio_backend_epipe))
        ] )
    ; ( "not a closed pipe"
      , [ Alcotest.test_case "a connection failure is a real failure" `Quick (fun () ->
            Alcotest.(check bool) "closed" false (closed eio_connection_failure))
        ; Alcotest.test_case "the exception text is never read" `Quick (fun () ->
            Alcotest.(check bool) "Sys_error" false (closed (Sys_error "Broken pipe"));
            Alcotest.(check bool) "Failure" false (closed (Failure "Broken pipe")))
        ] )
    ]
;;
