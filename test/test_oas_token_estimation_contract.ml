(** OAS canonical token-estimator contract for the tool-schema budget gauge
    (masc axis-1b — under-wired OAS consumption).

    [lib/mcp_server_eio.ml] reports the tool-schema budget (#7483 Step 1) through
    the OAS Context_reducer facade
    ([Keeper_context_core_accessors.estimate_char_tokens], which delegates to
    [Agent_sdk.Context_reducer.estimate_char_tokens]) instead of a hand-rolled
    byte-length/4 heuristic — a third ad-hoc copy of token math the MASC facade
    designates OAS as the SSOT for.

    These tests pin the canonical estimator's char-classified contract that the
    gauge now consumes, and show it is distinct from byte/4. A silent revert to
    the ad-hoc heuristic, or an OAS change to the estimator, surfaces here
    instead of drifting the emitted gauge value silently. They assert the
    estimator contract, not a direction of "correctness" against byte/4. *)

open Alcotest

let est = Agent_sdk.Context_reducer.estimate_char_tokens
let byte_over_4 s = String.length s / 4

(* Canonical contract values, mirroring OAS text_estimate inline tests:
   ASCII ~4 chars/token, multi-byte ~2/3 token/char, min 1 (no zero downstream).
   CJK/emoji written as UTF-8 escapes for byte-exactness:
   "\xEC\x95\x88\xEB\x85\x95\xED\x95\x98\xEC\x84\xB8\xEC\x9A\x94" = 안녕하세요 (5 Hangul)
   "\xF0\x9F\x98\x80\xF0\x9F\x98\x80" = 😀😀 (two 4-byte emoji) *)
let test_canonical_contract () =
  check int "empty -> 1" 1 (est "");
  check int "ascii 'hello world' -> ceil(11/4) = 3" 3 (est "hello world");
  check int "100 ascii 'x' -> 25" 25 (est (String.make 100 'x'));
  check int "5 Hangul -> (5*2+2)/3 = 4" 4
    (est "\xEC\x95\x88\xEB\x85\x95\xED\x95\x98\xEC\x84\xB8\xEC\x9A\x94");
  check int "two 4-byte emoji -> 2" 2 (est "\xF0\x9F\x98\x80\xF0\x9F\x98\x80")

(* Non-vacuous: the char-classified estimator is not byte-length/4 for CJK
   content, so routing the gauge through it changes the reported value. We pin
   that they differ, not which one is "more correct". 40 Hangul "한" (EC->ED 95 9C):
   byte/4 = 120/4 = 30; estimator = (40*2+2)/3 = 27. *)
let test_differs_from_byte_over_4_on_cjk () =
  let cjk = String.concat "" (List.init 40 (fun _ -> "\xED\x95\x9C")) in
  check bool "canonical estimate differs from byte/4 on CJK-heavy text" true
    (est cjk <> byte_over_4 cjk)

let () =
  run "oas_token_estimation_contract"
    [ ( "contract"
      , [ test_case "canonical estimator contract" `Quick test_canonical_contract
        ; test_case "distinct from byte/4 on CJK" `Quick
            test_differs_from_byte_over_4_on_cjk
        ] )
    ]
