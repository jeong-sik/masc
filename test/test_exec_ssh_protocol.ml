open Alcotest

let contains needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec scan i = i + n <= h && (String.sub haystack i n = needle || scan (i + 1)) in
  scan 0

let req = Exec_ssh_protocol.{ v = 1
                            ; argv = ["/bin/echo"; "hello"]
                            ; env = [("FOO", "bar")]
                            ; cwd = "/srv/masc/playground/keeper-a"
                            ; timeout_sec = 300.0
                            ; stdin_len = 0L }

let test_frame_roundtrip () =
  let framed = Exec_ssh_protocol.encode_request req ~stdin:"" in
  match Exec_ssh_protocol.decode_request framed with
  | Error e -> fail e
  | Ok (req', stdin) ->
    check (list string) "argv" req.argv req'.argv;
    check (list (pair string string)) "env" req.env req'.env;
    check string "cwd" req.cwd req'.cwd;
    check (float 0.0) "timeout" req.timeout_sec req'.timeout_sec;
    check string "stdin" "" stdin

let test_hostile_bytes_roundtrip () =
  (* invalid UTF-8 in argv; NULs, 0x1e and 0xff inside a 10 MiB stdin payload *)
  let big = Bytes.make (10 * 1024 * 1024) '\x00' in
  Bytes.blit_string "\x1e record sep \x1e \x00 \xff" 0 big 42 18;
  let stdin = Bytes.unsafe_to_string big in
  let r = { req with argv = ["\xff\xfe invalid utf8"]
                   ; stdin_len = Int64.of_int (String.length stdin) } in
  let framed = Exec_ssh_protocol.encode_request r ~stdin in
  match Exec_ssh_protocol.decode_request framed with
  | Error e -> fail e
  | Ok (r', stdin') ->
    check (list string) "hostile argv" r.argv r'.argv;
    check string "stdin bytes" stdin stdin'

let test_trailer_roundtrip () =
  let t = Exec_ssh_protocol.{ v = 1; exit = Some 3; signal = None
                            ; timed_out = false; shim_error = None } in
  let rendered = Exec_ssh_protocol.render_trailer t in
  check bool "starts with RS" true (String.length rendered > 2 && rendered.[0] = '\x1e');
  check bool "ends with RS" true
    (String.length rendered > 2 && rendered.[String.length rendered - 1] = '\x1e');
  match Exec_ssh_protocol.parse_trailer rendered with
  | Error e -> fail e
  | Ok t' -> check (option int) "exit" t.exit t'.exit

let test_trailer_malformed_is_transport_error () =
  match Exec_ssh_protocol.parse_trailer "\x1e not json \x1e" with
  | Ok _ -> fail "expected transport error"
  | Error msg -> check bool "transport, not exit0" true (contains "transport" msg)

let test_trailer_absent_is_transport_error () =
  match Exec_ssh_protocol.parse_trailer "plain stderr with no trailer" with
  | Ok _ -> fail "expected transport error"
  | Error _ -> ()

let test_trailer_last_match_wins () =
  (* the stderr tail may legitimately contain earlier \x1e-delimited junk
     emitted by the payload; the LAST well-formed \x1e...\x1e pair is the
     trailer, an earlier malformed pair must not poison it *)
  let real = Exec_ssh_protocol.render_trailer
      Exec_ssh_protocol.{ v = 1; exit = Some 7; signal = None
                        ; timed_out = false; shim_error = None } in
  let tail = "payload says \x1e{not the result}\x1e then more stderr " ^ real in
  match Exec_ssh_protocol.parse_trailer tail with
  | Error e -> fail e
  | Ok t' -> check (option int) "last trailer wins" (Some 7) t'.exit

let test_signal_vs_exit () =
  let t = Exec_ssh_protocol.{ v = 1; exit = None; signal = Some 9
                            ; timed_out = false; shim_error = None } in
  match Exec_ssh_protocol.parse_trailer (Exec_ssh_protocol.render_trailer t) with
  | Error e -> fail e
  | Ok t' -> check (option int) "signal" (Some 9) t'.signal

let test_probe_roundtrip () =
  let p = Exec_ssh_protocol.{ name = "masc-exec-shim"; version = "1.0.0"
                            ; capabilities = [] } in
  match Exec_ssh_protocol.parse_probe (Exec_ssh_protocol.render_probe p) with
  | Error e -> fail e
  | Ok p' ->
    check string "version" p.version p'.version;
    check bool "major compatible" true
      (Exec_ssh_protocol.probe_major_compatible ~want:"1" p'.version)

let test_probe_version_skew () =
  check bool "major mismatch" false
    (Exec_ssh_protocol.probe_major_compatible ~want:"2" "1.4.2")

let () =
  run "exec ssh protocol"
    [ "frame", [ test_case "roundtrip" `Quick test_frame_roundtrip
               ; test_case "hostile bytes" `Quick test_hostile_bytes_roundtrip ]
    ; "trailer", [ test_case "roundtrip" `Quick test_trailer_roundtrip
                 ; test_case "malformed is transport error" `Quick test_trailer_malformed_is_transport_error
                 ; test_case "absent is transport error" `Quick test_trailer_absent_is_transport_error
                 ; test_case "last match wins" `Quick test_trailer_last_match_wins
                 ; test_case "signal vs exit" `Quick test_signal_vs_exit ]
    ; "probe", [ test_case "roundtrip" `Quick test_probe_roundtrip
               ; test_case "version skew" `Quick test_probe_version_skew ] ]
