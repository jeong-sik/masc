(** Gen12: verify [truncate_string] primitive used at checkpoint load.

    Gen8 caps social_state at the write side (to_social_state). Gen12
    reuses the same primitive in Keeper_types.parse_keeper_state so
    pre-Gen8 checkpoints with unbounded [last_active_desire],
    [last_current_intention], [last_blocker], [last_need] are trimmed
    when loaded back into meta.runtime. This test locks the primitive
    so the load path and write path cannot drift. *)

module T = Masc_mcp.Keeper_social_model_types

let long n = String.make n 'x'

let test_truncate_long () =
  let result = T.truncate_string ~max_chars:100 (long 1000) in
  Alcotest.(check bool) "within budget + ellipsis"
    true (String.length result <= 103);
  Alcotest.(check bool) "grew beyond raw cap by ellipsis only"
    true (String.length result > 100)

let test_truncate_short_unchanged () =
  let result = T.truncate_string ~max_chars:100 "ok" in
  Alcotest.(check string) "short passes through" "ok" result

let test_truncate_at_exact_boundary () =
  let s = long 100 in
  let result = T.truncate_string ~max_chars:100 s in
  Alcotest.(check string) "exactly at cap passes through" s result

let test_truncate_idempotent () =
  let s = long 1000 in
  let once = T.truncate_string ~max_chars:100 s in
  let twice = T.truncate_string ~max_chars:100 once in
  Alcotest.(check string) "second application is noop" once twice

let test_truncate_matches_default_option_budget () =
  (* Gen12 load path uses T.default_option_field_max_chars. If Gen8
     defaults change, this test proves the primitive still behaves. *)
  let cap = T.default_option_field_max_chars in
  let s = long (cap * 10) in
  let result = T.truncate_string ~max_chars:cap s in
  Alcotest.(check bool) "load-path default budget honoured"
    true (String.length result <= cap + 3)

let () =
  Alcotest.run "social_state_cap_on_load"
    [ ( "truncate_string",
        [ Alcotest.test_case "truncates long string with ellipsis" `Quick
            test_truncate_long;
          Alcotest.test_case "short string unchanged" `Quick
            test_truncate_short_unchanged;
          Alcotest.test_case "exact boundary unchanged" `Quick
            test_truncate_at_exact_boundary;
          Alcotest.test_case "truncation is idempotent" `Quick
            test_truncate_idempotent;
          Alcotest.test_case "matches Gen8 default option budget" `Quick
            test_truncate_matches_default_option_budget;
        ] );
    ]
