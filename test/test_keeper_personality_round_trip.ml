(* test/test_keeper_personality_round_trip.ml

   Layer 1 of personality SSOT unification (see
   planning/2026-04-25-keeper-identity-canonicalization-rfc.md).

   #10061 introduced [personality_text_equal] with [String.trim] only.
   That captured the trailing-newline case but missed the larger drift:
   when persisted will/needs/desires exceed
   [Keeper_config.prompt_render_max_bytes] (320), the read path
   normalises to ~319 bytes, while reconcile's [target_will] keeps the
   raw value (~357 bytes for nick0cave).  Trim-only compare flagged
   that 38-byte gap as drift on every reconcile tick (~2880 redundant
   writes/day for nick0cave alone, 12% of all log volume).

   This test pins the round-trip invariant: when both sides are the
   same raw bytes, [personality_text_equal] returns true regardless of
   whether the value exceeds the prompt cap.  Disk preserves the raw
   value; compare uses the capped form.  No drift signal, no rewrite,
   loop terminates. *)

module KR = Masc_mcp.Keeper_runtime
module KC = Masc_mcp.Keeper_config

(* nick0cave's actual will field (357 bytes, 119 UTF-8 codepoints)
   from .masc/keepers/nick0cave.json on the day the loop was diagnosed.
   Reproduces the exact drift that motivated this fix. *)
let nick0cave_will =
  "구현 가능성이 보이면 바로 손을 댄다. 아직 안 만든 것은 핑계가 아니라 \
   대기열이다. 생각만 있는 상태를 오래 두지 않는다. 논쟁이 붙으면 가능한 한 \
   지지 않으려 하고, 말이 아니라 구현 증거로 뒤집는 쪽을 선호한다. 아니라면 \
   아니라고 말하고, 그 근거까지 가져온다."

let test_oversized_identical_is_equal () =
  (* The reconcile-loop killer: meta.will (357 bytes from disk) and
     target_will (357 bytes from apply_default) are byte-identical.
     Pre-fix: read normalised meta to 319 while target stayed at 357,
     trim-only compare flagged drift, write_meta rewrote 357 to disk,
     next tick repeated.  Post-fix: both sides normalise to 319 inside
     compare, equal, no rewrite. *)
  let len = String.length nick0cave_will in
  Alcotest.(check (neg int))
    "fixture must exceed the cap to exercise the drift path"
    KC.prompt_render_max_bytes len;
  Alcotest.(check bool)
    "oversized identical text compares equal (drift loop terminates)"
    true
    (KR.personality_text_equal nick0cave_will nick0cave_will)

let test_oversized_real_diff_still_detected () =
  (* Normalisation must not swallow real changes inside the cap.
     Append "X" near the start so the diff lands well within the
     first 319 bytes of normalised output. *)
  let modified =
    "X구현 가능성이 보이면 바로 손을 댄다. 아직 안 만든 것은 핑계가 아니라 \
     대기열이다. 생각만 있는 상태를 오래 두지 않는다. 논쟁이 붙으면 가능한 한 \
     지지 않으려 하고, 말이 아니라 구현 증거로 뒤집는 쪽을 선호한다. 아니라면 \
     아니라고 말하고, 그 근거까지 가져온다."
  in
  Alcotest.(check bool)
    "oversized text with a real intra-content change is NOT equal"
    false
    (KR.personality_text_equal nick0cave_will modified)

let test_oversized_with_trailing_whitespace_is_equal () =
  (* Combination of #10061 (trailing newline) and the cap-overflow
     path.  Both must compare equal: trim removes the newline,
     normalise caps the body, and the two sides agree. *)
  let with_newline = nick0cave_will ^ "\n\n" in
  Alcotest.(check bool)
    "oversized text with trailing whitespace compares equal"
    true
    (KR.personality_text_equal nick0cave_will with_newline)

let test_unicode_trailing_whitespace_is_equal () =
  (* #10552: NBSP (U+00A0 = C2 A0) and ideographic space (U+3000 = E3 80 80)
     are not stripped by [String.trim] but were the residual 4-byte drift
     that survived the #10479 symmetric-compare fix and kept nick0cave's
     personality re-sync firing at ~1/min. After [utf8_trim_trailing_whitespace],
     both sides must collapse to the same normalised form. *)
  let with_nbsp = nick0cave_will ^ "\xC2\xA0\xC2\xA0" in  (* 2 NBSP = 4 bytes *)
  let with_ideographic = nick0cave_will ^ "\xE3\x80\x80" in  (* 1 IS = 3 bytes *)
  let with_zero_width = nick0cave_will ^ "\xE2\x80\x8B" in  (* 1 ZWS = 3 bytes *)
  Alcotest.(check bool)
    "trailing NBSP (C2 A0) compares equal"
    true
    (KR.personality_text_equal nick0cave_will with_nbsp);
  Alcotest.(check bool)
    "trailing ideographic space (E3 80 80) compares equal"
    true
    (KR.personality_text_equal nick0cave_will with_ideographic);
  Alcotest.(check bool)
    "trailing zero-width space (E2 80 8B) compares equal"
    true
    (KR.personality_text_equal nick0cave_will with_zero_width)

let test_diff_summary_is_empty_for_identical_oversized () =
  (* The reconcile path uses [personality_diff_summary] to decide
     whether [personality_changed] fires.  An empty list is the
     authoritative signal that no rewrite happens. *)
  let entries =
    KR.personality_diff_summary
      [
        ("will", nick0cave_will, nick0cave_will);
        ("needs", nick0cave_will, nick0cave_will);
        ("desires", nick0cave_will, nick0cave_will);
      ]
  in
  Alcotest.(check (list string))
    "diff summary is empty for byte-identical oversized fields"
    []
    entries

let test_diff_summary_reports_normalised_lengths () =
  (* When a real change is detected, the reported [cur=N,tgt=M] pair
     uses normalised byte lengths so the operator sees the values the
     prompt actually rendered.  Pin that contract so future diagnostic
     formatting changes are intentional. *)
  let modified =
    "X구현 가능성이 보이면 바로 손을 댄다. 아직 안 만든 것은 핑계가 아니라 \
     대기열이다. 생각만 있는 상태를 오래 두지 않는다. 논쟁이 붙으면 가능한 한 \
     지지 않으려 하고, 말이 아니라 구현 증거로 뒤집는 쪽을 선호한다. 아니라면 \
     아니라고 말하고, 그 근거까지 가져온다."
  in
  let entries =
    KR.personality_diff_summary [ ("will", nick0cave_will, modified) ]
  in
  match entries with
  | [ entry ] ->
    let max_len = string_of_int KC.prompt_render_max_bytes in
    let contains needle =
      let nlen = String.length needle in
      let elen = String.length entry in
      let rec loop i =
        if i + nlen > elen then false
        else if String.sub entry i nlen = needle then true
        else loop (i + 1)
      in
      loop 0
    in
    Alcotest.(check bool)
      (Printf.sprintf
         "diff entry must report normalised lengths (<= %s) — got: %s"
         max_len entry)
      true
      (contains "will(cur=" && contains ",tgt=" && contains ",diff@")
  | other ->
    Alcotest.failf
      "expected exactly one diff entry, got %d entries"
      (List.length other)

let () =
  Alcotest.run "keeper_personality_round_trip"
    [
      ( "drift-loop-invariants",
        [
          Alcotest.test_case "oversized identical compares equal"
            `Quick test_oversized_identical_is_equal;
          Alcotest.test_case "oversized real diff still detected"
            `Quick test_oversized_real_diff_still_detected;
          Alcotest.test_case "oversized + trailing whitespace equal"
            `Quick test_oversized_with_trailing_whitespace_is_equal;
          Alcotest.test_case "unicode trailing whitespace equal (#10552)"
            `Quick test_unicode_trailing_whitespace_is_equal;
          Alcotest.test_case "diff_summary empty for identical oversized"
            `Quick test_diff_summary_is_empty_for_identical_oversized;
          Alcotest.test_case "diff_summary reports normalised lengths"
            `Quick test_diff_summary_reports_normalised_lengths;
        ] );
    ]
