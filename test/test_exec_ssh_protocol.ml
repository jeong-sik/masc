open Alcotest

let contains needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec scan i = i + n <= h && (String.sub haystack i n = needle || scan (i + 1)) in
  scan 0

let req = Exec_ssh_protocol.{ v = Exec_ssh_protocol.newest
                            ; argv = ["/bin/echo"; "hello"]
                            ; env = [("FOO", "bar")]
                            ; cwd = "/srv/masc/playground/keeper-a"
                            ; remote_root = "/srv/masc/playground"
                            ; timeout_sec = 300.0
                            ; stdin = Framed 0L
                            ; mode = Exec_ssh_protocol.Effect
                            ; acceptance_frame = false }

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

(* The mode is a closed set on the wire. *)
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
                   ; stdin = Framed (Int64.of_int (String.length stdin)) } in
  let framed = Exec_ssh_protocol.encode_request r ~stdin in
  match framed with
  | Error e -> fail e
  | Ok framed ->
    (match Exec_ssh_protocol.decode_request framed with
     | Error e -> fail e
     | Ok (r', stdin') ->
       check (list string) "hostile argv" r.argv r'.argv;
       check bool "the framed byte count survives" true (r'.stdin = r.stdin);
       check string "stdin bytes" stdin stdin')

let test_frame_version_gated () =
  (* A version this build does not speak cannot be framed -- [major] has no
     constructor for it -- and a frame that arrives carrying it is refused
     by name, never silently parsed. Derived from the current one so a
     later bump cannot turn this case into an accepted version. *)
  let json =
    Printf.sprintf
      {|{"v":%d,"argv":[],"env":[],"cwd":"","remote_root":"","timeout_sec":1.0,"stdin_len":0,"mode":"effect"}|}
      (Exec_ssh_protocol.protocol_version + 1)
  in
  let framed =
    let b = Bytes.create (8 + String.length json) in
    Bytes.set_int64_be b 0 (Int64.of_int (String.length json));
    Bytes.blit_string json 0 b 8 (String.length json);
    Bytes.to_string b
  in
  match Exec_ssh_protocol.decode_request framed with
  | Ok _ -> fail "expected version error"
  | Error msg ->
    check bool "decoder names the version error" true
      (contains "remote_ssh_version_error" msg)

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
  let t = Exec_ssh_protocol.{ v = Exec_ssh_protocol.newest; exit = Some 3; signal = None
                            ; timed_out = false; shim_error = None; observed_syscalls = [] } in
  let rendered = Exec_ssh_protocol.render_trailer t in
  check bool "starts with RS" true (String.length rendered > 2 && rendered.[0] = '\x1e');
  check bool "ends with RS" true
    (String.length rendered > 2 && rendered.[String.length rendered - 1] = '\x1e');
  match Exec_ssh_protocol.parse_trailer rendered with
  | Error e -> fail e
  | Ok t' -> check (option int) "exit" t.exit t'.exit

(* task-1575 item 4: the observed-syscalls evidence rides in the trailer's
   own typed field, distinct from exit/signal/shim_error, and survives a
   render/parse round trip -- not just a construction-site smoke test. *)
let test_trailer_observed_syscalls_roundtrip () =
  let t = Exec_ssh_protocol.{ v = Exec_ssh_protocol.newest; exit = Some 0; signal = None
                            ; timed_out = false; shim_error = None
                            ; observed_syscalls = [ 41; 41 ] } in
  match Exec_ssh_protocol.parse_trailer (Exec_ssh_protocol.render_trailer t) with
  | Error e -> fail e
  | Ok t' -> check (list int) "observed_syscalls" [ 41; 41 ] t'.observed_syscalls

(* A trailer from an older peer that never heard of this field must decode
   to [[]], not fail to parse: the field is additive on the wire. *)
let test_trailer_missing_observed_syscalls_is_empty () =
  let wire =
    Printf.sprintf "\x1e%s\x1e"
      (Yojson.Safe.to_string
         (`Assoc
            [ "masc_exec_result",
              `Assoc
                [ "v", `Int (Exec_ssh_protocol.int_of_major Exec_ssh_protocol.newest)
                ; "exit", `Int 0
                ; "signal", `Null
                ; "timed_out", `Bool false
                ; "shim_error", `Null
                ]
            ]))
  in
  match Exec_ssh_protocol.parse_trailer wire with
  | Error e -> fail e
  | Ok t -> check (list int) "no observed_syscalls key decodes to []" [] t.observed_syscalls

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
      Exec_ssh_protocol.{ v = Exec_ssh_protocol.newest; exit = Some 7; signal = None
                        ; timed_out = false; shim_error = None; observed_syscalls = [] } in
  let tail = "payload says \x1e{not the result}\x1e then more stderr " ^ real in
  match Exec_ssh_protocol.parse_trailer tail with
  | Error e -> fail e
  | Ok t' -> check (option int) "last trailer wins" (Some 7) t'.exit

let test_trailer_version_gated () =
  (* A version this build does not speak, in a trailer: same error as the
     frame. *)
  let text =
    Printf.sprintf
      "\x1e{\"masc_exec_result\":{\"v\":%d,\"exit\":0,\"signal\":null,\"timed_out\":false,\"shim_error\":null}}\x1e"
      (Exec_ssh_protocol.protocol_version + 1)
  in
  match Exec_ssh_protocol.parse_trailer text with
  | Ok _ -> fail "expected version error"
  | Error msg ->
    check bool "version error prefix" true
      (contains "remote_ssh_version_error" msg)

let test_exit_zero_is_a_real_exit () =
  (* exit 0 round-trips as data: the codec never fabricates or
     special-cases it *)
  let t = Exec_ssh_protocol.{ v = Exec_ssh_protocol.newest; exit = Some 0; signal = None
                            ; timed_out = false; shim_error = None; observed_syscalls = [] } in
  match Exec_ssh_protocol.parse_trailer (Exec_ssh_protocol.render_trailer t) with
  | Error e -> fail e
  | Ok t' -> check (option int) "exit 0 survives" (Some 0) t'.exit

let test_trailer_exclusivity_violation_is_transport_error () =
  (* exit and signal both set is malformed, not ambiguously "exit 1" *)
  let t = Exec_ssh_protocol.{ v = Exec_ssh_protocol.newest; exit = Some 1; signal = Some 9
                            ; timed_out = false; shim_error = None; observed_syscalls = [] } in
  match Exec_ssh_protocol.parse_trailer (Exec_ssh_protocol.render_trailer t) with
  | Ok _ -> fail "expected transport error"
  | Error msg ->
    check bool "mutually exclusive" true (contains "mutually exclusive" msg)

let test_signal_vs_exit () =
  let t = Exec_ssh_protocol.{ v = Exec_ssh_protocol.newest; exit = None; signal = Some 9
                            ; timed_out = false; shim_error = None; observed_syscalls = [] } in
  match Exec_ssh_protocol.parse_trailer (Exec_ssh_protocol.render_trailer t) with
  | Error e -> fail e
  | Ok t' -> check (option int) "signal" (Some 9) t'.signal

(* ── two majors on one wire ──────────────────────────────────────────── *)

let json_of_frame framed =
  (* The JSON sits after the 8-byte length prefix; the fixtures carry no
     stdin, so the rest of the frame is the JSON. *)
  Yojson.Safe.from_string (String.sub framed 8 (String.length framed - 8))

let frame_with_request_json json ~stdin =
  let body = json ^ stdin in
  let frame = Bytes.create (8 + String.length body) in
  Bytes.set_int64_be frame 0 (Int64.of_int (String.length body));
  Bytes.blit_string body 0 frame 8 (String.length body);
  Bytes.to_string frame

let test_interactive_header_keeps_live_bytes_outside_the_frame () =
  List.iter (fun mode ->
    let request = { req with stdin = Exec_ssh_protocol.Interactive; mode } in
    match Exec_ssh_protocol.encode_request request ~stdin:"" with
    | Error message -> fail message
    | Ok frame ->
      (match json_of_frame frame with
       | `Assoc fields ->
         check bool "streaming is explicit" true
           (List.assoc_opt "stdin_stream" fields = Some (`Bool true));
         (* A framed-only peer requires stdin_len. Omitting it makes a stale
            capability observation a refusal, rather than an empty-stdin run. *)
         check bool "no framed length a peer could mistake for empty input" false
           (List.mem_assoc "stdin_len" fields)
       | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
         fail "the request header is not an object");
      check int64 "the prefix covers only the complete JSON header"
        (Int64.of_int (String.length frame - 8))
        (Bytes.get_int64_be (Bytes.of_string frame) 0);
      (match Exec_ssh_protocol.decode_request frame with
       | Error message -> fail message
       | Ok (decoded, initial) ->
         check bool "interactive mode survives" true
           (decoded.stdin = Exec_ssh_protocol.Interactive);
         check bool "execution mode survives" true (decoded.mode = mode);
         check string "the initial frame contains no child input" "" initial);
      match Exec_ssh_protocol.decode_request (frame ^ "\x00\xffsecond input") with
      | Ok _ -> fail "whole-frame decoding consumed live channel bytes"
      | Error message -> check bool "trailing bytes are a transport error" true
          (contains "remote_ssh_transport_error" message))
    Exec_ssh_protocol.[ Effect; Observe; Guest_local ]

let test_framed_headers_keep_their_length_field () =
  List.iter (fun v ->
    match Exec_ssh_protocol.encode_request { req with v } ~stdin:"" with
    | Error message -> fail message
    | Ok frame ->
      (match json_of_frame frame with
       | `Assoc fields ->
         check bool "framed zero length remains explicit" true
           (List.assoc_opt "stdin_len" fields = Some (`Int 0));
         check bool "framed input carries no streaming marker" false
           (List.mem_assoc "stdin_stream" fields)
       | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
         fail "the request header is not an object");
      match Exec_ssh_protocol.decode_request frame with
      | Error message -> fail message
      | Ok (decoded, initial) ->
        check bool "empty framed input stays framed" true
          (decoded.stdin = Exec_ssh_protocol.Framed 0L);
        check string "empty framed payload" "" initial)
    Exec_ssh_protocol.[ V2; V3 ]

let interactive_request_json input_fields =
  {|{"v":3,"argv":[],"env":[],"cwd":"","remote_root":"","timeout_sec":1.0,"mode":"effect",|}
  ^ input_fields ^ "}"

let test_interactive_initial_payload_is_refused () =
  let payload = "\x00\xff\x1einitial input" in
  (match Exec_ssh_protocol.encode_request
      { req with stdin = Exec_ssh_protocol.Interactive } ~stdin:payload with
   | Ok _ -> fail "interactive encoding accepted a framed initial payload"
   | Error message -> check bool "encoding refuses the ambiguous payload" true
       (contains "remote_ssh_transport_error" message));
  let frame = frame_with_request_json
      (interactive_request_json {|"stdin_stream":true|}) ~stdin:payload in
  match Exec_ssh_protocol.decode_request frame with
  | Ok _ -> fail "interactive decoding accepted bytes inside the initial frame"
  | Error message -> check bool "decoding refuses the ambiguous payload" true
      (contains "remote_ssh_transport_error" message)

let test_input_headers_are_unambiguous () =
  List.iter (fun (label, fields) ->
    let frame = frame_with_request_json (interactive_request_json fields) ~stdin:"" in
    match Exec_ssh_protocol.decode_request frame with
    | Ok _ -> failf "%s was accepted as child input" label
    | Error message -> check bool (label ^ " is a transport error") true
        (contains "remote_ssh_transport_error" message))
    [ "framed and interactive", {|"stdin_len":0,"stdin_stream":true|}
    ; "interactive and framed", {|"stdin_stream":true,"stdin_len":0|}
    ; "duplicate stream marker", {|"stdin_stream":true,"stdin_stream":true|}
    ; "contradictory stream markers", {|"stdin_stream":true,"stdin_stream":false|}
    ; "duplicate framed length", {|"stdin_len":0,"stdin_len":0|}
    ; "false stream marker", {|"stdin_stream":false|}
    ; "null stream marker", {|"stdin_stream":null|}
    ; "string stream marker", {|"stdin_stream":"true"|}
    ; "numeric stream marker", {|"stdin_stream":1|}
    ; "no input representation", {|"unrelated":0|}
    ]

let test_v2_refuses_interactive_input () =
  (match Exec_ssh_protocol.encode_request
      { req with v = Exec_ssh_protocol.V2; stdin = Interactive } ~stdin:"" with
   | Ok _ -> fail "a V2 peer was sent interactive input"
   | Error message -> check bool "encoding names version skew" true
       (contains "remote_ssh_version_error" message));
  let json =
    {|{"v":2,"argv":[],"env":[],"cwd":"","remote_root":"","timeout_sec":1.0,"stdin_stream":true}|} in
  match Exec_ssh_protocol.decode_request (frame_with_request_json json ~stdin:"") with
  | Ok _ -> fail "a V2 header granted interactive input"
  | Error message -> check bool "decoding names version skew" true
      (contains "remote_ssh_version_error" message)

let test_interactive_input_requires_a_capable_v3_probe () =
  List.iter (fun (label, version, capabilities, expected) ->
    let wire = Yojson.Safe.to_string (`Assoc
        [ "name", `String "masc-exec-shim"
        ; "version", `String version
        ; "capabilities", `List (List.map (fun value -> `String value) capabilities)
        ]) in
    match Exec_ssh_protocol.parse_probe wire with
    | Error message -> fail message
    | Ok probe -> check bool label expected
        (Exec_ssh_protocol.supports_interactive_stdin probe))
    [ "V3 without the capability", "3.0.0", [], false
    ; "V3 with another capability", "3.0.0", ["interactive_stdin_extra"], false
    ; "capable V3", "3.0.0", [Exec_ssh_protocol.interactive_stdin_capability], true
    ; "capable stamped V3", "3.0.0+fixture", [Exec_ssh_protocol.interactive_stdin_capability], true
    ; "V2 cannot grant streaming", "2.4.1", [Exec_ssh_protocol.interactive_stdin_capability], false
    ; "unknown major cannot grant streaming", "4.0.0", [Exec_ssh_protocol.interactive_stdin_capability], false
    ; "unreadable major cannot grant streaming", "bad", [Exec_ssh_protocol.interactive_stdin_capability], false
    ]

(* A v2 frame is a v3 frame without [mode], and it means Effect: the shim
   one release behind reads it, and this build reads what such a shim's
   server sends. *)
let test_a_v2_frame_has_no_mode_and_means_effect () =
  match Exec_ssh_protocol.encode_request { req with v = Exec_ssh_protocol.V2 } ~stdin:"" with
  | Error e -> fail e
  | Ok framed ->
    check bool "no mode field on the wire" true
      (match json_of_frame framed with
       | `Assoc fields -> not (List.mem_assoc "mode" fields)
       | _ -> false);
    (match Exec_ssh_protocol.decode_request framed with
     | Error e -> fail e
     | Ok (r, _) ->
       check int "v" 2 (Exec_ssh_protocol.int_of_major r.v);
       check string "mode" "effect" (Exec_ssh_protocol.mode_to_string r.mode))

let test_a_v2_frame_cannot_carry_a_box () =
  (match Exec_ssh_protocol.encode_request { req with v = Exec_ssh_protocol.V2; mode = Observe } ~stdin:"" with
   | Ok _ -> fail "a v2 frame asked for a box"
   | Error msg -> check bool "named version error" true (contains "remote_ssh_version_error" msg));
  (* And the other direction: a frame claiming v2 while carrying a mode
     comes from a build that does not know what v2 is. *)
  let json =
    Printf.sprintf
      {|{"v":2,"argv":[],"env":[],"cwd":"","remote_root":"","timeout_sec":1.0,"stdin_len":0,"mode":"observe"}|}
  in
  let framed =
    let b = Bytes.create (8 + String.length json) in
    Bytes.set_int64_be b 0 (Int64.of_int (String.length json));
    Bytes.blit_string json 0 b 8 (String.length json);
    Bytes.to_string b
  in
  match Exec_ssh_protocol.decode_request framed with
  | Ok _ -> fail "v2 with a mode decoded"
  | Error msg -> check bool "named version error" true (contains "remote_ssh_version_error" msg)

let test_a_v2_trailer_is_read () =
  let t = Exec_ssh_protocol.{ v = V2; exit = Some 3; signal = None; timed_out = false; shim_error = None; observed_syscalls = [] } in
  match Exec_ssh_protocol.parse_trailer ("noise" ^ Exec_ssh_protocol.render_trailer t) with
  | Error e -> fail e
  | Ok t' ->
    check int "v" 2 (Exec_ssh_protocol.int_of_major t'.v);
    check (option int) "exit" (Some 3) t'.exit

let test_the_majors_are_closed () =
  check (list int) "exactly two" [ 2; 3 ]
    (List.map Exec_ssh_protocol.int_of_major Exec_ssh_protocol.majors);
  check int "the newest is 3" 3 Exec_ssh_protocol.protocol_version;
  check bool "the newest is spoken" true
    (Exec_ssh_protocol.major_of_int Exec_ssh_protocol.protocol_version
     = Some Exec_ssh_protocol.newest);
  check bool "one past the newest is not" true
    (Exec_ssh_protocol.major_of_int (Exec_ssh_protocol.protocol_version + 1) = None)

let major_int p = Result.map Exec_ssh_protocol.int_of_major (Exec_ssh_protocol.major_of_probe p)

let test_probe_roundtrip () =
  let p = Exec_ssh_protocol.{ name = "masc-exec-shim"; version = "3.0.0"
                            ; capabilities = []; release = None; boot_id = None } in
  match Exec_ssh_protocol.parse_probe (Exec_ssh_protocol.render_probe p) with
  | Error e -> fail e
  | Ok p' ->
    check string "version" p.version p'.version;
    check (result int string) "major read" (Ok 3) (major_int p')

(* The shim names the release it was built from, beside the
   protocol version and without touching it. A shim built before the field
   existed sends no key, which reads as None rather than as a broken probe:
   the two sides are one release apart on purpose and have to keep talking. *)
let test_probe_carries_the_release_it_was_built_from () =
  let with_release =
    Exec_ssh_protocol.
      { name = "masc-exec-shim"
      ; version = "3.0.0"
      ; capabilities = [ "observe" ]
      ; release = Some "0.33.0"
      ; boot_id = None
      }
  in
  (match Exec_ssh_protocol.parse_probe (Exec_ssh_protocol.render_probe with_release) with
   | Error e -> fail e
   | Ok p ->
     check (option string) "release survives" (Some "0.33.0") p.release;
     check (result int string) "major untouched" (Ok 3) (major_int p));
  (* The wire of a shim that predates the field. *)
  (match
     Exec_ssh_protocol.parse_probe
       {|{"name":"masc-exec-shim","version":"3.0.0","capabilities":[]}|}
   with
   | Error e -> fail e
   | Ok p ->
     check (option string) "absent key reads as none" None p.release;
     check (result int string) "still framed" (Ok 3) (major_int p));
  (* A key this build does not know is ignored, which is what lets a later
     shim add one without refusing this server. *)
  (match
     Exec_ssh_protocol.parse_probe
       {|{"name":"masc-exec-shim","version":"3.0.0","capabilities":[],"kernel":"6.8"}|}
   with
   | Error e -> fail e
   | Ok p -> check (option string) "unknown key ignored" None p.release);
  (* An empty release is not a release. *)
  match
    Exec_ssh_protocol.parse_probe
      {|{"name":"masc-exec-shim","version":"3.0.0","capabilities":[],"release":""}|}
  with
  | Error e -> fail e
  | Ok p -> check (option string) "empty is none" None p.release

(* The probe decides which version the caller frames in: a spoken major is
   that version, anything else is a skew the caller names. *)
let test_probe_boot_id_is_optional_and_validated () =
  let boot_id = "70d55243-7a2b-47bc-95b3-c133f134854e" in
  let probe = Exec_ssh_protocol.{ name = "masc-exec-shim"; version = "3.0.0";
    capabilities = []; release = None; boot_id = Some boot_id } in
  (match Exec_ssh_protocol.parse_probe (Exec_ssh_protocol.render_probe probe) with
   | Ok parsed -> check (option string) "boot survives" (Some boot_id) parsed.boot_id
   | Error detail -> fail detail);
  List.iter (fun wire ->
    match Exec_ssh_protocol.parse_probe wire with
    | Ok parsed -> check (option string) "missing or invalid boot is unknown" None parsed.boot_id
    | Error detail -> fail detail)
    [ {|{"name":"masc-exec-shim","version":"3.0.0","capabilities":[]}|};
      {|{"name":"masc-exec-shim","version":"3.0.0","capabilities":[],"boot_id":"bad"}|} ]

let test_probe_major_is_spoken_or_a_skew () =
  let probe version =
    Exec_ssh_protocol.{ name = "masc-exec-shim"; version; capabilities = []; release = None; boot_id = None }
  in
  check (result int string) "v2 shim" (Ok 2) (major_int (probe "2.4.1"));
  check (result int string) "v3 shim" (Ok 3) (major_int (probe "3.0.0"));
  (match major_int (probe "1.4.2") with
   | Ok _ -> fail "v1 accepted"
   | Error msg -> check bool "names both sides" true (contains "v1" msg && contains "v2, v3" msg));
  (* A static artifact stamps its build sha after the dotted version
     ("3.0.0+a1b2c3d4"); the major is still the numeric prefix, so a stamped
     probe is spoken, never a skew. *)
  check (result int string) "stamped v3 shim" (Ok 3)
    (major_int (probe "3.0.0+a1b2c3d4"));
  check (result int string) "stamped v2 shim" (Ok 2)
    (major_int (probe "2.4.1+00000000"));
  (match major_int (probe "4.0.0") with
   | Ok _ -> fail "v4 accepted"
   | Error _ -> ());
  match major_int (probe "garbage") with
  | Ok _ -> fail "no major accepted"
  | Error msg -> check bool "says there is no major" true (contains "no numeric major" msg)

let test_execution_receipts_preserve_process_outcome () =
  let open Exec_ssh_protocol in
  let trailer = { v = newest; exit = Some 127; signal = None;
                  timed_out = false; shim_error = None; observed_syscalls = [] } in
  List.iter (fun mode ->
    List.iter (fun boundary ->
      let execution_receipt = { mode; boundary } in
      let wire = render_trailer ~execution_receipt trailer in
      check bool "same response retains exact receipt" true
        (parse_execution_receipt wire = Ok (Some execution_receipt));
      check bool "receipt never rewrites the child status" true
        (parse_trailer wire = Ok trailer))
      [Sandbox_applied; Setup_failed; Exec_failed; Child_ack_unavailable; Refused; Refused_socket; Refused_write])
    [Effect; Observe; Guest_local];
  check bool "old peer supplies no receipt, not inferred Effect" true
    (parse_execution_receipt (render_trailer trailer) = Ok None);
  let malformed receipt =
    "\x1e" ^ Yojson.Safe.to_string
      (`Assoc ["masc_exec_result", `Assoc
        ["v", `Int (int_of_major newest); "exit", `Int 127; "signal", `Null;
         "timed_out", `Bool false; "shim_error", `Null; "execution_receipt", receipt]])
    ^ "\x1e"
  in
  List.iter (fun receipt ->
    let wire = malformed receipt in
    check bool "malformed receipt does not erase process outcome" true
      (parse_trailer wire = Ok trailer);
    check bool "malformed receipt is explicitly rejected" true
      (Result.is_error (parse_execution_receipt wire)))
    [`Null; `Assoc []; `Assoc ["mode", `String "observe";
       "plan", `String "unrestricted"; "boundary", `String "sandbox_applied"]]

(* --- request acceptance frame --- *)

let test_acceptance_frame_is_opt_in_on_the_wire () =
  let wire r =
    match Exec_ssh_protocol.encode_request r ~stdin:"" with
    | Ok framed -> framed
    | Error e -> fail e
  in
  check bool "a request that does not ask carries no such field" false
    (contains "acceptance_frame" (wire req));
  let asking = { req with acceptance_frame = true } in
  check bool "a request that asks says so" true
    (contains "\"acceptance_frame\":true" (wire asking));
  (match Exec_ssh_protocol.decode_request (wire asking) with
   | Ok (r, _) -> check bool "the shim reads it back" true r.acceptance_frame
   | Error e -> fail e);
  (match Exec_ssh_protocol.decode_request (wire req) with
   | Ok (r, _) -> check bool "an older host's request reads as not asking" false r.acceptance_frame
   | Error e -> fail e);
  match Exec_ssh_protocol.encode_request { asking with v = Exec_ssh_protocol.V2 } ~stdin:"" with
  | Ok _ -> fail "a v2 frame asked for a frame its shim cannot write"
  | Error e -> check bool "named version error" true (contains "remote_ssh_version_error" e)

let test_acceptance_frame_roundtrip () =
  let open Exec_ssh_protocol in
  List.iter (fun v ->
    let frame = render_acceptance_frame v in
    check bool "delimited by record separators" true
      (frame.[0] = '\x1e' && frame.[String.length frame - 1] = '\x1e');
    check bool "the whole frame is a frame with nothing around it" true
      (split_acceptance_head frame = Head_frame { v; preamble = ""; rest = "" });
    check bool "payload after the frame is kept, byte for byte" true
      (split_acceptance_head (frame ^ "out\x1e\x00\xff")
       = Head_frame { v; preamble = ""; rest = "out\x1e\x00\xff" }))
    majors

(* ssh and container exec print lines of their own before the shim runs. The
   frame is the first record separator, and what came ahead of it is returned
   to the caller untouched. *)
let test_acceptance_frame_after_a_transport_line () =
  let open Exec_ssh_protocol in
  let frame = render_acceptance_frame newest in
  let line = "** WARNING: connection is not using a post-quantum key exchange\n" in
  check bool "a transport line ahead of the frame is the preamble" true
    (split_acceptance_head (line ^ frame ^ "out")
     = Head_frame { v = newest; preamble = line; rest = "out" });
  check bool "the line alone, with no separator yet, is pending" true
    (split_acceptance_head line = Head_pending);
  check bool "the line and a started frame are pending" true
    (split_acceptance_head (line ^ String.sub frame 0 7) = Head_pending)

(* Every prefix of a frame is held back; the frame is recognized at its closing
   separator and not before. A shorter prefix released early would put frame
   bytes into the payload stderr the model reads. *)
let test_acceptance_frame_is_held_until_it_closes () =
  let open Exec_ssh_protocol in
  let frame = render_acceptance_frame newest in
  for k = 0 to String.length frame - 1 do
    check bool (Printf.sprintf "a %d-byte prefix is pending" k) true
      (split_acceptance_head (String.sub frame 0 k) = Head_pending)
  done

let test_acceptance_head_that_is_not_a_frame_is_payload () =
  let open Exec_ssh_protocol in
  List.iter (fun (name, head) ->
    check bool name true (split_acceptance_head head = Head_payload))
    [ "separators around something else", "\x1e{\"masc_exec_result\":{}}\x1e"
    ; "separators around non-JSON", "\x1enot json\x1e"
    ; "a separator followed by bytes no frame starts with", "\x1ejunk"
    ; "a frame of a major no build speaks",
      "\x1e{\"masc_request_accepted\":{\"v\":99}}\x1e"
    ; "a frame without a major", "\x1e{\"masc_request_accepted\":{}}\x1e"
    ; "output with no separator that outgrows the bound",
      String.make acceptance_frame_max_bytes 'x' ];
  check bool "short output with no separator is pending" true
    (split_acceptance_head "hello\n" = Head_pending)

(* A stream reader decides one chunk at a time and the host decides again on
   the whole text afterwards. Both must reach the same answer, so a frame
   that starts at or past the bound is payload however it arrives. *)
let test_a_frame_starting_past_the_bound_is_payload () =
  let open Exec_ssh_protocol in
  let frame = render_acceptance_frame newest in
  let last_inside = String.make (acceptance_frame_max_bytes - 1) 'x' in
  check bool "a frame starting at the last byte inside the bound is read" true
    (split_acceptance_head (last_inside ^ frame ^ "out")
     = Head_frame { v = newest; preamble = last_inside; rest = "out" });
  let first_outside = String.make acceptance_frame_max_bytes 'x' in
  check bool "a frame starting at the bound is payload" true
    (split_acceptance_head (first_outside ^ frame) = Head_payload);
  check bool "so is one starting far past it" true
    (split_acceptance_head (first_outside ^ first_outside ^ frame) = Head_payload)

(* The host reads stderr in pieces, holding the head while it is pending, and
   again as a whole once the process is done. The two must agree wherever the
   pieces are cut. This replays the stream reader on every two-way split of a
   stream, and on a split into single bytes. *)
let read_in_pieces pieces =
  let open Exec_ssh_protocol in
  let rec go held = function
    | [] -> (match split_acceptance_head held with
             | Head_pending -> `Pending held
             | Head_payload -> `Payload held
             | Head_frame { v; preamble; rest } -> `Frame (v, preamble, rest))
    | piece :: later ->
      (match split_acceptance_head (held ^ piece) with
       | Head_pending -> go (held ^ piece) later
       | Head_payload -> `Payload (held ^ piece ^ String.concat "" later)
       | Head_frame { v; preamble; rest } ->
         `Frame (v, preamble, rest ^ String.concat "" later))
  in
  go "" pieces

let test_a_stream_read_in_pieces_agrees_with_the_whole () =
  let open Exec_ssh_protocol in
  let frame = render_acceptance_frame newest in
  let at k = String.make k 'x' in
  let spaced = "\x1e{\"masc_request_accepted\": {\"v\": 3}}\x1e" in
  let streams =
    [ "frame first", frame ^ "out"
    ; "a line then the frame", "warn\n" ^ frame ^ "out"
    ; "frame starting at the last byte inside the bound",
      at (acceptance_frame_max_bytes - 1) ^ frame ^ "out"
    ; "frame starting two bytes inside the bound",
      at (acceptance_frame_max_bytes - 2) ^ frame ^ "out"
    ; "frame starting at the bound", at acceptance_frame_max_bytes ^ frame
    ; "a frame spaced differently", spaced ^ "out"
    ; "a frame of a major no build speaks",
      "\x1e{\"masc_request_accepted\":{\"v\":99}}\x1eout"
    ; "a trailer and no frame", "\x1e{\"masc_exec_result\":{}}\x1e"
    ; "a cut off frame", at 5 ^ String.sub frame 0 9
    ; "output with no separator", "plain output\n" ]
  in
  List.iter (fun (name, stream) ->
    let whole = read_in_pieces [ stream ] in
    for cut = 0 to String.length stream do
      let pieces = [ String.sub stream 0 cut; String.sub stream cut (String.length stream - cut) ] in
      check bool (Printf.sprintf "%s: cut at %d" name cut) true (read_in_pieces pieces = whole)
    done;
    let bytes = List.init (String.length stream) (fun i -> String.make 1 stream.[i]) in
    check bool (name ^ ": one byte at a time") true (read_in_pieces bytes = whole))
    streams

(* The stream ended on a head still pending. A frame the wire cut off is not
   payload; everything else is. *)
let test_a_cut_off_frame_is_not_payload () =
  let open Exec_ssh_protocol in
  let frame = render_acceptance_frame newest in
  let cut = String.sub frame 0 9 in
  let at k = String.make k 'x' in
  check string "a cut frame is dropped" "" (settle_acceptance_head cut);
  check string "a transport line before it is kept" "warn\n"
    (settle_acceptance_head ("warn\n" ^ cut));
  check string "a cut frame starting at the last byte inside the bound is dropped"
    (at (acceptance_frame_max_bytes - 1))
    (settle_acceptance_head (at (acceptance_frame_max_bytes - 1) ^ cut));
  check string "a cut frame starting at the bound is kept as payload"
    (at acceptance_frame_max_bytes ^ cut)
    (settle_acceptance_head (at acceptance_frame_max_bytes ^ cut));
  check string "output without a separator is kept" "warn\n"
    (settle_acceptance_head "warn\n")

(* {1 Guest agent relay} *)

module Relay = Exec_ssh_protocol.Relay

(* A raw chunk with any kind byte and payload, for the cases [encode] never
   writes. *)
let relay_frame kind payload =
  let length = String.length payload in
  let bytes = Bytes.create (5 + length) in
  Bytes.set bytes 0 kind;
  Bytes.set_int32_be bytes 1 (Int32.of_int length);
  Bytes.blit_string payload 0 bytes 5 length;
  Bytes.to_string bytes

(* Every chunk in [bytes], in order. Fails on an error or a cut tail. *)
let relay_decode_all bytes =
  let rec go pos acc =
    if pos = String.length bytes
    then List.rev acc
    else
      match Relay.decode bytes ~pos with
      | Ok (Relay.Chunk { chunk; consumed }) -> go (pos + consumed) (chunk :: acc)
      | Ok Relay.Need_more -> fail "a complete stream ended in the middle of a chunk"
      | Error _ -> fail "a chunk this module encoded did not decode"
  in
  go 0 []

let relay_hello =
  Relay.{ relay_version = Relay.version
        ; source_identity = Source_identity.current
        ; root_read_only = true
        ; uid = 502
        ; gid = 20
        ; no_new_privs = true }

let test_relay_chunks_roundtrip () =
  let chunks =
    Relay.[ Hello relay_hello
          ; Stdout "out"
          ; Stderr "err\x1e"
          ; Stdout ""
          ; Exit (Exited 3)
          ; Exit (Signaled 9) ]
  in
  check bool "every chunk decodes to itself, in order" true
    (relay_decode_all (String.concat "" (List.map Relay.encode chunks)) = chunks)

let test_relay_splits_long_output () =
  let bytes =
    String.init (2 * Relay.max_payload_bytes + 7) (fun index -> Char.chr (index mod 256))
  in
  match relay_decode_all (Relay.encode (Relay.Stdout bytes)) with
  | [ Relay.Stdout first; Relay.Stdout second; Relay.Stdout third ] ->
    check int "the first chunk is at the limit" Relay.max_payload_bytes (String.length first);
    check int "the last chunk carries the rest" 7 (String.length third);
    check bool "the pieces join back to the output" true (first ^ second ^ third = bytes)
  | _ -> fail "long output did not become three stdout chunks"

let test_relay_waits_for_a_whole_chunk () =
  let whole = Relay.encode (Relay.Stdout "payload") in
  for cut = 0 to String.length whole - 1 do
    match Relay.decode (String.sub whole 0 cut) ~pos:0 with
    | Ok Relay.Need_more -> ()
    | Ok (Relay.Chunk _) | Error _ -> failf "a chunk cut at %d bytes was read" cut
  done

let test_relay_refuses_bad_headers () =
  (match Relay.decode (relay_frame '\009' "") ~pos:0 with
   | Error (Relay.Unknown_kind kind) -> check int "the unknown kind byte" 9 kind
   | Ok _ | Error _ -> fail "an unknown kind byte was read");
  let header length =
    let bytes = Bytes.create 5 in
    Bytes.set bytes 0 '\002';
    Bytes.set_int32_be bytes 1 length;
    Bytes.to_string bytes
  in
  List.iter
    (fun (label, length) ->
       match Relay.decode (header length) ~pos:0 with
       | Error (Relay.Oversized _) -> ()
       | Ok _ | Error _ -> failf "%s was waited for instead of refused" label)
    [ "a length past the limit", Int32.of_int (Relay.max_payload_bytes + 1)
    ; "a negative length", Int32.min_int ]

let test_relay_hello_is_strict () =
  List.iter
    (fun (label, payload) ->
       match Relay.decode (relay_frame '\001' payload) ~pos:0 with
       | Error (Relay.Malformed_hello _) -> ()
       | Ok _ | Error _ -> failf "%s was read as a hello" label)
    [ "a missing field", {|{"relay_version":1,"root_read_only":true,"uid":502,"gid":20}|}
    ; "a mistyped field",
      {|{"relay_version":"1","root_read_only":true,"uid":502,"gid":20,"no_new_privs":true}|}
    ; "an unknown field",
      {|{"relay_version":1,"root_read_only":true,"uid":502,"gid":20,"no_new_privs":true,"extra":0}|}
    ; "a repeated field",
      {|{"relay_version":1,"relay_version":1,"root_read_only":true,"uid":502,"gid":20,"no_new_privs":true}|}
    ; "not an object", {|[1]|}
    ; "not JSON", "{" ]

let test_relay_exit_is_strict () =
  List.iter
    (fun (label, payload) ->
       match Relay.decode (relay_frame '\004' payload) ~pos:0 with
       | Error (Relay.Malformed_exit _) -> ()
       | Ok _ | Error _ -> failf "%s was read as an exit" label)
    [ "a short payload", "\000\000\000\000"
    ; "an unknown tag", "\007\000\000\000\001" ]

let test_relay_request_kinds_are_closed () =
  List.iter
    (fun kind ->
       check bool "a kind byte reads back as its kind" true
         (Relay.request_kind_of_byte (Relay.request_kind_byte kind) = Some kind))
    Relay.[ Run; Probe; Interactive_run ];
  check char "interactive runs have a distinct wire kind" 'I'
    (Relay.request_kind_byte Relay.Interactive_run);
  check int "interactive relay contract has its own version" 2 Relay.version;
  check bool "another byte is no kind" true (Relay.request_kind_of_byte 'X' = None)

(* RFC host-and-shim-share-one-build-identity. *)
let sha1 c = String.make 40 c

let test_relay_hello_without_identity_reads_as_none () =
  match
    Relay.decode
      (relay_frame '\001'
         {|{"relay_version":1,"root_read_only":true,"uid":502,"gid":20,"no_new_privs":true}|})
      ~pos:0
  with
  | Ok (Relay.Chunk { chunk = Relay.Hello { Relay.source_identity = None; relay_version = 1; _ }; _ }) -> ()
  | Ok _ | Error _ -> fail "a hello that names no source did not read as one"

let test_relay_hello_identity_is_strict () =
  List.iter
    (fun (label, identity) ->
       let payload =
         Printf.sprintf
           {|{"relay_version":2,"source_identity":%s,"root_read_only":true,"uid":502,"gid":20,"no_new_privs":true}|}
           identity in
       match Relay.decode (relay_frame '\001' payload) ~pos:0 with
       | Error (Relay.Malformed_hello _) -> ()
       | Ok _ | Error _ -> failf "%s was read as a hello" label)
    [ "a number", "1"
    ; "a commit without a state", Printf.sprintf "%S" (sha1 'a')
    ; "upper-case hex", Printf.sprintf "%S" (String.make 40 'A' ^ "/clean")
    ; "a short commit", Printf.sprintf "%S" (String.make 39 'a' ^ "/clean") ]

let test_relay_hello_identity_roundtrips () =
  let identity = { Source_identity.commit = sha1 'b'; state = Source_identity.Modified { digest = sha1 'c' } } in
  let hello = { relay_hello with Relay.source_identity = Some identity } in
  match Relay.decode (Relay.encode (Relay.Hello hello)) ~pos:0 with
  | Ok (Relay.Chunk { chunk = Relay.Hello decoded; _ }) ->
    check bool "the identity reads back" true
      (match decoded.Relay.source_identity with
       | Some got -> Source_identity.equal got identity
       | None -> false)
  | Ok _ | Error _ -> fail "the hello did not read back"

let test_source_identity_grammar () =
  let clean = { Source_identity.commit = sha1 'a'; state = Source_identity.Clean } in
  let modified = { Source_identity.commit = sha1 'a'; state = Source_identity.Modified { digest = sha1 'd' } } in
  let sha256 = { Source_identity.commit = String.make 64 'e'; state = Source_identity.Clean } in
  List.iter
    (fun identity ->
       check bool "an identity reads back from its string" true
         (match Source_identity.of_string (Source_identity.to_string identity) with
          | Some got -> Source_identity.equal got identity
          | None -> false))
    [ clean; modified; sha256 ];
  check bool "clean and modified of one commit differ" false (Source_identity.equal clean modified);
  List.iter
    (fun text ->
       check bool (text ^ " is no identity") true (Source_identity.of_string text = None))
    [ ""; sha1 'a'; sha1 'a' ^ "/"; sha1 'a' ^ "/dirty"; sha1 'a' ^ "/modified:"
    ; sha1 'a' ^ "/modified:" ^ String.make 41 'd'; String.make 40 'g' ^ "/clean" ]

let test_source_identity_scan () =
  let a = { Source_identity.commit = sha1 'a'; state = Source_identity.Clean } in
  let b = { Source_identity.commit = sha1 'b'; state = Source_identity.Clean } in
  let declared bytes =
    match Source_identity.scan bytes with
    | Source_identity.Declared got -> Some got
    | Source_identity.Undeclared | Source_identity.Several _ -> None in
  check bool "one declaration among other bytes" true
    (match declared ("\000ELF..." ^ Source_identity.declaration a ^ "\000tail") with
     | Some got -> Source_identity.equal got a
     | None -> false);
  check bool "a repeated declaration is one" true
    (match declared (Source_identity.declaration a ^ Source_identity.declaration a) with
     | Some got -> Source_identity.equal got a
     | None -> false);
  check bool "two sources are several, in byte order" true
    (match Source_identity.scan (Source_identity.declaration b ^ Source_identity.declaration a) with
     | Source_identity.Several [ first; second ] ->
       Source_identity.equal first b && Source_identity.equal second a
     | Source_identity.Several _ | Source_identity.Declared _ | Source_identity.Undeclared -> false);
  List.iter
    (fun bytes ->
       check bool "no declaration" true (Source_identity.scan bytes = Source_identity.Undeclared))
    [ ""; "MASC_SOURCE_IDENTITY="; "MASC_SOURCE_IDENTITY=\000\000\002;"
    ; "MASC_SOURCE_IDENTITY=" ^ sha1 'a' ^ "/clean"
    ; "MASC_SOURCE_IDENTITY=" ^ sha1 'a' ^ "/clean" ^ String.make 200 'x' ^ ";"
    ; "MASC_EXEC_SHIM_RELAY_VERSION=2;" ]

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
    ; "source identity",
      [ test_case "a hello without one reads as none" `Quick
          test_relay_hello_without_identity_reads_as_none
      ; test_case "a hello identity is strict" `Quick test_relay_hello_identity_is_strict
      ; test_case "a hello identity roundtrips" `Quick test_relay_hello_identity_roundtrips
      ; test_case "the grammar" `Quick test_source_identity_grammar
      ; test_case "scan" `Quick test_source_identity_scan ]
    ; "interactive stdin",
      [ test_case "the header leaves live bytes outside the frame" `Quick
          test_interactive_header_keeps_live_bytes_outside_the_frame
      ; test_case "framed headers keep their length field" `Quick
          test_framed_headers_keep_their_length_field
      ; test_case "an initial payload is refused" `Quick
          test_interactive_initial_payload_is_refused
      ; test_case "input headers are unambiguous" `Quick test_input_headers_are_unambiguous
      ; test_case "V2 refuses interactive input" `Quick test_v2_refuses_interactive_input
      ; test_case "only a capable V3 probe grants interactive input" `Quick
          test_interactive_input_requires_a_capable_v3_probe ]
    ; "trailer", [ test_case "execution receipts preserve process outcome" `Quick
                     test_execution_receipts_preserve_process_outcome
                 ; test_case "roundtrip" `Quick test_trailer_roundtrip
                 ; test_case "observed_syscalls roundtrip" `Quick
                     test_trailer_observed_syscalls_roundtrip
                 ; test_case "missing observed_syscalls is empty" `Quick
                     test_trailer_missing_observed_syscalls_is_empty
                 ; test_case "malformed is transport error" `Quick test_trailer_malformed_is_transport_error
                 ; test_case "absent is transport error" `Quick test_trailer_absent_is_transport_error
                 ; test_case "last match wins" `Quick test_trailer_last_match_wins
                 ; test_case "version gated" `Quick test_trailer_version_gated
                 ; test_case "exit 0 is a real exit" `Quick test_exit_zero_is_a_real_exit
                 ; test_case "exclusivity violation is transport error" `Quick
                     test_trailer_exclusivity_violation_is_transport_error
                 ; test_case "signal vs exit" `Quick test_signal_vs_exit ]
    ; "acceptance frame",
      [ test_case "is opt in on the wire" `Quick test_acceptance_frame_is_opt_in_on_the_wire
      ; test_case "roundtrip" `Quick test_acceptance_frame_roundtrip
      ; test_case "follows a transport line" `Quick
          test_acceptance_frame_after_a_transport_line
      ; test_case "is held until it closes" `Quick
          test_acceptance_frame_is_held_until_it_closes
      ; test_case "a frame starting past the bound is payload" `Quick
          test_a_frame_starting_past_the_bound_is_payload
      ; test_case "pieces agree with the whole at every cut" `Quick
          test_a_stream_read_in_pieces_agrees_with_the_whole
      ; test_case "a cut off frame is not payload" `Quick
          test_a_cut_off_frame_is_not_payload
      ; test_case "a head that is not a frame is payload" `Quick
          test_acceptance_head_that_is_not_a_frame_is_payload ]
    ; "two majors", [ test_case "a v2 frame has no mode and means effect" `Quick
                        test_a_v2_frame_has_no_mode_and_means_effect
                    ; test_case "a v2 frame cannot carry a box" `Quick
                        test_a_v2_frame_cannot_carry_a_box
                    ; test_case "a v2 trailer is read" `Quick test_a_v2_trailer_is_read
                    ; test_case "the majors are closed" `Quick
                        test_the_majors_are_closed ]
    ; "probe", [ test_case "roundtrip" `Quick test_probe_roundtrip
               ; test_case "boot identity is optional and validated" `Quick test_probe_boot_id_is_optional_and_validated
               ; test_case "carries the release it was built from" `Quick
                   test_probe_carries_the_release_it_was_built_from
               ; test_case "major is spoken or a skew" `Quick
                   test_probe_major_is_spoken_or_a_skew ]
    ; "relay", [ test_case "chunks roundtrip" `Quick test_relay_chunks_roundtrip
               ; test_case "long output is split" `Quick test_relay_splits_long_output
               ; test_case "a cut chunk waits" `Quick test_relay_waits_for_a_whole_chunk
               ; test_case "bad headers are refused" `Quick test_relay_refuses_bad_headers
               ; test_case "hello is strict" `Quick test_relay_hello_is_strict
               ; test_case "exit is strict" `Quick test_relay_exit_is_strict
               ; test_case "request kinds are closed" `Quick
                   test_relay_request_kinds_are_closed ] ]
