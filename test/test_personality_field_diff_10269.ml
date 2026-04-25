(** #10269: nick0cave personality re-syncs every reconcile cycle (~371
    events / 3000 logs) but the existing log line ["re-syncing
    [personality] for nick0cave"] does not say which of the eight
    personality fields differ or how.  These tests pin the
    [personality_field_diff_summary] helper that the runtime now calls
    after the re-sync log so operators can map the storm to a concrete
    field + length signature. *)

open Alcotest
module Kr = Masc_mcp.Keeper_runtime

let opt_string = option string

let test_trim_equal_returns_none () =
  check opt_string "trailing newline drift collapses"
    None
    (Kr.personality_field_diff_summary
       ~field:"instructions" ~current:"hello\n" ~target:"hello");
  check opt_string "leading whitespace drift collapses"
    None
    (Kr.personality_field_diff_summary
       ~field:"goal" ~current:"  same  " ~target:"same");
  check opt_string "identical strings collapse"
    None
    (Kr.personality_field_diff_summary
       ~field:"will" ~current:"x" ~target:"x")

let test_inner_diff_returns_summary () =
  match
    Kr.personality_field_diff_summary
      ~field:"instructions" ~current:"alpha bravo" ~target:"alpha gamma"
  with
  | None -> fail "expected Some summary for inner content drift"
  | Some s ->
      check bool "summary tags field" true
        (Astring.String.is_prefix ~affix:"instructions(" s);
      check bool "summary exposes meta length" true
        (Astring.String.is_infix ~affix:"raw_meta_len=11" s);
      check bool "summary exposes target length" true
        (Astring.String.is_infix ~affix:"raw_target_len=11" s)

let test_length_drift_returns_summary () =
  match
    Kr.personality_field_diff_summary
      ~field:"goal" ~current:"short" ~target:"a much longer goal text"
  with
  | None -> fail "expected Some summary for length drift"
  | Some s ->
      check bool "asymmetric length is reported" true
        (Astring.String.is_infix ~affix:"raw_meta_len=5" s);
      check bool "asymmetric length is reported" true
        (Astring.String.is_infix ~affix:"raw_target_len=23" s)

let test_long_field_truncates_preview () =
  let long_a = String.make 200 'a' in
  let long_b = String.make 200 'b' in
  match
    Kr.personality_field_diff_summary
      ~field:"instructions" ~current:long_a ~target:long_b
  with
  | None -> fail "expected Some summary"
  | Some s ->
      check bool "ellipsis present for long preview" true
        (Astring.String.is_infix ~affix:"..." s);
      (* Sanity: full 200-char string must NOT appear. *)
      check bool "untruncated preview must not appear" false
        (Astring.String.is_infix ~affix:long_a s)

let () =
  run "personality_field_diff_10269" [
    ("diff_summary", [
        test_case "trim-equal pairs return None" `Quick
          test_trim_equal_returns_none;
        test_case "inner content diff returns Some summary" `Quick
          test_inner_diff_returns_summary;
        test_case "length drift surfaces both raw lengths" `Quick
          test_length_drift_returns_summary;
        test_case "long preview is truncated" `Quick
          test_long_field_truncates_preview;
      ]);
  ]
