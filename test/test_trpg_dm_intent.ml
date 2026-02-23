open Masc_mcp

(* ---- combat keywords ---- *)
let test_combat () =
  let intent =
    Trpg_dm_intent.extract
      "The goblins draw their swords and charge! A battle begins as the monsters attack."
  in
  let cat = Trpg_dm_intent.string_of_category intent.primary in
  Alcotest.(check string) "combat detected" "combat_setup" cat;
  Alcotest.(check bool) "confidence > 0" true (intent.confidence > 0.0);
  Alcotest.(check bool) "keywords non-empty" true
    (List.length intent.keywords_matched > 0)

(* ---- social encounter ---- *)
let test_social () =
  let intent =
    Trpg_dm_intent.extract
      "The merchant greets you at the tavern and says: I have an offer for a trade."
  in
  let cat = Trpg_dm_intent.string_of_category intent.primary in
  Alcotest.(check string) "social detected" "social_encounter" cat

(* ---- puzzle challenge ---- *)
let test_puzzle () =
  let intent =
    Trpg_dm_intent.extract
      "You find a locked chest with strange runes. A riddle is inscribed."
  in
  let cat = Trpg_dm_intent.string_of_category intent.primary in
  Alcotest.(check string) "puzzle detected" "puzzle_challenge" cat

(* ---- exploration ---- *)
let test_exploration () =
  let intent =
    Trpg_dm_intent.extract
      "You travel through the dense forest, discovering ancient ruins ahead."
  in
  let cat = Trpg_dm_intent.string_of_category intent.primary in
  Alcotest.(check string) "exploration detected" "exploration" cat

(* ---- rest/downtime ---- *)
let test_rest () =
  let intent =
    Trpg_dm_intent.extract "The party sets up camp for the night to rest and heal."
  in
  let cat = Trpg_dm_intent.string_of_category intent.primary in
  Alcotest.(check string) "rest detected" "rest_downtime" cat

(* ---- tension building ---- *)
let test_tension () =
  let intent =
    Trpg_dm_intent.extract
      "An ominous shadow looms overhead. Something watches from the darkness."
  in
  let cat = Trpg_dm_intent.string_of_category intent.primary in
  Alcotest.(check string) "tension detected" "tension_building" cat

(* ---- unknown / no clear intent ---- *)
let test_unknown () =
  let intent = Trpg_dm_intent.extract "Hello world, nothing specific here." in
  let cat = Trpg_dm_intent.string_of_category intent.primary in
  (* Could be unknown or low-confidence match *)
  Alcotest.(check bool) "some category returned" true (String.length cat > 0)

(* ---- to_hint ---- *)
let test_to_hint () =
  let intent = Trpg_dm_intent.extract "Monsters appear! Roll initiative!" in
  let hint = Trpg_dm_intent.to_hint intent in
  Alcotest.(check bool) "hint non-empty" true (String.length hint > 0)

(* ---- to_yojson ---- *)
let test_to_yojson () =
  let intent = Trpg_dm_intent.extract "The king reveals the secret prophecy." in
  let json = Trpg_dm_intent.to_yojson intent in
  match json with
  | `Assoc fields ->
    Alcotest.(check bool) "has primary field" true
      (List.mem_assoc "primary" fields);
    Alcotest.(check bool) "has confidence field" true
      (List.mem_assoc "confidence" fields);
    Alcotest.(check bool) "has keywords_matched field" true
      (List.mem_assoc "keywords_matched" fields)
  | _ -> Alcotest.fail "to_yojson should return Assoc"

let () =
  Alcotest.run "trpg_dm_intent"
    [
      ( "extraction",
        [
          Alcotest.test_case "combat" `Quick test_combat;
          Alcotest.test_case "social" `Quick test_social;
          Alcotest.test_case "puzzle" `Quick test_puzzle;
          Alcotest.test_case "exploration" `Quick test_exploration;
          Alcotest.test_case "rest" `Quick test_rest;
          Alcotest.test_case "tension" `Quick test_tension;
          Alcotest.test_case "unknown" `Quick test_unknown;
        ] );
      ( "serialization",
        [
          Alcotest.test_case "to_hint" `Quick test_to_hint;
          Alcotest.test_case "to_yojson" `Quick test_to_yojson;
        ] );
    ]
