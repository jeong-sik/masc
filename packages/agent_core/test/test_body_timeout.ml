(** Unit tests for [body_timeout_s] option.

    Validates the field flow plus the operator-facing message contract
    for non-streaming [TimeoutError { phase = Non_streaming_body; _ }]. *)

open Agent_core

let tc name f = Alcotest.test_case name `Quick f

(* ── Field default + record update flow ─────────────────────────── *)

let test_default_options_body_timeout_none () =
  Alcotest.(check (option (float 0.001)))
    "default body_timeout_s is None"
    None
    Agent.default_options.body_timeout_s
;;

let test_options_record_update () =
  let opts = Agent.default_options in
  Alcotest.(check (option (float 0.001)))
    "baseline body_timeout_s is None"
    None
    opts.body_timeout_s;
  let opts' = { opts with body_timeout_s = Some 180.0 } in
  Alcotest.(check (option (float 0.001)))
    "record update sets body_timeout_s"
    (Some 180.0)
    opts'.body_timeout_s;
  Alcotest.(check (option (float 0.001)))
    "stream_idle_timeout_s untouched by body_timeout update"
    None
    opts'.stream_idle_timeout_s
;;

(* ── Message-prefix contract ────────────────────────────────────────

   The timeout is typed by [TimeoutError.phase], but the message is
   still pinned because operators and logs use it to distinguish
   non-streaming body deadlines from streaming idle deadlines. *)

let body_timeout_message timeout_s =
  Printf.sprintf
    "body_timeout_s deadline exceeded after %.1fs (Complete.complete non-streaming path; \
     total HTTP round-trip cap)"
    timeout_s
;;

let starts_with ~prefix s =
  let lp = String.length prefix in
  String.length s >= lp && String.equal (String.sub s 0 lp) prefix
;;


let test_message_has_promotion_prefix () =
  let msg = body_timeout_message 180.0 in
  Alcotest.(check bool)
    "prefix matches Complete outer-match guard"
    true
    (starts_with ~prefix:"body_timeout_s deadline exceeded" msg)
;;

let test_message_includes_configured_value () =
  let msg = body_timeout_message 180.0 in
  Alcotest.(check bool)
    "message records the configured deadline (180.0)"
    true
    (Agent_core_strings.contains_substring ~needle:"180.0" ~haystack:msg)
;;

let test_message_distinguishes_from_idle_timeout () =
  (* Operators must be able to tell sync body deadline from inter-line idle
     deadline by reading the message alone — the two have different
     remediations. *)
  let msg = body_timeout_message 30.0 in
  Alcotest.(check bool)
    "message names Complete.complete path"
    true
    (Agent_core_strings.contains_substring ~needle:"Complete.complete non-streaming path" ~haystack:msg);
  Alcotest.(check bool)
    "message disambiguates from stream_idle_timeout_s"
    true
    (Agent_core_strings.contains_substring ~needle:"Complete.complete non-streaming path" ~haystack:msg)
;;

let () =
  Alcotest.run
    "body_timeout"
    [ ( "options field flow"
      , [ tc "default None" test_default_options_body_timeout_none
        ; tc "record update" test_options_record_update
        ] )
    ; ( "message-prefix contract"
      , [ tc "promotion prefix" test_message_has_promotion_prefix
        ; tc "configured value present" test_message_includes_configured_value
        ; tc "disambiguation tokens" test_message_distinguishes_from_idle_timeout
        ] )
    ]
;;
