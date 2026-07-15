(** Behavioural pin for [Text_token_estimate.estimate_char_tokens]
    (masc#24391 crossover): the estimator was recovered verbatim from the
    retired oas [Text_estimate] (902c45d2) when OAS 0.212.0 dropped it,
    and these vectors are the module's own upstream tests, preserved so
    the recovered semantics cannot drift silently. *)

open Alcotest

let est = Text_token_estimate.estimate_char_tokens

let test_vectors () =
  check int "empty string returns 1" 1 (est "");
  check int "pure ASCII rounds up per 4 chars (11 chars)" 3 (est "hello world");
  check int "pure Hangul 5 chars ~ 2/3 token each" 4
    (est "\xEC\x95\x88\xEB\x85\x95\xED\x95\x98\xEC\x84\xB8\xEC\x9A\x94");
  check int "mixed ASCII + Hangul" 4 (est "hello \xEC\x95\x88\xEB\x85\x95");
  check int "two 4-byte emoji" 2 (est "\xF0\x9F\x98\x80\xF0\x9F\x98\x80");
  check bool "single ASCII char is at least 1" true (est "a" >= 1)

let () =
  run "text_token_estimate"
    [ ("estimate_char_tokens", [ test_case "upstream vectors" `Quick test_vectors ]) ]
