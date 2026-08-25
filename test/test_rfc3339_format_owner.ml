(** Pins RFC 3339 writing to one implementation.

    Eight sites hand-wrote ["%04d-%02d-%02dT%02d:%02d:%02dZ"] before
    {!Time_codec.rfc3339_of_unix} existed. Two guarantees keep them from
    drifting apart again: the surviving public entry points agree byte for
    byte with the owner, and what the owner writes is what
    {!Time_codec.parse_rfc3339} reads back.

    The last group pins the three inputs where that round trip does not
    hold. They are stated in the owner's docstring; #27131 owns the decision
    about changing the type. A test that asserts today's behaviour keeps the
    docstring from claiming something the code stopped doing. *)

let check_string = Alcotest.(check string)

(* label, unix seconds, expected rendering *)
let round_trip_cases =
  [ "epoch", 0.0, "1970-01-01T00:00:00Z"
  ; "one second past epoch", 1.0, "1970-01-01T00:00:01Z"
  ; "a 2025 instant", 1754000000.0, "2025-07-31T22:13:20Z"
  ; "one second before epoch", -1.0, "1969-12-31T23:59:59Z"
  ; "a full day before epoch", -86400.0, "1969-12-31T00:00:00Z"
  ; "last second Ptime accepts", 253402300799.0, "9999-12-31T23:59:59Z"
  ]
;;

let test_rendering () =
  List.iter
    (fun (label, seconds, expected) ->
      check_string label expected (Time_codec.rfc3339_of_unix seconds))
    round_trip_cases
;;

let test_round_trip () =
  List.iter
    (fun (label, seconds, _) ->
      let rendered = Time_codec.rfc3339_of_unix seconds in
      match Time_codec.parse_rfc3339 ~strict:true rendered with
      | Ok back ->
        Alcotest.(check (float 0.0))
          (label ^ ": parses back to the same instant")
          seconds
          back
      | Error Time_codec.Invalid_rfc3339 ->
        Alcotest.failf "%s: the canonical reader rejected %S" label rendered)
    round_trip_cases
;;

let test_fraction_is_dropped () =
  check_string
    "sub-second input truncates rather than rounding up"
    "2025-07-31T22:13:20Z"
    (Time_codec.rfc3339_of_unix 1754000000.75)
;;

(* The delegating entry points are what production actually calls. Comparing
   them against the owner is what makes the collapse a no-op rather than a
   claim about one. *)
let test_delegates_agree () =
  List.iter
    (fun (label, seconds, _) ->
      let owner = Time_codec.rfc3339_of_unix seconds in
      check_string
        (label ^ ": Masc_domain.iso8601_of_unix_seconds")
        owner
        (Masc_domain.iso8601_of_unix_seconds seconds);
      check_string
        (label ^ ": Gate_time_util.iso8601_of_unix")
        owner
        (Gate_time_util.iso8601_of_unix seconds);
      (* This one is here because it was missing. [cutoff_of] hand-wrote the
         format in bin/ and so was invisible to a list of delegates kept by
         hand — the same shape #29358 is about. Its hours argument is the
         offset it subtracts, so zero hours is the plain rendering. *)
      check_string
        (label ^ ": Masc_tui_keeper_activity.cutoff_of")
        owner
        (Masc_tui_keeper_activity.cutoff_of ~now:seconds ~hours:0))
    round_trip_cases
;;

let test_now_iso_is_readable () =
  let rendered = Masc_domain.now_iso () in
  match Time_codec.parse_rfc3339 ~strict:true rendered with
  | Ok _ -> ()
  | Error Time_codec.Invalid_rfc3339 ->
    Alcotest.failf "now_iso produced %S, which the canonical reader rejects" rendered
;;

(* ---- documented failure modes (#27131) ---- *)

(* nan is bad in two different ways depending on the C library. Darwin's
   gmtime accepts it and yields the epoch, so the value becomes
   indistinguishable from a genuine 1970 timestamp. glibc raises EOVERFLOW, so
   it escapes as an exception from a signature that promises a string. This
   suite ran green on Darwin and red on the Linux runner until it stopped
   asserting one platform's answer. A third behaviour fails the test. *)
let test_nan_does_not_survive_as_itself () =
  match Time_codec.rfc3339_of_unix Float.nan with
  | exception Unix.Unix_error (_, "gmtime", _) -> ()
  | "1970-01-01T00:00:00Z" -> ()
  | other ->
    Alcotest.failf "nan rendered as %S, which neither platform did; #27131 needs revisiting" other
;;

let test_past_year_9999_is_unreadable () =
  let rendered = Time_codec.rfc3339_of_unix 253402300800.0 in
  check_string "a five-digit year is emitted" "10000-01-01T00:00:00Z" rendered;
  match Time_codec.parse_rfc3339 ~strict:true rendered with
  | Error Time_codec.Invalid_rfc3339 -> ()
  | Ok _ ->
    Alcotest.fail
      "the canonical reader now accepts a five-digit year; #27131 needs revisiting"
;;

(* Asserted as "does not survive the round trip" rather than "raises
   EOVERFLOW": whether [Unix.gmtime] rejects the value or renders an absurd
   year is the platform's C library talking, and this suite runs on more than
   one. The property that matters either way is that the value cannot be
   written and read back. *)
let test_far_future_does_not_round_trip () =
  match Time_codec.rfc3339_of_unix 1e18 with
  | exception Unix.Unix_error (_, "gmtime", _) -> ()
  | rendered ->
    (match Time_codec.parse_rfc3339 ~strict:true rendered with
     | Error Time_codec.Invalid_rfc3339 -> ()
     | Ok back ->
       Alcotest.failf
         "1e18 rendered as %S and read back as %f; #27131 needs revisiting"
         rendered
         back)
;;

let () =
  Alcotest.run
    "rfc3339 format owner"
    [ ( "owner"
      , [ Alcotest.test_case "renders the pinned strings" `Quick test_rendering
        ; Alcotest.test_case "round-trips through the reader" `Quick test_round_trip
        ; Alcotest.test_case "drops the fractional part" `Quick test_fraction_is_dropped
        ] )
    ; ( "delegates"
      , [ Alcotest.test_case "agree with the owner" `Quick test_delegates_agree
        ; Alcotest.test_case "now_iso stays readable" `Quick test_now_iso_is_readable
        ] )
    ; ( "documented failure modes"
      , [ Alcotest.test_case
            "nan does not survive as itself"
            `Quick
            test_nan_does_not_survive_as_itself
        ; Alcotest.test_case
            "past year 9999 the reader rejects it"
            `Quick
            test_past_year_9999_is_unreadable
        ; Alcotest.test_case
            "far future cannot be read back"
            `Quick
            test_far_future_does_not_round_trip
        ] )
    ]
;;
