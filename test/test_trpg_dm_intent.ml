open Masc_mcp

let with_env key value f =
  let old = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match old with
      | Some prev -> Unix.putenv key prev
      | None -> Unix.putenv key "")
    f

let with_keyword_mode f =
  with_env "MASC_TRPG_DM_INTENT_MODE" "keyword" f

(* ==== Keyword extraction tests (default mode) ============================ *)

let test_combat () =
  with_keyword_mode (fun () ->
      let intent =
        Trpg_dm_intent.extract
          "The goblins draw their swords and charge! A battle begins as the monsters attack."
      in
      let cat = Trpg_dm_intent.string_of_category intent.primary in
      Alcotest.(check string) "combat detected" "combat_setup" cat;
      Alcotest.(check bool) "confidence > 0" true (intent.confidence > 0.0);
      Alcotest.(check bool) "keywords non-empty" true
        (List.length intent.keywords_matched > 0);
      Alcotest.(check bool) "mode set" true (String.length intent.mode > 0);
      Alcotest.(check bool) "provenance set" true
        (String.length intent.provenance > 0))

let test_social () =
  with_keyword_mode (fun () ->
      let intent =
        Trpg_dm_intent.extract
          "The merchant greets you at the tavern and says: I have an offer for a trade."
      in
      let cat = Trpg_dm_intent.string_of_category intent.primary in
      Alcotest.(check string) "social detected" "social_encounter" cat)

let test_puzzle () =
  with_keyword_mode (fun () ->
      let intent =
        Trpg_dm_intent.extract
          "You find a locked chest with strange runes. A riddle is inscribed."
      in
      let cat = Trpg_dm_intent.string_of_category intent.primary in
      Alcotest.(check string) "puzzle detected" "puzzle_challenge" cat)

let test_exploration () =
  with_keyword_mode (fun () ->
      let intent =
        Trpg_dm_intent.extract
          "You travel through the dense forest, discovering ancient ruins ahead."
      in
      let cat = Trpg_dm_intent.string_of_category intent.primary in
      Alcotest.(check string) "exploration detected" "exploration" cat)

let test_rest () =
  with_keyword_mode (fun () ->
      let intent =
        Trpg_dm_intent.extract "The party sets up camp for the night to rest and heal."
      in
      let cat = Trpg_dm_intent.string_of_category intent.primary in
      Alcotest.(check string) "rest detected" "rest_downtime" cat)

let test_tension () =
  with_keyword_mode (fun () ->
      let intent =
        Trpg_dm_intent.extract
          "An ominous shadow looms overhead. Something watches from the darkness."
      in
      let cat = Trpg_dm_intent.string_of_category intent.primary in
      Alcotest.(check string) "tension detected" "tension_building" cat)

let test_unknown () =
  with_keyword_mode (fun () ->
      let intent = Trpg_dm_intent.extract "Hello world, nothing specific here." in
      let cat = Trpg_dm_intent.string_of_category intent.primary in
      (* Could be unknown or low-confidence match *)
      Alcotest.(check bool) "some category returned" true (String.length cat > 0))

(* ==== Serialization tests ================================================ *)

let test_to_hint () =
  with_keyword_mode (fun () ->
      let intent = Trpg_dm_intent.extract "Monsters appear! Roll initiative!" in
      let hint = Trpg_dm_intent.to_hint intent in
      Alcotest.(check bool) "hint non-empty" true (String.length hint > 0))

let test_to_yojson () =
  with_keyword_mode (fun () ->
      let intent = Trpg_dm_intent.extract "The king reveals the secret prophecy." in
      let json = Trpg_dm_intent.to_yojson intent in
      match json with
      | `Assoc fields ->
        Alcotest.(check bool) "has primary field" true
          (List.mem_assoc "primary" fields);
        Alcotest.(check bool) "has confidence field" true
          (List.mem_assoc "confidence" fields);
        Alcotest.(check bool) "has keywords_matched field" true
          (List.mem_assoc "keywords_matched" fields);
        Alcotest.(check bool) "has mode field" true
          (List.mem_assoc "mode" fields);
        Alcotest.(check bool) "has provenance field" true
          (List.mem_assoc "provenance" fields)
      | _ -> Alcotest.fail "to_yojson should return Assoc")

(* ==== category_of_string tests =========================================== *)

let test_category_of_string () =
  let open Trpg_dm_intent in
  Alcotest.(check string) "combat_setup"
    "combat_setup" (string_of_category (category_of_string "combat_setup"));
  Alcotest.(check string) "combat alias"
    "combat_setup" (string_of_category (category_of_string "combat"));
  Alcotest.(check string) "social_encounter"
    "social_encounter" (string_of_category (category_of_string "social_encounter"));
  Alcotest.(check string) "social alias"
    "social_encounter" (string_of_category (category_of_string "Social"));
  Alcotest.(check string) "puzzle_challenge"
    "puzzle_challenge" (string_of_category (category_of_string "puzzle"));
  Alcotest.(check string) "exploration"
    "exploration" (string_of_category (category_of_string "Exploration"));
  Alcotest.(check string) "rest_downtime"
    "rest_downtime" (string_of_category (category_of_string "rest"));
  Alcotest.(check string) "plot_reveal"
    "plot_reveal" (string_of_category (category_of_string "plot_reveal"));
  Alcotest.(check string) "tension_building"
    "tension_building" (string_of_category (category_of_string "tension"));
  Alcotest.(check string) "unknown fallback"
    "unknown" (string_of_category (category_of_string "nonsense"))

(* ==== parse_llm_intent tests ============================================= *)

let test_parse_clean_json () =
  let json_str =
    {|{"primary":"combat_setup","secondary":"tension_building","confidence":0.85,"keywords":["sword","monster"]}|}
  in
  match Trpg_dm_intent.parse_llm_intent json_str with
  | Ok intent ->
      Alcotest.(check string) "primary" "combat_setup"
        (Trpg_dm_intent.string_of_category intent.primary);
      (match intent.secondary with
       | Some cat ->
           Alcotest.(check string) "secondary" "tension_building"
             (Trpg_dm_intent.string_of_category cat)
       | None -> Alcotest.fail "expected secondary");
      Alcotest.(check bool) "confidence" true (intent.confidence > 0.8);
      Alcotest.(check int) "keywords count" 2 (List.length intent.keywords_matched)
  | Error e -> Alcotest.fail (Printf.sprintf "parse failed: %s" e)

let test_parse_embedded_json () =
  let response =
    {|Here is the classification:
{"primary":"exploration","secondary":null,"confidence":0.7,"keywords":["travel","forest"]}
Hope this helps!|}
  in
  match Trpg_dm_intent.parse_llm_intent response with
  | Ok intent ->
      Alcotest.(check string) "primary" "exploration"
        (Trpg_dm_intent.string_of_category intent.primary);
      Alcotest.(check bool) "no secondary" true
        (intent.secondary = None);
      Alcotest.(check bool) "confidence" true
        (intent.confidence >= 0.6 && intent.confidence <= 0.8)
  | Error e -> Alcotest.fail (Printf.sprintf "parse failed: %s" e)

let test_parse_null_secondary () =
  let json_str =
    {|{"primary":"social_encounter","secondary":null,"confidence":0.9,"keywords":["merchant","tavern"]}|}
  in
  match Trpg_dm_intent.parse_llm_intent json_str with
  | Ok intent ->
      Alcotest.(check string) "primary" "social_encounter"
        (Trpg_dm_intent.string_of_category intent.primary);
      Alcotest.(check bool) "no secondary" true (intent.secondary = None)
  | Error e -> Alcotest.fail (Printf.sprintf "parse failed: %s" e)

let test_parse_same_secondary_filtered () =
  (* secondary = primary should be filtered to None *)
  let json_str =
    {|{"primary":"combat_setup","secondary":"combat_setup","confidence":0.8,"keywords":["fight"]}|}
  in
  match Trpg_dm_intent.parse_llm_intent json_str with
  | Ok intent ->
      Alcotest.(check bool) "secondary filtered" true (intent.secondary = None)
  | Error e -> Alcotest.fail (Printf.sprintf "parse failed: %s" e)

let test_parse_confidence_clamped () =
  let json_str =
    {|{"primary":"plot_reveal","secondary":null,"confidence":1.5,"keywords":[]}|}
  in
  match Trpg_dm_intent.parse_llm_intent json_str with
  | Ok intent ->
      Alcotest.(check bool) "confidence clamped to 1.0" true
        (intent.confidence <= 1.0)
  | Error e -> Alcotest.fail (Printf.sprintf "parse failed: %s" e)

let test_parse_invalid () =
  match Trpg_dm_intent.parse_llm_intent "not json at all" with
  | Error _ -> () (* expected *)
  | Ok _ -> Alcotest.fail "should have failed on invalid input"

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
      ( "category_of_string",
        [
          Alcotest.test_case "round-trip" `Quick test_category_of_string;
        ] );
      ( "parse_llm_intent",
        [
          Alcotest.test_case "clean json" `Quick test_parse_clean_json;
          Alcotest.test_case "embedded json" `Quick test_parse_embedded_json;
          Alcotest.test_case "null secondary" `Quick test_parse_null_secondary;
          Alcotest.test_case "same secondary filtered" `Quick test_parse_same_secondary_filtered;
          Alcotest.test_case "confidence clamped" `Quick test_parse_confidence_clamped;
          Alcotest.test_case "invalid input" `Quick test_parse_invalid;
        ] );
    ]
