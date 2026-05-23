(** Unit tests for Http_protocol_detect.

    The original suite used [Unix.socketpair] + the now-internal
    [Http_protocol_detect.detect_from_fd] (POSIX file_descr entry).
    The public surface is now the Eio adapter [detect :
    _ Eio.Net.stream_socket -> (protocol, string) result] — the
    POSIX-FD entry and [protocol_to_string] formatter were both hidden
    during the dead-export sweep because the only production caller
    goes through Eio.

    Re-implementing the six Unix-FD detection cases (H2 preface /
    H1 GET / H1 POST / partial read / closed connection / peek
    non-destructive) against an Eio socket harness is tracked
    separately; this file is intentionally a stub stanza for now so
    the test runner registration in test/dune does not bit-rot. *)

open Masc_mcp

let test_protocol_type_sanity () =
  (* Cheapest possible compile-time anchor that keeps the module name
     referenced and exercises the public [type protocol] surface. *)
  let _ : Http_protocol_detect.protocol = Http_protocol_detect.Http1 in
  let _ : Http_protocol_detect.protocol = Http_protocol_detect.Http2 in
  Alcotest.(check pass) "protocol variant constructible" () ()

let () =
  Alcotest.run "http_protocol_detect"
    [
      ( "labels",
        [
          Alcotest.test_case "protocol type sanity" `Quick
            test_protocol_type_sanity;
        ] );
    ]
