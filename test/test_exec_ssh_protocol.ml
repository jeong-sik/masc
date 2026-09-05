open Alcotest

let contains needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec scan i = i + n <= h && (String.sub haystack i n = needle || scan (i + 1)) in
  scan 0

let req = Exec_ssh_protocol.{ v = Exec_ssh_protocol.protocol_version
                            ; argv = ["/bin/echo"; "hello"]
                            ; env = [("FOO", "bar")]
                            ; cwd = "/srv/masc/playground/keeper-a"
                            ; remote_root = "/srv/masc/playground"
                            ; timeout_sec = 300.0
                            ; stdin_len = 0L
                            ; mode = Exec_ssh_protocol.Effect }

let test_frame_roundtrip () =
  match Exec_ssh_protocol.encode_request req ~stdin:"" with
  | Error e -> fail e
  | Ok framed ->
    (match Exec_ssh_protocol.decode_request framed with
     | Error e -> fail e
     | Ok (req', stdin) ->
       check (list string) "argv" req.argv req'.argv;
       check (list (pair string string)) "env" req.env req'.env;
       check string "cwd" req.cwd req'.cwd;
       check (float 0.0) "timeout" req.timeout_sec req'.timeout_sec;
       check string "mode" (Exec_ssh_protocol.mode_to_string req.mode)
         (Exec_ssh_protocol.mode_to_string req'.mode);
       check string "stdin" "" stdin)

(* RFC-0422: the mode is a closed set on the wire. *)
let test_mode_roundtrip () =
  List.iter
    (fun mode ->
       match Exec_ssh_protocol.encode_request { req with mode } ~stdin:"" with
       | Error e -> fail e
       | Ok framed ->
         (match Exec_ssh_protocol.decode_request framed with
          | Error e -> fail e
          | Ok (r, _) ->
            check string (Exec_ssh_protocol.mode_to_string mode)
              (Exec_ssh_protocol.mode_to_string mode)
              (Exec_ssh_protocol.mode_to_string r.mode)))
    Exec_ssh_protocol.[ Effect; Observe; Guest_local ]

let test_mode_outside_the_set_is_a_transport_error () =
  match Exec_ssh_protocol.encode_request req ~stdin:"" with
  | Error e -> fail e
  | Ok framed ->
    (* Same frame, "effect" respelled to a word this build does not speak.
       The length prefix still matches because both spellings are 6 bytes. *)
    let hostile =
      let idx =
        let needle = "\"mode\":\"effect\"" in
        let n = String.length needle in
        let rec find i = if String.sub framed i n = needle then i else find (i + 1) in
        find 8 in
      String.sub framed 0 idx ^ "\"mode\":\"bogus!\""
      ^ String.sub framed (idx + String.length "\"mode\":\"effect\"")
          (String.length framed - idx - String.length "\"mode\":\"effect\"") in
    (match Exec_ssh_protocol.decode_request hostile with
     | Ok _ -> fail "an unknown mode decoded"
     | Error msg ->
       check bool "named transport error" true
         (contains "remote_ssh_transport_error" msg && contains "mode" msg))

let test_mode_strings_are_closed () =
  check (option string) "effect" (Some "effect")
    (Option.map Exec_ssh_protocol.mode_to_string (Exec_ssh_protocol.mode_of_string "effect"));
  check (option string) "observe" (Some "observe")
    (Option.map Exec_ssh_protocol.mode_to_string (Exec_ssh_protocol.mode_of_string "observe"));
  check (option string) "guest_local" (Some "guest_local")
    (Option.map Exec_ssh_protocol.mode_to_string (Exec_ssh_protocol.mode_of_string "guest_local"));
  check bool "anything else is None" true
    (Option.is_none (Exec_ssh_protocol.mode_of_string "Observe")
     && Option.is_none (Exec_ssh_protocol.mode_of_string ""))

let test_hostile_bytes_roundtrip () =
  (* invalid UTF-8 in argv; NULs, 0x1e and 0xff inside a 10 MiB stdin payload *)
  let big = Bytes.make (10 * 1024 * 1024) '\x00' in
  Bytes.blit_string "\x1e record sep \x1e \x00 \xff" 0 big 42 18;
  let stdin = Bytes.unsafe_to_string big in
  let r = { req with argv = ["\xff\xfe invalid utf8"]
                   ; stdin_len = Int64.of_int (String.length stdin) } in
  let framed = Exec_ssh_protocol.encode_request r ~stdin in
  match framed with
  | Error e -> fail e
  | Ok framed ->
    (match Exec_ssh_protocol.decode_request framed with
     | Error e -> fail e
     | Ok (r', stdin') ->
       check (list string) "hostile argv" r.argv r'.argv;
       check string "stdin bytes" stdin stdin')

let test_frame_version_gated () =
  (* A version this build does not speak is a named version error, never a
     silent parse. Derived from the current one so a later bump cannot turn
     this case into the accepted version. *)
  match
    Exec_ssh_protocol.encode_request
      { req with v = Exec_ssh_protocol.protocol_version + 1 }
      ~stdin:""
  with
  | Error e -> fail e
  | Ok framed ->
    (match Exec_ssh_protocol.decode_request framed with
     | Ok _ -> fail "expected version error"
     | Error msg ->
       check bool "version error prefix" true
         (contains "remote_ssh_version_error" msg))

let test_frame_stdin_len_mismatch_is_transport_error () =
  (* declare 5, send 3; hand-built because encode_request rejects the
     inconsistency at the source *)
  let json =
    Printf.sprintf
      {|{"v":%d,"argv":[],"env":[],"cwd":"","remote_root":"","timeout_sec":1.0,"stdin_len":5,"mode":"effect"}|}
      Exec_ssh_protocol.protocol_version
  in
  let stdin = "abc" in
  let n = String.length json + String.length stdin in
  let frame = Bytes.create (8 + n) in
  for i = 0 to 7 do
    Bytes.set frame i (Char.chr ((n lsr (8 * (7 - i))) land 0xff))
  done;
  Bytes.blit_string json 0 frame 8 (String.length json);
  Bytes.blit_string stdin 0 frame (8 + String.length json) (String.length stdin);
  match Exec_ssh_protocol.decode_request (Bytes.unsafe_to_string frame) with
  | Ok _ -> fail "expected transport error"
  | Error msg ->
    check bool "stdin_len mismatch" true (contains "stdin_len mismatch" msg)

let test_trailer_roundtrip () =
  let t = Exec_ssh_protocol.{ v = Exec_ssh_protocol.protocol_version; exit = Some 3; signal = None
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
      Exec_ssh_protocol.{ v = Exec_ssh_protocol.protocol_version; exit = Some 7; signal = None
                        ; timed_out = false; shim_error = None } in
  let tail = "payload says \x1e{not the result}\x1e then more stderr " ^ real in
  match Exec_ssh_protocol.parse_trailer tail with
  | Error e -> fail e
  | Ok t' -> check (option int) "last trailer wins" (Some 7) t'.exit

let test_trailer_version_gated () =
  (* A version this build does not speak, in a trailer: same error as the
     frame. *)
  let t = Exec_ssh_protocol.{ v = Exec_ssh_protocol.protocol_version + 1
                            ; exit = Some 0; signal = None
                            ; timed_out = false; shim_error = None } in
  match Exec_ssh_protocol.parse_trailer (Exec_ssh_protocol.render_trailer t) with
  | Ok _ -> fail "expected version error"
  | Error msg ->
    check bool "version error prefix" true
      (contains "remote_ssh_version_error" msg)

let test_exit_zero_is_a_real_exit () =
  (* exit 0 round-trips as data: the codec never fabricates or
     special-cases it *)
  let t = Exec_ssh_protocol.{ v = Exec_ssh_protocol.protocol_version; exit = Some 0; signal = None
                            ; timed_out = false; shim_error = None } in
  match Exec_ssh_protocol.parse_trailer (Exec_ssh_protocol.render_trailer t) with
  | Error e -> fail e
  | Ok t' -> check (option int) "exit 0 survives" (Some 0) t'.exit

let test_trailer_exclusivity_violation_is_transport_error () =
  (* exit and signal both set is malformed, not ambiguously "exit 1" *)
  let t = Exec_ssh_protocol.{ v = Exec_ssh_protocol.protocol_version; exit = Some 1; signal = Some 9
                            ; timed_out = false; shim_error = None } in
  match Exec_ssh_protocol.parse_trailer (Exec_ssh_protocol.render_trailer t) with
  | Ok _ -> fail "expected transport error"
  | Error msg ->
    check bool "mutually exclusive" true (contains "mutually exclusive" msg)

let test_signal_vs_exit () =
  let t = Exec_ssh_protocol.{ v = Exec_ssh_protocol.protocol_version; exit = None; signal = Some 9
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
               ; test_case "hostile bytes" `Quick test_hostile_bytes_roundtrip
               ; test_case "version gated" `Quick test_frame_version_gated
               ; test_case "mode roundtrip" `Quick test_mode_roundtrip
               ; test_case "mode outside the set is transport error" `Quick
                   test_mode_outside_the_set_is_a_transport_error
               ; test_case "mode strings are closed" `Quick test_mode_strings_are_closed
               ; test_case "stdin_len mismatch is transport error" `Quick
                   test_frame_stdin_len_mismatch_is_transport_error ]
    ; "trailer", [ test_case "roundtrip" `Quick test_trailer_roundtrip
                 ; test_case "malformed is transport error" `Quick test_trailer_malformed_is_transport_error
                 ; test_case "absent is transport error" `Quick test_trailer_absent_is_transport_error
                 ; test_case "last match wins" `Quick test_trailer_last_match_wins
                 ; test_case "version gated" `Quick test_trailer_version_gated
                 ; test_case "exit 0 is a real exit" `Quick test_exit_zero_is_a_real_exit
                 ; test_case "exclusivity violation is transport error" `Quick
                     test_trailer_exclusivity_violation_is_transport_error
                 ; test_case "signal vs exit" `Quick test_signal_vs_exit ]
    ; "probe", [ test_case "roundtrip" `Quick test_probe_roundtrip
               ; test_case "version skew" `Quick test_probe_version_skew ] ]
