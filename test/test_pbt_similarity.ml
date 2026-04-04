(** Property-based and unit tests for proactive similarity scoring.

    Covers similarity_tokens, jaccard_similarity, and
    proactive_similarity_score from Keeper_types_profile. *)

module P = Masc_mcp.Keeper_types_profile

(* ── Generators ── *)

let gen_word =
  QCheck.Gen.(
    let* len = int_range 1 10 in
    let* chars = list_size (return len) (char_range 'a' 'z') in
    return (String.init len (fun i -> List.nth chars i)))

let gen_text =
  QCheck.Gen.(
    let* words = list_size (int_range 0 12) gen_word in
    return (String.concat " " words))

let arb_text = QCheck.make gen_text ~print:Fun.id

(* ── PBT Properties ── *)

(* similarity_tokens never returns empty-string tokens *)
let prop_tokens_no_empty =
  QCheck.Test.make ~count:500 ~name:"tokens contain no empty strings"
    arb_text
    (fun text ->
       let tokens = P.similarity_tokens text in
       List.for_all (fun t -> String.length t >= 2) tokens)

(* similarity_tokens is deterministic *)
let prop_tokens_deterministic =
  QCheck.Test.make ~count:500 ~name:"tokens are deterministic"
    arb_text
    (fun text ->
       let a = P.similarity_tokens text in
       let b = P.similarity_tokens text in
       a = b)

(* jaccard(A, A) = 1.0 for non-empty *)
let prop_jaccard_self =
  QCheck.Test.make ~count:500 ~name:"jaccard(A,A) = 1.0"
    arb_text
    (fun text ->
       let tokens = P.similarity_tokens text in
       if tokens = [] then true
       else P.jaccard_similarity tokens tokens = 1.0)

(* jaccard is symmetric *)
let prop_jaccard_symmetric =
  QCheck.Test.make ~count:500 ~name:"jaccard is symmetric"
    (QCheck.pair arb_text arb_text)
    (fun (a, b) ->
       let ta = P.similarity_tokens a in
       let tb = P.similarity_tokens b in
       P.jaccard_similarity ta tb = P.jaccard_similarity tb ta)

(* jaccard is in [0, 1] *)
let prop_jaccard_range =
  QCheck.Test.make ~count:500 ~name:"jaccard in [0,1]"
    (QCheck.pair arb_text arb_text)
    (fun (a, b) ->
       let ta = P.similarity_tokens a in
       let tb = P.similarity_tokens b in
       let score = P.jaccard_similarity ta tb in
       score >= 0.0 && score <= 1.0)

(* proactive_similarity_score is symmetric *)
let prop_score_symmetric =
  QCheck.Test.make ~count:500 ~name:"similarity_score is symmetric"
    (QCheck.pair arb_text arb_text)
    (fun (a, b) ->
       P.proactive_similarity_score ~candidate:a ~previous:b
       = P.proactive_similarity_score ~candidate:b ~previous:a)

(* ── Unit tests ── *)

open Alcotest

let test_tokens_basic () =
  check (list string) "simple words"
    ["hello"; "world"]
    (P.similarity_tokens "Hello, World!")

let test_tokens_consecutive_spaces () =
  check (list string) "consecutive spaces collapsed"
    ["hello"; "world"]
    (P.similarity_tokens "hello    world")

let test_tokens_short_filtered () =
  check (list string) "single chars filtered out"
    ["ab"; "cd"]
    (P.similarity_tokens "a ab b cd c")

let test_tokens_empty () =
  check (list string) "empty input"
    []
    (P.similarity_tokens "")

let test_tokens_only_punctuation () =
  check (list string) "only punctuation"
    []
    (P.similarity_tokens "!@#$%")

let test_jaccard_identical () =
  check (float 0.001) "identical lists"
    1.0
    (P.jaccard_similarity ["aa"; "bb"; "cc"] ["aa"; "bb"; "cc"])

let test_jaccard_disjoint () =
  check (float 0.001) "disjoint lists"
    0.0
    (P.jaccard_similarity ["aa"; "bb"] ["cc"; "dd"])

let test_jaccard_partial () =
  (* {aa,bb} ∩ {bb,cc} = {bb}, union = {aa,bb,cc} → 1/3 *)
  check (float 0.001) "partial overlap"
    (1.0 /. 3.0)
    (P.jaccard_similarity ["aa"; "bb"] ["bb"; "cc"])

let test_jaccard_both_empty () =
  check (float 0.001) "both empty"
    1.0
    (P.jaccard_similarity [] [])

let test_jaccard_one_empty () =
  check (float 0.001) "one empty"
    0.0
    (P.jaccard_similarity ["aa"] [])

let test_jaccard_duplicates () =
  check (float 0.001) "duplicates in input"
    1.0
    (P.jaccard_similarity ["aa"; "aa"; "bb"] ["aa"; "bb"; "bb"])

let test_score_identical_text () =
  let s = P.proactive_similarity_score
    ~candidate:"hello world test" ~previous:"hello world test" in
  check (float 0.001) "identical text" 1.0 s

let test_score_completely_different () =
  let s = P.proactive_similarity_score
    ~candidate:"alpha beta gamma" ~previous:"delta epsilon zeta" in
  check (float 0.001) "completely different" 0.0 s

let () =
  let pbt_suite =
    List.map QCheck_alcotest.to_alcotest
      [ prop_tokens_no_empty;
        prop_tokens_deterministic;
        prop_jaccard_self;
        prop_jaccard_symmetric;
        prop_jaccard_range;
        prop_score_symmetric ]
  in
  Alcotest.run "pbt_similarity"
    [ ("properties", pbt_suite);
      ("similarity_tokens",
       [ test_case "basic" `Quick test_tokens_basic;
         test_case "consecutive spaces" `Quick test_tokens_consecutive_spaces;
         test_case "short filtered" `Quick test_tokens_short_filtered;
         test_case "empty" `Quick test_tokens_empty;
         test_case "only punctuation" `Quick test_tokens_only_punctuation ]);
      ("jaccard_similarity",
       [ test_case "identical" `Quick test_jaccard_identical;
         test_case "disjoint" `Quick test_jaccard_disjoint;
         test_case "partial overlap" `Quick test_jaccard_partial;
         test_case "both empty" `Quick test_jaccard_both_empty;
         test_case "one empty" `Quick test_jaccard_one_empty;
         test_case "duplicates" `Quick test_jaccard_duplicates ]);
      ("proactive_similarity_score",
       [ test_case "identical text" `Quick test_score_identical_text;
         test_case "completely different" `Quick test_score_completely_different ]) ]
