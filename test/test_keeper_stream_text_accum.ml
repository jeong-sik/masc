(** test_keeper_stream_text_accum — behavioral guard for issue #20907.

    Pins the keeper chat text-delta policy: deltas are emitted live with
    per-delta redaction, the terminal full-reply re-send fires only when
    nothing was streamed, and the raw concatenation stays available as the
    terminal empty-reply fallback. #20825 and #20869 both removed live
    emission without any test failing; these tests make the next removal
    visible. *)

let test_fresh_accum_allows_terminal_resend () =
  let t = Keeper_stream_text_accum.create () in
  Alcotest.(check bool)
    "no deltas → terminal re-send allowed" false
    (Keeper_stream_text_accum.suppress_terminal_resend t);
  Alcotest.(check string)
    "fallback starts empty" ""
    (Keeper_stream_text_accum.streamed_text t)

let test_delta_emitted_live_with_per_delta_redaction () =
  let t = Keeper_stream_text_accum.create () in
  let redact s = "[r]" ^ s in
  let chunk = Keeper_stream_text_accum.on_delta t ~redact "hello" in
  Alcotest.(check string)
    "live chunk passes through the per-delta redactor" "[r]hello" chunk;
  Alcotest.(check bool)
    "delta emitted → terminal re-send suppressed" true
    (Keeper_stream_text_accum.suppress_terminal_resend t)

let test_fallback_keeps_raw_concatenation_in_order () =
  let t = Keeper_stream_text_accum.create () in
  let redact = String.uppercase_ascii in
  ignore (Keeper_stream_text_accum.on_delta t ~redact "ab");
  ignore (Keeper_stream_text_accum.on_delta t ~redact "cd");
  Alcotest.(check string)
    "fallback is the raw (unredacted) concatenation in arrival order" "abcd"
    (Keeper_stream_text_accum.streamed_text t)

let () =
  Alcotest.run "keeper_stream_text_accum"
    [ ( "delta-policy"
      , [ Alcotest.test_case "fresh accum allows terminal re-send" `Quick
            test_fresh_accum_allows_terminal_resend
        ; Alcotest.test_case "delta emitted live, redacted per delta" `Quick
            test_delta_emitted_live_with_per_delta_redaction
        ; Alcotest.test_case "terminal fallback keeps raw concatenation" `Quick
            test_fallback_keeps_raw_concatenation_in_order
        ] )
    ]
