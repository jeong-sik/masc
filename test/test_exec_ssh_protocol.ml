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
                            ; stdin_len = 0L
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

(* RFC-0427 B-3. The shim names the release it was built from, beside the
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
      [Sandbox_applied; Setup_failed; Exec_failed; Child_ack_unavailable; Refused])
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

(* The stream ended on a head still pending. A frame the wire cut off is not
   payload; everything else is. *)
let test_a_cut_off_frame_is_not_payload () =
  let open Exec_ssh_protocol in
  let frame = render_acceptance_frame newest in
  let cut = String.sub frame 0 9 in
  check string "a cut frame is dropped" "" (settle_acceptance_head cut);
  check string "a transport line before it is kept" "warn\n"
    (settle_acceptance_head ("warn\n" ^ cut));
  check string "output without a separator is kept" "warn\n"
    (settle_acceptance_head "warn\n")

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
                   test_probe_major_is_spoken_or_a_skew ] ]
