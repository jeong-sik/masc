(* Nonce fact generation, turn-plan construction, and recall scoring for
   the keeper canary harness (masc, task-11, M1 PR1). Pure logic, no
   network/Eio — see lib/keeper_canary/keeper_canary_facts.ml for the
   module under test. *)

let test_generate_is_deterministic_given_the_same_seed () =
  let a = Keeper_canary_facts.generate ~seed:"run-fixed-A" ~count:9 in
  let b = Keeper_canary_facts.generate ~seed:"run-fixed-A" ~count:9 in
  Alcotest.(check (list string))
    "categories match"
    (List.map (fun (f : Keeper_canary_facts.fact) -> f.category) a)
    (List.map (fun (f : Keeper_canary_facts.fact) -> f.category) b);
  Alcotest.(check (list string))
    "values match"
    (List.map (fun (f : Keeper_canary_facts.fact) -> f.value) a)
    (List.map (fun (f : Keeper_canary_facts.fact) -> f.value) b);
  Alcotest.(check (list string))
    "statements match"
    (List.map (fun (f : Keeper_canary_facts.fact) -> f.statement) a)
    (List.map (fun (f : Keeper_canary_facts.fact) -> f.statement) b)

let test_generate_differs_across_seeds () =
  let a = Keeper_canary_facts.generate ~seed:"run-fixed-A" ~count:9 in
  let b = Keeper_canary_facts.generate ~seed:"run-fixed-B" ~count:9 in
  let values (facts : Keeper_canary_facts.fact list) =
    List.map (fun (f : Keeper_canary_facts.fact) -> f.value) facts
  in
  Alcotest.(check bool)
    "two different seeds do not produce identical value lists"
    true
    (values a <> values b)

let test_generate_returns_requested_count_and_known_categories () =
  let facts = Keeper_canary_facts.generate ~seed:"run-count" ~count:5 in
  Alcotest.(check int) "count" 5 (List.length facts);
  List.iter
    (fun (f : Keeper_canary_facts.fact) ->
       Alcotest.(check bool)
         (Printf.sprintf "%s is a known category" f.category)
         true
         (List.mem f.category Keeper_canary_facts.category_names))
    facts

let test_generate_caps_at_category_count () =
  let facts = Keeper_canary_facts.generate ~seed:"run-cap" ~count:100 in
  Alcotest.(check int)
    "capped at category_names length"
    (List.length Keeper_canary_facts.category_names)
    (List.length facts)

(* First-occurrence scoring needs values that cannot be matched by
   anything except this run's own recall: no duplicates within a run, no
   value that is a substring of another (its first occurrence would be
   inside the longer value's statement), and no collision with another
   run's values (an old round on a reused keeper matched "Asia/Tokyo"
   first on 2026-08-16 and flipped order_matches). Two fixed seeds stand
   in for "another run" deterministically. *)
let test_values_are_unique_within_and_across_runs () =
  let values seed =
    Keeper_canary_facts.generate ~seed ~count:9
    |> List.map (fun (f : Keeper_canary_facts.fact) -> f.value)
  in
  let a = values "run-fixed-A" in
  let b = values "run-fixed-B" in
  Alcotest.(check int)
    "within-run values are pairwise distinct"
    9
    (List.length (List.sort_uniq compare a));
  List.iter
    (fun v ->
      let contained_elsewhere =
        List.exists
          (fun w -> (not (String.equal v w)) && Astring.String.is_infix ~affix:v w)
          a
      in
      Alcotest.(check bool)
        (Printf.sprintf "%S is not a substring of another value" v)
        false
        contained_elsewhere)
    a;
  List.iter
    (fun v ->
      Alcotest.(check bool)
        (Printf.sprintf "%S does not recur under another seed" v)
        false
        (List.mem v b))
    a

let test_statement_mentions_value () =
  let facts = Keeper_canary_facts.generate ~seed:"run-statement" ~count:9 in
  List.iter
    (fun (f : Keeper_canary_facts.fact) ->
       let score = Keeper_canary_facts.score ~facts:[ f ] ~reply:f.statement in
       Alcotest.(check int)
         (Printf.sprintf "%s statement recalls its own value" f.category)
         1
         score.facts_recalled)
    facts

let test_plan_orders_facts_then_one_recall_turn () =
  let facts = Keeper_canary_facts.generate ~seed:"run-plan" ~count:4 in
  let plan = Keeper_canary_facts.plan ~facts in
  Alcotest.(check int) "plan length is facts + 1" 5 (List.length plan);
  Alcotest.(check (list int))
    "indices are 1..5 in order"
    [ 1; 2; 3; 4; 5 ]
    (List.map (fun (e : Keeper_canary_facts.turn_plan_entry) -> e.index) plan);
  let fact_entries, recall_entries =
    List.partition (fun (e : Keeper_canary_facts.turn_plan_entry) -> e.category <> None) plan
  in
  Alcotest.(check int) "4 fact-injection entries" 4 (List.length fact_entries);
  (match recall_entries with
   | [ recall ] ->
     Alcotest.(check int) "recall is the last index" 5 recall.index;
     Alcotest.(check string) "recall message is the configured prompt" (Keeper_canary_facts.recall_prompt ()) recall.message
   | _ -> Alcotest.fail "expected exactly one recall entry")

let test_plan_fact_entries_carry_their_own_statement () =
  let facts = Keeper_canary_facts.generate ~seed:"run-plan-msg" ~count:3 in
  let plan = Keeper_canary_facts.plan ~facts in
  List.iter2
    (fun (f : Keeper_canary_facts.fact) (e : Keeper_canary_facts.turn_plan_entry) ->
       Alcotest.(check (option string)) "category" (Some f.category) e.category;
       Alcotest.(check string) "message is the fact's statement" f.statement e.message)
    facts
    (List.filteri (fun i _ -> i < 3) plan)

let test_plan_on_zero_facts_is_just_the_recall_turn () =
  let plan = Keeper_canary_facts.plan ~facts:[] in
  match plan with
  | [ { index = 1; category = None; message } ] ->
    Alcotest.(check string) "recall message" (Keeper_canary_facts.recall_prompt ()) message
  | _ -> Alcotest.fail "expected a single recall-only entry at index 1"

let test_score_all_recalled_in_order_is_pass_shaped () =
  let facts = Keeper_canary_facts.generate ~seed:"run-score-order" ~count:4 in
  let reply =
    "Sure, here is what you told me: "
    ^ String.concat ". " (List.map (fun (f : Keeper_canary_facts.fact) -> f.value) facts)
    ^ "."
  in
  let score = Keeper_canary_facts.score ~facts ~reply in
  Alcotest.(check int) "facts_total" 4 score.facts_total;
  Alcotest.(check int) "facts_recalled" 4 score.facts_recalled;
  Alcotest.(check bool) "order_matches" true score.order_matches;
  Alcotest.(check (list string)) "missing_categories" [] score.missing_categories

let test_score_partial_recall_reports_missing_categories () =
  let facts = Keeper_canary_facts.generate ~seed:"run-score-partial" ~count:4 in
  let recalled, missing =
    match facts with
    | a :: b :: rest -> [ a; b ], rest
    | _ -> Alcotest.fail "expected at least 2 facts"
  in
  let reply =
    String.concat ". " (List.map (fun (f : Keeper_canary_facts.fact) -> f.value) recalled)
  in
  let score = Keeper_canary_facts.score ~facts ~reply in
  Alcotest.(check int) "facts_recalled" 2 score.facts_recalled;
  Alcotest.(check (list string))
    "missing_categories"
    (List.map (fun (f : Keeper_canary_facts.fact) -> f.category) missing)
    score.missing_categories

let test_score_out_of_order_recall_fails_order_matches () =
  let facts = Keeper_canary_facts.generate ~seed:"run-score-reorder" ~count:2 in
  let a, b =
    match facts with
    | [ a; b ] -> a, b
    | _ -> Alcotest.fail "expected exactly 2 facts"
  in
  (* Reply mentions b before a, the reverse of injection order. *)
  let reply = Printf.sprintf "%s, then %s." b.value a.value in
  let score = Keeper_canary_facts.score ~facts ~reply in
  Alcotest.(check int) "facts_recalled" 2 score.facts_recalled;
  Alcotest.(check bool) "order_matches" false score.order_matches

let test_score_recall_is_case_insensitive () =
  let facts = Keeper_canary_facts.generate ~seed:"run-score-case" ~count:1 in
  let f = List.hd facts in
  let reply = String.uppercase_ascii f.value in
  let score = Keeper_canary_facts.score ~facts ~reply in
  Alcotest.(check int) "facts_recalled" 1 score.facts_recalled

let test_score_empty_reply_recalls_nothing () =
  let facts = Keeper_canary_facts.generate ~seed:"run-score-empty" ~count:3 in
  let score = Keeper_canary_facts.score ~facts ~reply:"" in
  Alcotest.(check int) "facts_recalled" 0 score.facts_recalled;
  Alcotest.(check bool) "order_matches on empty recall" true score.order_matches

let test_interval_for_wall_clock () =
  Alcotest.(check (float 1e-9))
    "9 gaps over 3600s"
    400.0
    (Keeper_canary_facts.interval_for_wall_clock ~gaps:9 ~target_s:3600.0);
  Alcotest.(check (float 1e-9))
    "zero gaps has no interval"
    0.0
    (Keeper_canary_facts.interval_for_wall_clock ~gaps:0 ~target_s:3600.0);
  Alcotest.(check (float 1e-9))
    "negative gaps has no interval"
    0.0
    (Keeper_canary_facts.interval_for_wall_clock ~gaps:(-1) ~target_s:3600.0)

let () =
  Prompt_registry.set_markdown_dir
    (Filename.concat (Masc_test_deps.find_project_root ()) "config/prompts");
  Alcotest.run
    "keeper_canary_facts"
    [ ( "generate"
      , [ Alcotest.test_case
            "deterministic given the same seed"
            `Quick
            test_generate_is_deterministic_given_the_same_seed
        ; Alcotest.test_case "differs across seeds" `Quick test_generate_differs_across_seeds
        ; Alcotest.test_case
            "returns requested count with known categories"
            `Quick
            test_generate_returns_requested_count_and_known_categories
        ; Alcotest.test_case
            "caps at category_names length"
            `Quick
            test_generate_caps_at_category_count
        ; Alcotest.test_case
            "statement mentions value"
            `Quick
            test_statement_mentions_value
        ; Alcotest.test_case
            "values are unique within and across runs"
            `Quick
            test_values_are_unique_within_and_across_runs
        ] )
    ; ( "plan"
      , [ Alcotest.test_case
            "orders facts then one recall turn"
            `Quick
            test_plan_orders_facts_then_one_recall_turn
        ; Alcotest.test_case
            "fact entries carry their own statement"
            `Quick
            test_plan_fact_entries_carry_their_own_statement
        ; Alcotest.test_case
            "zero facts is just the recall turn"
            `Quick
            test_plan_on_zero_facts_is_just_the_recall_turn
        ] )
    ; ( "score"
      , [ Alcotest.test_case
            "all recalled in order is pass-shaped"
            `Quick
            test_score_all_recalled_in_order_is_pass_shaped
        ; Alcotest.test_case
            "partial recall reports missing categories"
            `Quick
            test_score_partial_recall_reports_missing_categories
        ; Alcotest.test_case
            "out-of-order recall fails order_matches"
            `Quick
            test_score_out_of_order_recall_fails_order_matches
        ; Alcotest.test_case
            "recall is case-insensitive"
            `Quick
            test_score_recall_is_case_insensitive
        ; Alcotest.test_case
            "empty reply recalls nothing"
            `Quick
            test_score_empty_reply_recalls_nothing
        ] )
    ; ( "ladder"
      , [ Alcotest.test_case "interval for wall clock" `Quick test_interval_for_wall_clock ] )
    ]
