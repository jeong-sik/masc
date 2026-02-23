open Masc_mcp

let float_eq ~eps a b = Float.abs (a -. b) < eps

let check_float msg ~eps expected actual =
  Alcotest.(check bool) msg true (float_eq ~eps expected actual)

(* ---- basic score ---- *)
let test_score_basic () =
  let s =
    Trpg_actor_match.score ~keeper_name:"sage" ~keeper_style:"analytical"
      ~keeper_description:"A wise analytical scholar who studies curious ancient tomes"
      ~actor_id:"wizard-1" ~actor_archetype:"wizard"
      ~actor_traits:[ "wise"; "analytical"; "curious" ]
      ~actor_persona:"A wise scholar seeking ancient knowledge"
  in
  (* analytical keeper + wizard archetype -> high affinity (0.9) *)
  check_float "archetype affinity high" ~eps:0.15 0.9 s.archetype_affinity;
  Alcotest.(check bool) "total > 0.5" true (s.total > 0.5);
  Alcotest.(check string) "keeper_name preserved" "sage" s.keeper_name;
  Alcotest.(check string) "actor_id preserved" "wizard-1" s.actor_id

(* ---- trait overlap (Jaccard) ---- *)
let test_trait_overlap () =
  let s =
    Trpg_actor_match.score ~keeper_name:"k" ~keeper_style:"brave"
      ~keeper_description:"A brave and bold warrior"
      ~actor_id:"a" ~actor_archetype:"warrior"
      ~actor_traits:[ "brave"; "strong"; "loyal" ]
      ~actor_persona:"A veteran knight"
  in
  (* "brave" appears in both keeper_description and actor_traits *)
  Alcotest.(check bool) "trait overlap > 0" true (s.trait_overlap > 0.0);
  Alcotest.(check bool) "trait overlap <= 1.0" true (s.trait_overlap <= 1.0)

(* ---- archetype affinity matrix ---- *)
let test_archetype_affinity () =
  (* creative keeper + bard archetype -> 0.9 *)
  let s1 =
    Trpg_actor_match.score ~keeper_name:"k" ~keeper_style:"creative"
      ~keeper_description:"An artist"
      ~actor_id:"a" ~actor_archetype:"bard"
      ~actor_traits:[] ~actor_persona:""
  in
  check_float "creative+bard=0.9" ~eps:0.15 0.9 s1.archetype_affinity;
  (* empathetic keeper + healer archetype -> 0.9 *)
  let s2 =
    Trpg_actor_match.score ~keeper_name:"k" ~keeper_style:"empathetic"
      ~keeper_description:"A caring soul"
      ~actor_id:"a" ~actor_archetype:"healer"
      ~actor_traits:[] ~actor_persona:""
  in
  check_float "empathetic+healer=0.9" ~eps:0.15 0.9 s2.archetype_affinity;
  (* unmatched style + archetype -> 0.5 *)
  let s3 =
    Trpg_actor_match.score ~keeper_name:"k" ~keeper_style:"mysterious"
      ~keeper_description:"enigma"
      ~actor_id:"a" ~actor_archetype:"monk"
      ~actor_traits:[] ~actor_persona:""
  in
  check_float "unmatched=0.5" ~eps:0.15 0.5 s3.archetype_affinity

(* ---- total weight formula ---- *)
let test_total_weight () =
  let s =
    Trpg_actor_match.score ~keeper_name:"k" ~keeper_style:"strategic"
      ~keeper_description:"A tactical commander"
      ~actor_id:"a" ~actor_archetype:"warrior"
      ~actor_traits:[ "tactical"; "strategic" ]
      ~actor_persona:"A battlefield veteran"
  in
  (* total = trait * 0.3 + archetype * 0.4 + semantic * 0.3 *)
  let expected =
    (s.trait_overlap *. 0.3)
    +. (s.archetype_affinity *. 0.4)
    +. (s.semantic_alignment *. 0.3)
  in
  check_float "total follows weight formula" ~eps:0.001 expected s.total

(* ---- rank ordering ---- *)
let test_rank () =
  let keepers =
    [
      ("sage", "analytical", "Scholar of ancient lore");
      ("jester", "chaotic", "Unpredictable trickster");
      ("healer", "empathetic", "Compassionate soul");
    ]
  in
  let ranked =
    Trpg_actor_match.rank ~keepers ~actor_id:"w1" ~actor_archetype:"wizard"
      ~actor_traits:[ "intelligent"; "analytical" ]
      ~actor_persona:"Arcane researcher"
  in
  Alcotest.(check int) "3 scores returned" 3 (List.length ranked);
  (* Verify descending order *)
  let rec is_descending = function
    | [] | [ _ ] -> true
    | a :: (b :: _ as rest) ->
      a.Trpg_actor_match.total >= b.Trpg_actor_match.total && is_descending rest
  in
  Alcotest.(check bool) "descending order" true (is_descending ranked)

(* ---- best_match ---- *)
let test_best_match () =
  let keepers =
    [
      ("sage", "analytical", "Scholar");
      ("jester", "chaotic", "Trickster");
    ]
  in
  let best =
    Trpg_actor_match.best_match ~keepers ~actor_id:"w1"
      ~actor_archetype:"wizard"
      ~actor_traits:[ "analytical" ]
      ~actor_persona:"Scholar"
  in
  (match best with
   | Some s ->
     Alcotest.(check bool) "best has total > 0" true (s.total > 0.0)
   | None -> Alcotest.fail "best_match should return Some for non-empty keepers")

(* ---- best_match with empty keepers ---- *)
let test_best_match_empty () =
  let best =
    Trpg_actor_match.best_match ~keepers:[] ~actor_id:"a"
      ~actor_archetype:"warrior" ~actor_traits:[] ~actor_persona:""
  in
  Alcotest.(check bool) "empty keepers -> None" true (Option.is_none best)

(* ---- to_yojson ---- *)
let test_to_yojson () =
  let s =
    Trpg_actor_match.score ~keeper_name:"k" ~keeper_style:"bold"
      ~keeper_description:"Brave warrior"
      ~actor_id:"a" ~actor_archetype:"warrior"
      ~actor_traits:[ "brave" ] ~actor_persona:"Fighter"
  in
  let json = Trpg_actor_match.to_yojson s in
  match json with
  | `Assoc fields ->
    Alcotest.(check bool) "has keeperName" true
      (List.mem_assoc "keeperName" fields);
    Alcotest.(check bool) "has total" true (List.mem_assoc "total" fields)
  | _ -> Alcotest.fail "to_yojson should return Assoc"

(* ---- ranking_to_yojson ---- *)
let test_ranking_to_yojson () =
  let keepers =
    [ ("a", "analytical", "Scholar"); ("b", "creative", "Artist") ]
  in
  let ranked =
    Trpg_actor_match.rank ~keepers ~actor_id:"x" ~actor_archetype:"bard"
      ~actor_traits:[] ~actor_persona:""
  in
  let json = Trpg_actor_match.ranking_to_yojson ranked in
  match json with
  | `List items ->
    Alcotest.(check int) "2 items in ranking" 2 (List.length items)
  | _ -> Alcotest.fail "ranking_to_yojson should return List"

let () =
  Alcotest.run "trpg_actor_match"
    [
      ( "scoring",
        [
          Alcotest.test_case "basic score" `Quick test_score_basic;
          Alcotest.test_case "trait overlap" `Quick test_trait_overlap;
          Alcotest.test_case "archetype affinity" `Quick
            test_archetype_affinity;
          Alcotest.test_case "total weight formula" `Quick test_total_weight;
        ] );
      ( "ranking",
        [
          Alcotest.test_case "rank ordering" `Quick test_rank;
          Alcotest.test_case "best match" `Quick test_best_match;
          Alcotest.test_case "best match empty" `Quick test_best_match_empty;
        ] );
      ( "serialization",
        [
          Alcotest.test_case "to_yojson" `Quick test_to_yojson;
          Alcotest.test_case "ranking_to_yojson" `Quick test_ranking_to_yojson;
        ] );
    ]
