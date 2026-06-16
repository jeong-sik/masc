(* Standalone alcotest for the pure fusion core (RFC-0249 §6/§9/§10).
   Proves: deterministic gate branches, TOML config validation, depth guard. *)

open Fusion_types

(* alcotest testable over the derived show/eq of gate_decision. *)
let gate = Alcotest.testable pp_gate_decision equal_gate_decision

let base_policy : Fusion_policy.t =
  { Fusion_policy.enabled = true
  ; default_preset = "budget"
  ; max_concurrent_panels = 2
  ; presets =
      [ { Fusion_policy.name = "budget"
        ; panel = [ "a"; "b"; "c" ]
        ; judge = "a"
        ; max_tool_calls_per_panel = 2
        ; web_tools = true
        }
      ]
  ; low_confidence_threshold = 0.55
  ; high_stakes_task_kinds = [ "goal_decision" ]
  ; per_hour_budget = 20
  ; max_cost_usd_per_call = 0.5
  }

let req ?(preset = "budget") ?(depth = Fusion_depth.Top) ?(trigger = Explicit_tool_call) ()
  : fusion_request =
  { run_id = "r1"; keeper = "k"; prompt = "p"; preset; depth; trigger; web_tools = true }

let decide ?(policy = base_policy) ?(hourly_count = 0) ?(estimated_cost_usd = 0.1) r =
  Fusion_policy.decide ~policy ~hourly_count ~estimated_cost_usd r

(* --- gate branches (RFC-0249 §6) --- *)

let test_disabled () =
  let policy = { base_policy with Fusion_policy.enabled = false } in
  Alcotest.check gate "disabled" (Deny Disabled) (decide ~policy (req ()))

let test_unknown_preset () =
  Alcotest.check gate "unknown preset"
    (Deny (Preset_unknown "nope"))
    (decide (req ~preset:"nope" ()))

let test_depth_nested () =
  Alcotest.check gate "nested depth"
    (Deny Depth_exceeded)
    (decide (req ~depth:Fusion_depth.Nested ()))

let test_low_conf_below () =
  let r = req ~trigger:(Low_confidence { score = 0.4; threshold = 0.55 }) () in
  Alcotest.check gate "low-conf below threshold -> allow" (Allow r) (decide r)

let test_low_conf_above () =
  let r = req ~trigger:(Low_confidence { score = 0.7; threshold = 0.55 }) () in
  Alcotest.check gate "conf above threshold -> not warranted"
    (Deny Not_warranted) (decide r)

let test_high_stakes_listed () =
  let r = req ~trigger:(High_stakes "goal_decision") () in
  Alcotest.check gate "high-stakes listed -> allow" (Allow r) (decide r)

let test_high_stakes_unlisted () =
  let r = req ~trigger:(High_stakes "chitchat") () in
  Alcotest.check gate "high-stakes unlisted -> not warranted"
    (Deny Not_warranted) (decide r)

let test_over_hourly () =
  let r = req () in
  Alcotest.check gate "hourly budget exceeded"
    (Deny Over_hourly_budget) (decide ~hourly_count:20 r)

let test_over_cost () =
  let r = req () in
  Alcotest.check gate "cost cap exceeded"
    (Deny Over_cost_cap) (decide ~estimated_cost_usd:0.6 r)

let test_allow () =
  let r = req () in
  Alcotest.check gate "all pass -> allow" (Allow r) (decide r)

(* budget gate applies even to explicit/operator triggers *)
let test_explicit_still_budget_bound () =
  let r = req ~trigger:Operator_requested () in
  Alcotest.check gate "operator request still budget-bound"
    (Deny Over_hourly_budget) (decide ~hourly_count:99 r)

(* --- depth guard (RFC-0249 §10) --- *)

let test_depth_descend () =
  Alcotest.(check bool) "Top descends to Nested" true
    (Fusion_depth.descend Fusion_depth.Top = Some Fusion_depth.Nested);
  Alcotest.(check bool) "Nested is the floor" true
    (Fusion_depth.descend Fusion_depth.Nested = None)

(* --- config (RFC-0249 §9) --- *)

let parse s = Otoml.Parser.from_string s

let test_config_absent () =
  match Fusion_config.of_toml (parse "foo = 1") with
  | Ok p -> Alcotest.(check bool) "absent [fusion] -> disabled" false p.Fusion_policy.enabled
  | Error _ -> Alcotest.fail "expected Ok disabled"

let valid_toml =
  {|
[fusion]
enabled = true
default_preset = "budget"
max_concurrent_panels = 2
[fusion.gate]
low_confidence_threshold = 0.55
high_stakes_task_kinds = ["goal_decision"]
per_hour_budget = 20
max_cost_usd_per_call = 0.5
[fusion.presets.budget]
panel = ["a", "b", "c"]
judge = "a"
max_tool_calls_per_panel = 2
web_tools = true
|}

let test_config_valid () =
  match Fusion_config.of_toml (parse valid_toml) with
  | Ok p ->
    Alcotest.(check bool) "enabled" true p.Fusion_policy.enabled;
    Alcotest.(check int) "one preset" 1 (List.length p.Fusion_policy.presets);
    Alcotest.(check (float 0.0001)) "low_conf" 0.55 p.Fusion_policy.low_confidence_threshold;
    Alcotest.(check int) "per_hour" 20 p.Fusion_policy.per_hour_budget
  | Error es ->
    Alcotest.failf "expected Ok, got errors: %s"
      (String.concat ", " (List.map Fusion_config.show_config_error es))

let test_config_empty_presets () =
  match Fusion_config.of_toml (parse "[fusion]\nenabled = true\n") with
  | Error es ->
    Alcotest.(check bool) "Empty_presets present" true
      (List.mem Fusion_config.Empty_presets es)
  | Ok _ -> Alcotest.fail "expected Error Empty_presets"

let test_config_invalid_size () =
  let s =
    {|
[fusion]
enabled = true
[fusion.presets.toomany]
panel = ["a", "b", "c", "d", "e", "f", "g", "h", "i"]
judge = "a"
|}
  in
  match Fusion_config.of_toml (parse s) with
  | Error es ->
    Alcotest.(check bool) "Invalid_panel_size present" true
      (List.exists
         (function Fusion_config.Invalid_panel_size _ -> true | _ -> false)
         es)
  | Ok _ -> Alcotest.fail "expected Error Invalid_panel_size"

let test_config_missing_default () =
  let s =
    {|
[fusion]
enabled = true
default_preset = "ghost"
[fusion.presets.budget]
panel = ["a", "b"]
judge = "a"
|}
  in
  match Fusion_config.of_toml (parse s) with
  | Error es ->
    Alcotest.(check bool) "Missing_default_preset present" true
      (List.mem (Fusion_config.Missing_default_preset "ghost") es)
  | Ok _ -> Alcotest.fail "expected Error Missing_default_preset"

(* --- judge LLM-facing JSON parse (RFC-0249 §7.2) --- *)

let jdecision = Alcotest.testable pp_judge_decision equal_judge_decision

let valid_judge_json =
  {|{
    "consensus": [ { "text": "X is true", "supporting_models": ["a","b"] } ],
    "contradictions": [ { "topic": "Y", "positions": [ {"model":"a","stance":"yes"}, {"model":"b","stance":"no"} ], "evidence": ["e1"] } ],
    "partial_coverage": [ { "topic": "Z", "addressed_by": ["a"], "missing": "depth" } ],
    "unique_insights": [ { "text": "novel", "model": "b" } ],
    "blind_spots": [ "edge case" ],
    "resolved_answer": "the answer",
    "decision": { "kind": "answer", "answer": "the answer" }
  }|}

let test_judge_valid () =
  match Fusion_judge_parse.of_string valid_judge_json with
  | Ok js ->
    Alcotest.(check string) "resolved" "the answer" js.resolved_answer;
    Alcotest.(check int) "consensus" 1 (List.length js.consensus);
    Alcotest.(check int) "contradictions" 1 (List.length js.contradictions);
    Alcotest.(check int) "positions" 2
      (List.length (List.hd js.contradictions).positions);
    Alcotest.(check int) "blind_spots" 1 (List.length js.blind_spots);
    Alcotest.check jdecision "decision" (Answer "the answer") js.decision
  | Error e -> Alcotest.failf "expected Ok, got %s" e

let test_judge_recommend () =
  let s =
    {|{ "resolved_answer": "r", "decision": { "kind": "recommend", "action": "claim task 5", "rationale": "best fit" } }|}
  in
  match Fusion_judge_parse.of_string s with
  | Ok js ->
    Alcotest.check jdecision "recommend"
      (Recommend { action = "claim task 5"; rationale = "best fit" }) js.decision
  | Error e -> Alcotest.failf "expected Ok, got %s" e

let test_judge_insufficient () =
  let s =
    {|{ "resolved_answer": "r", "decision": { "kind": "insufficient", "missing": ["data","time"] } }|}
  in
  match Fusion_judge_parse.of_string s with
  | Ok js ->
    Alcotest.check jdecision "insufficient"
      (Insufficient { missing_for_decision = [ "data"; "time" ] }) js.decision
  | Error _ -> Alcotest.fail "expected Ok"

let test_judge_unknown_kind () =
  match
    Fusion_judge_parse.of_string
      {|{ "resolved_answer": "r", "decision": { "kind": "frobnicate" } }|}
  with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected Error on unknown decision kind"

let test_judge_missing_resolved () =
  match
    Fusion_judge_parse.of_string {|{ "decision": { "kind": "answer", "answer": "a" } }|}
  with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected Error on missing resolved_answer"

let test_judge_missing_decision () =
  match Fusion_judge_parse.of_string {|{ "resolved_answer": "r" }|} with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected Error on missing decision"

let test_judge_code_fence () =
  let s =
    "```json\n{ \"resolved_answer\": \"r\", \"decision\": { \"kind\": \"answer\", \"answer\": \"a\" } }\n```"
  in
  match Fusion_judge_parse.of_string s with
  | Ok js -> Alcotest.(check string) "fenced resolved" "r" js.resolved_answer
  | Error e -> Alcotest.failf "expected Ok, got %s" e

let test_judge_tolerant_skip () =
  (* one valid claim + one malformed (missing "text") -> only the valid one kept *)
  let s =
    {|{ "consensus": [ {"text":"ok"}, {"supporting_models":["a"]} ], "resolved_answer": "r", "decision": {"kind":"answer","answer":"a"} }|}
  in
  match Fusion_judge_parse.of_string s with
  | Ok js -> Alcotest.(check int) "tolerant consensus" 1 (List.length js.consensus)
  | Error e -> Alcotest.failf "expected Ok, got %s" e

let () =
  Alcotest.run "fusion_core"
    [ ( "gate"
      , [ Alcotest.test_case "disabled" `Quick test_disabled
        ; Alcotest.test_case "unknown_preset" `Quick test_unknown_preset
        ; Alcotest.test_case "depth_nested" `Quick test_depth_nested
        ; Alcotest.test_case "low_conf_below" `Quick test_low_conf_below
        ; Alcotest.test_case "low_conf_above" `Quick test_low_conf_above
        ; Alcotest.test_case "high_stakes_listed" `Quick test_high_stakes_listed
        ; Alcotest.test_case "high_stakes_unlisted" `Quick test_high_stakes_unlisted
        ; Alcotest.test_case "over_hourly" `Quick test_over_hourly
        ; Alcotest.test_case "over_cost" `Quick test_over_cost
        ; Alcotest.test_case "allow" `Quick test_allow
        ; Alcotest.test_case "explicit_budget_bound" `Quick test_explicit_still_budget_bound
        ] )
    ; ("depth", [ Alcotest.test_case "descend" `Quick test_depth_descend ])
    ; ( "config"
      , [ Alcotest.test_case "absent" `Quick test_config_absent
        ; Alcotest.test_case "valid" `Quick test_config_valid
        ; Alcotest.test_case "empty_presets" `Quick test_config_empty_presets
        ; Alcotest.test_case "invalid_size" `Quick test_config_invalid_size
        ; Alcotest.test_case "missing_default" `Quick test_config_missing_default
        ] )
    ; ( "judge_parse"
      , [ Alcotest.test_case "valid" `Quick test_judge_valid
        ; Alcotest.test_case "recommend" `Quick test_judge_recommend
        ; Alcotest.test_case "insufficient" `Quick test_judge_insufficient
        ; Alcotest.test_case "unknown_kind" `Quick test_judge_unknown_kind
        ; Alcotest.test_case "missing_resolved" `Quick test_judge_missing_resolved
        ; Alcotest.test_case "missing_decision" `Quick test_judge_missing_decision
        ; Alcotest.test_case "code_fence" `Quick test_judge_code_fence
        ; Alcotest.test_case "tolerant_skip" `Quick test_judge_tolerant_skip
        ] )
    ]
