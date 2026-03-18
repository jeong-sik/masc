(** Tests for Trpg_actor_match — Actor-Keeper Compatibility Scoring. *)

open Masc_mcp

let eps = 1e-6

let float_eq a b = Float.abs (a -. b) < eps

let check_float msg expected actual =
  Alcotest.(check bool)
    (Printf.sprintf "%s: expected %.4f got %.4f" msg expected actual)
    true (float_eq expected actual)

(* ---------- tokenize ---------- *)

let test_tokenize_basic () =
  let tokens = Trpg_actor_match.tokenize "The brave warrior fights" in
  (* "the" is a stop word, single-char filtered *)
  Alcotest.(check bool) "contains brave" true (List.mem "brave" tokens);
  Alcotest.(check bool) "contains warrior" true (List.mem "warrior" tokens);
  Alcotest.(check bool) "contains fights" true (List.mem "fights" tokens);
  Alcotest.(check bool) "no stop word 'the'" false (List.mem "the" tokens)

let test_tokenize_punctuation () =
  let tokens = Trpg_actor_match.tokenize "fire-breathing,dragon;slayer" in
  Alcotest.(check bool) "fire" true (List.mem "fire" tokens);
  Alcotest.(check bool) "breathing" true (List.mem "breathing" tokens);
  Alcotest.(check bool) "dragon" true (List.mem "dragon" tokens);
  Alcotest.(check bool) "slayer" true (List.mem "slayer" tokens)

let test_tokenize_empty () =
  let tokens = Trpg_actor_match.tokenize "" in
  Alcotest.(check int) "empty input" 0 (List.length tokens)

let test_tokenize_dedup () =
  let tokens = Trpg_actor_match.tokenize "brave brave brave" in
  Alcotest.(check int) "deduped to 1" 1 (List.length tokens)

(* ---------- trait_overlap_score ---------- *)

let test_trait_overlap_both_empty () =
  let s = Trpg_actor_match.trait_overlap_score [] [] in
  check_float "both empty -> 0.5" 0.5 s

let test_trait_overlap_identical () =
  let s =
    Trpg_actor_match.trait_overlap_score [ "brave"; "wise" ] [ "brave"; "wise" ]
  in
  check_float "identical -> 1.0" 1.0 s

let test_trait_overlap_disjoint () =
  let s =
    Trpg_actor_match.trait_overlap_score [ "brave" ] [ "cunning" ]
  in
  check_float "disjoint -> 0.0" 0.0 s

let test_trait_overlap_partial () =
  (* {brave, wise} ∩ {brave, cunning} = {brave}, union = 3 *)
  let s =
    Trpg_actor_match.trait_overlap_score
      [ "brave"; "wise" ] [ "brave"; "cunning" ]
  in
  check_float "partial -> 1/3" (1.0 /. 3.0) s

let test_trait_overlap_case_insensitive () =
  let s =
    Trpg_actor_match.trait_overlap_score [ "BRAVE" ] [ "brave" ]
  in
  check_float "case insensitive -> 1.0" 1.0 s

(* ---------- archetype_affinity_score ---------- *)

let test_archetype_known_pair () =
  let s = Trpg_actor_match.archetype_affinity_score "analytical" "wizard" in
  check_float "analytical+wizard -> 0.9" 0.9 s

let test_archetype_unknown_pair () =
  let s = Trpg_actor_match.archetype_affinity_score "mysterious" "ranger" in
  check_float "unknown pair -> 0.5" 0.5 s

let test_archetype_case_insensitive () =
  let s = Trpg_actor_match.archetype_affinity_score "CREATIVE" "Bard" in
  check_float "case insensitive -> 0.9" 0.9 s

(* ---------- semantic_alignment_score ---------- *)

let test_semantic_both_empty () =
  let s = Trpg_actor_match.semantic_alignment_score "" "" in
  check_float "both empty -> 0.0" 0.0 s

let test_semantic_identical () =
  let s =
    Trpg_actor_match.semantic_alignment_score
      "brave warrior fights evil"
      "brave warrior fights evil"
  in
  check_float "identical -> 1.0" 1.0 s

let test_semantic_partial () =
  let s =
    Trpg_actor_match.semantic_alignment_score
      "brave warrior"
      "brave wizard scholar"
  in
  (* words_a = [brave; warrior], words_b = [brave; wizard; scholar]
     common = 1 (brave), max_len = 3 → 1/3 *)
  check_float "partial -> 1/3" (1.0 /. 3.0) s

(* ---------- score ---------- *)

let test_score_basic () =
  let ms =
    Trpg_actor_match.score
      ~keeper_name:"alice"
      ~keeper_style:"analytical"
      ~keeper_description:"wise scholarly researcher"
      ~actor_id:"actor-1"
      ~actor_archetype:"wizard"
      ~actor_traits:[ "wise"; "scholarly" ]
      ~actor_persona:"A wise wizard who studies ancient tomes"
  in
  Alcotest.(check string) "keeper_name" "alice" ms.keeper_name;
  Alcotest.(check string) "actor_id" "actor-1" ms.actor_id;
  (* archetype_affinity = 0.9 (analytical + wizard) *)
  check_float "archetype" 0.9 ms.archetype_affinity;
  (* total should be in valid range *)
  Alcotest.(check bool) "total >= 0" true (ms.total >= 0.0);
  Alcotest.(check bool) "total <= 1" true (ms.total <= 1.0)

(* ---------- rank ---------- *)

let test_rank_order () =
  let keepers =
    [
      ("alice", "analytical", "wise scholarly researcher");
      ("bob", "chaotic", "random prankster");
    ]
  in
  let results =
    Trpg_actor_match.rank ~keepers ~actor_id:"actor-1"
      ~actor_archetype:"wizard" ~actor_traits:[ "wise" ]
      ~actor_persona:"A wise wizard"
  in
  Alcotest.(check int) "2 results" 2 (List.length results);
  let first = List.hd results in
  let second = List.nth results 1 in
  Alcotest.(check bool) "sorted desc" true (first.total >= second.total);
  (* analytical + wizard = 0.9 should beat chaotic + wizard = 0.5 *)
  Alcotest.(check string) "best is alice" "alice" first.keeper_name

let test_rank_empty_keepers () =
  let results =
    Trpg_actor_match.rank ~keepers:[] ~actor_id:"actor-1"
      ~actor_archetype:"wizard" ~actor_traits:[] ~actor_persona:""
  in
  Alcotest.(check int) "empty keepers -> empty results" 0 (List.length results)

(* ---------- best_match ---------- *)

let test_best_match_some () =
  let keepers = [ ("alice", "analytical", "wise researcher") ] in
  let result =
    Trpg_actor_match.best_match ~keepers ~actor_id:"a1"
      ~actor_archetype:"wizard" ~actor_traits:[] ~actor_persona:""
  in
  Alcotest.(check bool) "Some" true (Option.is_some result);
  let ms = Option.get result in
  Alcotest.(check string) "keeper" "alice" ms.keeper_name

let test_best_match_none () =
  let result =
    Trpg_actor_match.best_match ~keepers:[] ~actor_id:"a1"
      ~actor_archetype:"wizard" ~actor_traits:[] ~actor_persona:""
  in
  Alcotest.(check bool) "None" true (Option.is_none result)

(* ---------- JSON serialization ---------- *)

let test_to_yojson () =
  let ms =
    Trpg_actor_match.score
      ~keeper_name:"alice" ~keeper_style:"analytical"
      ~keeper_description:"wise" ~actor_id:"a1"
      ~actor_archetype:"wizard" ~actor_traits:[] ~actor_persona:""
  in
  let json = Trpg_actor_match.to_yojson ms in
  let s = Yojson.Safe.to_string json in
  Alcotest.(check bool) "contains keeperName" true
    (String.length s > 0
    && Yojson.Safe.Util.member "keeperName" json = `String "alice");
  Alcotest.(check bool) "contains actorId" true
    (Yojson.Safe.Util.member "actorId" json = `String "a1")

let test_ranking_to_yojson () =
  let ms1 =
    Trpg_actor_match.score
      ~keeper_name:"alice" ~keeper_style:"analytical"
      ~keeper_description:"" ~actor_id:"a1"
      ~actor_archetype:"wizard" ~actor_traits:[] ~actor_persona:""
  in
  let json = Trpg_actor_match.ranking_to_yojson [ ms1 ] in
  match json with
  | `List [ _ ] -> ()  (* ok, single element *)
  | _ -> Alcotest.fail "expected JSON array with 1 element"

(* ---------- Test runner ---------- *)

let () =
  Alcotest.run "Trpg_actor_match"
    [
      ( "tokenize",
        [
          Alcotest.test_case "basic" `Quick test_tokenize_basic;
          Alcotest.test_case "punctuation" `Quick test_tokenize_punctuation;
          Alcotest.test_case "empty" `Quick test_tokenize_empty;
          Alcotest.test_case "dedup" `Quick test_tokenize_dedup;
        ] );
      ( "trait_overlap",
        [
          Alcotest.test_case "both empty" `Quick test_trait_overlap_both_empty;
          Alcotest.test_case "identical" `Quick test_trait_overlap_identical;
          Alcotest.test_case "disjoint" `Quick test_trait_overlap_disjoint;
          Alcotest.test_case "partial" `Quick test_trait_overlap_partial;
          Alcotest.test_case "case insensitive" `Quick
            test_trait_overlap_case_insensitive;
        ] );
      ( "archetype_affinity",
        [
          Alcotest.test_case "known pair" `Quick test_archetype_known_pair;
          Alcotest.test_case "unknown pair" `Quick test_archetype_unknown_pair;
          Alcotest.test_case "case insensitive" `Quick
            test_archetype_case_insensitive;
        ] );
      ( "semantic_alignment",
        [
          Alcotest.test_case "both empty" `Quick test_semantic_both_empty;
          Alcotest.test_case "identical" `Quick test_semantic_identical;
          Alcotest.test_case "partial" `Quick test_semantic_partial;
        ] );
      ( "score",
        [
          Alcotest.test_case "basic" `Quick test_score_basic;
        ] );
      ( "rank",
        [
          Alcotest.test_case "order" `Quick test_rank_order;
          Alcotest.test_case "empty keepers" `Quick test_rank_empty_keepers;
        ] );
      ( "best_match",
        [
          Alcotest.test_case "some" `Quick test_best_match_some;
          Alcotest.test_case "none" `Quick test_best_match_none;
        ] );
      ( "json",
        [
          Alcotest.test_case "to_yojson" `Quick test_to_yojson;
          Alcotest.test_case "ranking_to_yojson" `Quick
            test_ranking_to_yojson;
        ] );
    ]
