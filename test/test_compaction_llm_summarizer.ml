(** Unit tests for [Keeper_compaction_llm_summarizer] (RFC-0313-adjacent W2).

    Covers the pure surface: structured-plan parsing/validation
    ([plan_of_json]) and plan application ([apply]). The provider call in
    [make] needs an Eio context + live provider and is exercised by
    integration, not here. *)

open Masc
module C = Keeper_compaction_llm_summarizer
module Compact_policy = Keeper_compact_policy

let plan_json ~summary ~kept ~summarized ~dropped : Yojson.Safe.t =
  let ints xs = `List (List.map (fun i -> `Int i) xs) in
  `Assoc
    [ "summary", `String summary
    ; "kept_indices", ints kept
    ; "summarized_indices", ints summarized
    ; "dropped_indices", ints dropped
    ]

let is_ok = function Ok _ -> true | Error _ -> false
let is_error = function Ok _ -> false | Error _ -> true

let temperature_runtime_id = "local.kimi_like"

let temperature_runtime_toml =
  "[providers.local]\n\
   display-name = \"Local\"\n\
   protocol = \"ollama-http\"\n\
   endpoint = \"http://localhost:11434\"\n\
   \n\
   [providers.fallback]\n\
   display-name = \"Fallback\"\n\
   protocol = \"ollama-http\"\n\
   endpoint = \"http://localhost:11435\"\n\
   \n\
   [models.kimi_like]\n\
   api-name = \"kimi-like\"\n\
   max-context = 1024\n\
   temperature = 1.0\n\
   \n\
   [models.kimi_like.capabilities]\n\
   supports-structured-output = true\n\
   \n\
   [local.kimi_like]\n\
   \n\
   [fallback.kimi_like]\n\
   \n\
   [runtime]\n\
   default = \"local.kimi_like\"\n\
   librarian = \"local.kimi_like\"\n\
   \n\
   [runtime.lanes.compaction]\n\
   strategy = \"ordered\"\n\
   candidates = [\"local.kimi_like\", \"fallback.kimi_like\"]\n"

let with_temperature_runtime f =
  let path = Filename.temp_file "compaction_temperature_runtime" ".toml" in
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  let oc = open_out path in
  output_string oc temperature_runtime_toml;
  close_out oc;
  Fun.protect
    ~finally:(fun () ->
      Runtime.For_testing.restore runtime_snapshot;
      try Sys.remove path with
      | Sys_error _ -> ())
    (fun () ->
      match Runtime.save_config_text ~runtime_config_path:path temperature_runtime_toml with
      | Error detail -> Alcotest.failf "runtime config should load: %s" detail
      | Ok () ->
        (match Runtime.get_runtime_by_id temperature_runtime_id with
         | None -> Alcotest.fail "temperature runtime should resolve"
         | Some runtime -> f runtime.Runtime.provider_config))

let test_provider_for_plan_preserves_runtime_temperature () =
  with_temperature_runtime (fun provider_cfg ->
    let cfg =
      C.For_testing.provider_for_plan provider_cfg
    in
    Alcotest.(check (option (float 0.0001)))
      "runtime.toml temperature is preserved"
      (Some 1.0)
      cfg.temperature)

let test_provider_for_plan_preserves_temperature_omission () =
  let provider_cfg =
    Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.OpenAI_compat
      ~model_id:"test-model"
      ~base_url:"http://example.invalid"
      ()
  in
  let cfg = C.For_testing.provider_for_plan provider_cfg in
  Alcotest.(check (option (float 0.0001)))
    "temperature remains omitted"
    None
    cfg.temperature

let test_lane_candidates_keep_declared_order () =
  with_temperature_runtime @@ fun _ ->
  let actual =
    C.For_testing.candidate_runtime_ids_for_assignment
      ~keeper_name:"keeper-test"
      ~runtime_id:"compaction"
  in
  Alcotest.(check (option (list string))) "declared candidate order"
    (Some [ "local.kimi_like"; "fallback.kimi_like" ])
    actual

(* -- #25051 P0: structured-judge lane precedes an ineligible chat runtime --

   On the live fleet, most keepers inherit [runtime].default for chat, which
   is picked for chat throughput and is not guaranteed to support the
   provider-native structured-output schema the compaction plan call needs.
   [runtime].structured_judge, by contrast, is explicitly reserved for
   schema-capable requests (RFC-0307), the same lane board-attention judgment
   and failure judgment already use. These fixtures give "chat" no
   [supports-structured-output] (ineligible, mirrors deepseek-v4-flash in
   config/runtime.toml) and "judge" [supports-structured-output = true]
   (eligible), so the tests below can tell the two candidate sources apart. *)

let ineligible_chat_runtime_id = "lane_split_chat.chat_model"
let eligible_judge_runtime_id = "lane_split_judge.judge_model"

let lane_split_runtime_toml =
  "[providers.lane_split_chat]\n\
   display-name = \"Lane Split Chat\"\n\
   protocol = \"ollama-http\"\n\
   endpoint = \"http://localhost:11434\"\n\
   \n\
   [providers.lane_split_judge]\n\
   display-name = \"Lane Split Judge\"\n\
   protocol = \"ollama-http\"\n\
   endpoint = \"http://localhost:11436\"\n\
   \n\
   [models.chat_model]\n\
   api-name = \"chat-model\"\n\
   max-context = 1024\n\
   \n\
   [models.chat_model.capabilities]\n\
   supports-structured-output = false\n\
   \n\
   [models.judge_model]\n\
   api-name = \"judge-model\"\n\
   max-context = 1024\n\
   \n\
   [models.judge_model.capabilities]\n\
   supports-structured-output = true\n\
   \n\
   [lane_split_chat.chat_model]\n\
   \n\
   [lane_split_judge.judge_model]\n\
   \n\
   [runtime]\n\
   default = \"lane_split_chat.chat_model\"\n\
   structured_judge = \"lane_split_judge.judge_model\"\n"

let with_lane_split_runtime f =
  let path = Filename.temp_file "compaction_lane_split_runtime" ".toml" in
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  let oc = open_out path in
  output_string oc lane_split_runtime_toml;
  close_out oc;
  Fun.protect
    ~finally:(fun () ->
      Runtime.For_testing.restore runtime_snapshot;
      try Sys.remove path with
      | Sys_error _ -> ())
    (fun () ->
      match Runtime.save_config_text ~runtime_config_path:path lane_split_runtime_toml with
      | Error detail -> Alcotest.failf "runtime config should load: %s" detail
      | Ok () -> f ())

let test_ineligible_chat_runtime_alone_has_no_candidate () =
  with_lane_split_runtime @@ fun () ->
  (* Reproduces the #25051 P0 symptom directly: when the keeper's own chat
     runtime is the only seed (the pre-fix behaviour), an ineligible model
     resolves to zero candidates, so the summarizer is permanently
     unavailable for that keeper. *)
  Alcotest.(check (option (list string)))
    "an ineligible seed alone resolves no candidates"
    (Some [])
    (C.For_testing.candidate_runtime_ids_for_assignment
       ~keeper_name:"keeper-test"
       ~runtime_id:ineligible_chat_runtime_id)

let test_structured_judge_seed_reaches_eligible_candidate () =
  with_lane_split_runtime @@ fun () ->
  (* The fix: seeding the chain with the structured-judge id first gives the
     chain an eligible candidate even though the keeper's own chat runtime
     (still present as a lower-priority seed) remains ineligible. *)
  Alcotest.(check (list string))
    "structured-judge seed supplies the only eligible candidate, ordered first"
    [ eligible_judge_runtime_id ]
    (C.For_testing.candidate_runtime_ids_for_assignments
       ~keeper_name:"keeper-test"
       ~runtime_ids:[ eligible_judge_runtime_id; ineligible_chat_runtime_id ])

let test_both_seeds_unresolvable_yields_no_candidate () =
  with_lane_split_runtime @@ fun () ->
  (* No silent fallback: an unresolvable structured-judge id alongside an
     ineligible chat runtime must still resolve to zero candidates, never a
     surprise fallback onto the ineligible model. *)
  Alcotest.(check (list string))
    "no candidate when every seed fails to resolve or is ineligible"
    []
    (C.For_testing.candidate_runtime_ids_for_assignments
       ~keeper_name:"keeper-test"
       ~runtime_ids:[ "no.such.runtime"; ineligible_chat_runtime_id ])

let test_duplicate_seed_collapses_to_one_candidate () =
  with_lane_split_runtime @@ fun () ->
  Alcotest.(check (list string))
    "the same runtime id named twice as a seed is tried once"
    [ eligible_judge_runtime_id ]
    (C.For_testing.candidate_runtime_ids_for_assignments
       ~keeper_name:"keeper-test"
       ~runtime_ids:[ eligible_judge_runtime_id; eligible_judge_runtime_id ])

let make_test_meta name =
  match Masc_test_deps.meta_of_json_fixture (`Assoc [ "name", `String name ]) with
  | Ok m -> m
  | Error e -> Alcotest.failf "meta fixture failed: %s" e

let test_compact_policy_prefers_structured_judge_over_chat_runtime () =
  with_lane_split_runtime @@ fun () ->
  (* End-to-end proof at the Keeper_compact_policy call site (not just the
     summarizer's candidate resolution): a keeper with no explicit runtime
     assignment inherits [runtime].default for chat (ineligible here), yet
     the candidate-id list built for the compaction plan call still puts the
     structured-judge runtime first. Counterfactual: on the pre-#25051 code,
     [Compact_policy.For_testing] does not exist (single [runtime_id] sourced
     solely from the keeper's own chat assignment), so this fails to compile
     on that base — verified by stashing this fix and re-running the build. *)
  let meta = make_test_meta "lane-split-keeper" in
  Alcotest.(check (list string))
    "structured-judge runtime precedes the keeper's own chat runtime"
    [ eligible_judge_runtime_id; ineligible_chat_runtime_id ]
    (Compact_policy.For_testing.compaction_runtime_ids meta)

(* -- plan_of_json: valid partition accepted -- *)

let test_valid_partition_accepted () =
  let json = plan_json ~summary:"folded" ~kept:[ 3; 4 ] ~summarized:[ 0; 1 ] ~dropped:[ 2 ] in
  Alcotest.(check bool)
    "a full disjoint partition of [0,5) parses"
    true
    (is_ok (C.plan_of_json ~message_count:5 json))

let test_all_kept_rejected () =
  let json = plan_json ~summary:"n/a" ~kept:[ 0; 1; 2 ] ~summarized:[] ~dropped:[] in
  Alcotest.(check bool)
    "keeping everything is not semantic compaction"
    true
    (is_error (C.plan_of_json ~message_count:3 json))

let test_drop_only_with_kept_accepted () =
  let json = plan_json ~summary:"unused" ~kept:[ 1 ] ~summarized:[] ~dropped:[ 0 ] in
  Alcotest.(check bool)
    "drop-only plans are valid when at least one message remains"
    true
    (is_ok (C.plan_of_json ~message_count:2 json))

(* -- plan_of_json: structural violations rejected (no silent repair) -- *)

let test_out_of_range_rejected () =
  let json = plan_json ~summary:"x" ~kept:[ 0; 1 ] ~summarized:[ 5 ] ~dropped:[] in
  Alcotest.(check bool)
    "an index >= message_count is rejected"
    true
    (is_error (C.plan_of_json ~message_count:2 json))

let test_negative_rejected () =
  let json = plan_json ~summary:"x" ~kept:[ -1; 0 ] ~summarized:[ 1 ] ~dropped:[] in
  Alcotest.(check bool)
    "a negative index is rejected"
    true
    (is_error (C.plan_of_json ~message_count:2 json))

let test_duplicate_rejected () =
  let json = plan_json ~summary:"x" ~kept:[ 0; 1 ] ~summarized:[ 1 ] ~dropped:[] in
  Alcotest.(check bool)
    "an index appearing in two lists is rejected"
    true
    (is_error (C.plan_of_json ~message_count:2 json))

let test_missing_index_rejected () =
  let json = plan_json ~summary:"x" ~kept:[ 0 ] ~summarized:[] ~dropped:[] in
  Alcotest.(check bool)
    "a partition that omits an in-range index is rejected"
    true
    (is_error (C.plan_of_json ~message_count:2 json))

let test_all_dropped_rejected () =
  let json = plan_json ~summary:"S" ~kept:[] ~summarized:[] ~dropped:[ 0; 1 ] in
  Alcotest.(check bool)
    "a non-empty working set must not compact to empty output"
    true
    (is_error (C.plan_of_json ~message_count:2 json))

let test_empty_summary_rejected_when_summarizing () =
  let json = plan_json ~summary:"   " ~kept:[ 1 ] ~summarized:[ 0 ] ~dropped:[] in
  Alcotest.(check bool)
    "a blank summary is rejected when there are summarized indices to fold"
    true
    (is_error (C.plan_of_json ~message_count:2 json))

let test_missing_field_rejected () =
  let json = `Assoc [ "summary", `String "x"; "kept_indices", `List [] ] in
  Alcotest.(check bool)
    "a plan missing summarized_indices/dropped_indices is rejected"
    true
    (is_error (C.plan_of_json ~message_count:0 json))

(* -- apply: reconstruction honours the plan -- *)

let msg role text = Agent_sdk.Types.text_message role text
let texts (ms : Agent_sdk.Types.message list) =
  List.map (fun m -> Agent_sdk.Types.text_of_message m) ms

let sample =
  [ msg Agent_sdk.Types.User "u0"
  ; msg Agent_sdk.Types.Assistant "a1"
  ; msg Agent_sdk.Types.Tool "t2"
  ; msg Agent_sdk.Types.User "u3"
  ]

let test_apply_keeps_summarizes_drops () =
  (* kept: 3 ; summarized: 0,1 ; dropped: 2 *)
  let json = plan_json ~summary:"S" ~kept:[ 3 ] ~summarized:[ 0; 1 ] ~dropped:[ 2 ] in
  match C.plan_of_json ~message_count:4 json with
  | Error e -> Alcotest.failf "expected valid plan, got %s" e
  | Ok plan ->
    let out = C.apply plan ~messages:sample in
    let out_texts = texts out in
    (* summary replaces indices 0,1 at position of first summarized (0);
       index 2 dropped; index 3 kept. Result: [summary; u3]. *)
    Alcotest.(check int) "two messages remain" 2 (List.length out);
    Alcotest.(check bool)
      "first is the compaction summary"
      true
      (match out_texts with
       | s :: _ -> Astring.String.is_infix ~affix:"S" s
                   && Astring.String.is_prefix ~affix:"[COMPACTION_SUMMARY]" s
       | [] -> false);
    Alcotest.(check (list string))
      "kept message survives verbatim after the summary"
      [ "u3" ]
      (List.tl out_texts)

let test_apply_drop_only_preserves_kept () =
  let json = plan_json ~summary:"unused" ~kept:[ 0; 1; 2 ] ~summarized:[] ~dropped:[ 3 ] in
  match C.plan_of_json ~message_count:4 json with
  | Error e -> Alcotest.failf "expected valid plan, got %s" e
  | Ok plan ->
    let out = C.apply plan ~messages:sample in
    Alcotest.(check (list string))
      "drop-only removes only the selected message"
      [ "u0"; "a1"; "t2" ]
      (texts out)

let () =
  Alcotest.run "compaction_llm_summarizer"
    [ ( "provider"
      , [ Alcotest.test_case "runtime temperature is authoritative" `Quick
            test_provider_for_plan_preserves_runtime_temperature
        ; Alcotest.test_case "temperature omission is preserved" `Quick
            test_provider_for_plan_preserves_temperature_omission
        ; Alcotest.test_case "lane candidates keep declared order" `Quick
            test_lane_candidates_keep_declared_order
        ] )
    ; ( "structured_judge_lane_split_25051"
      , [ Alcotest.test_case "ineligible chat runtime alone has no candidate" `Quick
            test_ineligible_chat_runtime_alone_has_no_candidate
        ; Alcotest.test_case "structured-judge seed reaches an eligible candidate" `Quick
            test_structured_judge_seed_reaches_eligible_candidate
        ; Alcotest.test_case "both seeds unresolvable yields no candidate" `Quick
            test_both_seeds_unresolvable_yields_no_candidate
        ; Alcotest.test_case "duplicate seed collapses to one candidate" `Quick
            test_duplicate_seed_collapses_to_one_candidate
        ; Alcotest.test_case "compact policy prefers structured judge over chat runtime" `Quick
            test_compact_policy_prefers_structured_judge_over_chat_runtime
        ] )
    ; ( "plan_of_json"
      , [ Alcotest.test_case "valid partition accepted" `Quick test_valid_partition_accepted
        ; Alcotest.test_case "all kept rejected" `Quick test_all_kept_rejected
        ; Alcotest.test_case "drop-only with kept accepted" `Quick
            test_drop_only_with_kept_accepted
        ; Alcotest.test_case "out of range rejected" `Quick test_out_of_range_rejected
        ; Alcotest.test_case "negative rejected" `Quick test_negative_rejected
        ; Alcotest.test_case "duplicate rejected" `Quick test_duplicate_rejected
        ; Alcotest.test_case "missing index rejected" `Quick test_missing_index_rejected
        ; Alcotest.test_case "all dropped rejected" `Quick test_all_dropped_rejected
        ; Alcotest.test_case "empty summary rejected when summarizing" `Quick
            test_empty_summary_rejected_when_summarizing
        ; Alcotest.test_case "missing field rejected" `Quick test_missing_field_rejected
        ] )
    ; ( "apply"
      , [ Alcotest.test_case "keeps/summarizes/drops" `Quick test_apply_keeps_summarizes_drops
        ; Alcotest.test_case "drop-only preserves kept" `Quick
            test_apply_drop_only_preserves_kept
        ] )
    ]
