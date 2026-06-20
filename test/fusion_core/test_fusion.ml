(* Standalone alcotest for the pure fusion core (RFC-0252 §6/§9/§10).
   Proves: deterministic gate branches, TOML config validation, depth guard,
   atomic budget check-and-increment. *)

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
        ; panel_system_prompt = "panel"
        ; judge_system_prompt = "judge"
        ; panel_timeout_s = 300.0
        ; judge_timeout_s = 300.0
        ; web_tools = false
        ; max_tool_calls_per_panel = 0
        }
      ]
  ; per_hour_budget = 20
  }

let req ?(preset = "budget") ?(depth = Fusion_depth.Top) ?(trigger = Explicit_tool_call)
    ?(web_tools = false) () : fusion_request =
  { run_id = "r1"; keeper = "k"; prompt = "p"; preset; web_tools; depth; trigger }

let decide ?(policy = base_policy) r = Fusion_policy.decide ~policy r

let ok_int = Alcotest.result Alcotest.int Alcotest.unit

(* --- gate branches (RFC-0252 §6) --- *)

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

(* trigger는 발동 이유 라벨일 뿐 — 게이트는 종류로 거부하지 않는다(심의 가치는
   키퍼/LLM이 판단). 구조(enabled/preset/depth)만 통과하면 어떤 trigger든 Allow.
   예전 score<threshold / task_kind∈list 판정(Not_warranted)은 제거됐다. *)
let test_low_confidence_trigger_allowed () =
  let r = req ~trigger:Low_confidence () in
  Alcotest.check gate "low_confidence label -> allow" (Allow r) (decide r)

let test_high_stakes_trigger_allowed () =
  let r = req ~trigger:(High_stakes "anything") () in
  Alcotest.check gate "high_stakes label -> allow" (Allow r) (decide r)

let test_allow () =
  let r = req () in
  Alcotest.check gate "all pass -> allow" (Allow r) (decide r)

(* budget gate applies even to explicit/operator triggers — 예산은 이제
   orchestrator에서 [Fusion_budget.try_incr_if_under]로 원자적으로 소비한다. *)
let test_explicit_still_budget_bound () =
  let b = Fusion_budget.create () in
  Alcotest.(check ok_int) "operator request still budget-bound after limit hit"
    (Error ())
    (Fusion_budget.try_incr_if_under b ~hour_bucket:"H1" ~limit:0)

(* --- config (RFC-0252 §9) --- *)

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
per_hour_budget = 20
[fusion.presets.budget]
web_tools = false
max_tool_calls_per_panel = 0
panel = ["a", "b", "c"]
judge = "a"
panel_system_prompt = "answer independently"
judge_system_prompt = "synthesize the panel"
|}

let test_config_valid () =
  match Fusion_config.of_toml (parse valid_toml) with
  | Ok p ->
    Alcotest.(check bool) "enabled" true p.Fusion_policy.enabled;
    Alcotest.(check int) "one preset" 1 (List.length p.Fusion_policy.presets);
    Alcotest.(check int) "per_hour" 20 p.Fusion_policy.per_hour_budget;
    (match p.Fusion_policy.presets with
     | [ preset ] ->
       Alcotest.(check bool) "web_tools" false preset.Fusion_policy.web_tools;
       Alcotest.(check int) "max_tool_calls" 0 preset.Fusion_policy.max_tool_calls_per_panel
     | _ -> Alcotest.fail "expected exactly one preset")
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
panel_system_prompt = "p"
judge_system_prompt = "j"
|}
  in
  match Fusion_config.of_toml (parse s) with
  | Error es ->
    Alcotest.(check bool) "Missing_default_preset present" true
      (List.mem (Fusion_config.Missing_default_preset "ghost") es)
  | Ok _ -> Alcotest.fail "expected Error Missing_default_preset"

let test_config_missing_prompt () =
  let s =
    {|
[fusion]
enabled = true
default_preset = "p1"
[fusion.presets.p1]
panel = ["a", "b"]
judge = "a"
|}
  in
  match Fusion_config.of_toml (parse s) with
  | Error es ->
    Alcotest.(check bool) "Missing_prompt present" true
      (List.mem (Fusion_config.Missing_prompt "p1") es)
  | Ok _ -> Alcotest.fail "expected Error Missing_prompt"

(* enabled인데 preset의 judge 모델 id 누락(="") → 빈 runtime_id로 종합 불가. 로드 거부. *)
let test_config_missing_judge_model () =
  let s =
    {|
[fusion]
enabled = true
default_preset = "p1"
[fusion.gate]
per_hour_budget = 20
[fusion.presets.p1]
panel = ["a", "b"]
judge = ""
panel_system_prompt = "p"
judge_system_prompt = "j"
|}
  in
  match Fusion_config.of_toml (parse s) with
  | Error es ->
    Alcotest.(check bool) "Missing_judge_model present" true
      (List.mem (Fusion_config.Missing_judge_model "p1") es)
  | Ok _ -> Alcotest.fail "expected Error Missing_judge_model"

let test_config_bad_concurrency () =
  let s =
    {|
[fusion]
enabled = true
default_preset = "p1"
max_concurrent_panels = 0
[fusion.presets.p1]
panel = ["a", "b"]
judge = "a"
panel_system_prompt = "p"
judge_system_prompt = "j"
|}
  in
  match Fusion_config.of_toml (parse s) with
  | Error es ->
    Alcotest.(check bool) "Invalid_max_concurrent_panels present" true
      (List.mem (Fusion_config.Invalid_max_concurrent_panels 0) es)
  | Ok _ -> Alcotest.fail "expected Error Invalid_max_concurrent_panels"

(* enabled + per_hour_budget=0 → gate가 count>=0으로 항상 deny-all. 로드 거부 강제. *)
let test_config_bad_per_hour () =
  let s =
    {|
[fusion]
enabled = true
default_preset = "p1"
[fusion.gate]
per_hour_budget = 0
[fusion.presets.p1]
panel = ["a", "b"]
judge = "a"
panel_system_prompt = "p"
judge_system_prompt = "j"
|}
  in
  match Fusion_config.of_toml (parse s) with
  | Error es ->
    Alcotest.(check bool) "Invalid_per_hour_budget present" true
      (List.mem (Fusion_config.Invalid_per_hour_budget 0) es)
  | Ok _ -> Alcotest.fail "expected Error Invalid_per_hour_budget"

let test_config_invalid_max_tool_calls () =
  let s =
    {|
[fusion]
enabled = true
default_preset = "p1"
[fusion.presets.p1]
panel = ["a", "b"]
judge = "a"
panel_system_prompt = "p"
judge_system_prompt = "j"
web_tools = true
max_tool_calls_per_panel = 17
|}
  in
  match Fusion_config.of_toml (parse s) with
  | Error es ->
    Alcotest.(check bool) "Invalid_max_tool_calls present" true
      (List.exists
         (function Fusion_config.Invalid_max_tool_calls _ -> true | _ -> false)
         es)
  | Ok _ -> Alcotest.fail "expected Error Invalid_max_tool_calls"

(* enabled인데 default_preset 생략(="") → preset 생략 호출이 폭빽할 default가 없어
   항상 Preset_unknown ""로 deny. 빈 default_preset도 로드 거부. *)
let test_config_empty_default_preset () =
  let s =
    {|
[fusion]
enabled = true
[fusion.gate]
per_hour_budget = 20
[fusion.presets.p1]
panel = ["a", "b"]
judge = "a"
panel_system_prompt = "p"
judge_system_prompt = "j"
|}
  in
  match Fusion_config.of_toml (parse s) with
  | Error es ->
    Alcotest.(check bool) "Missing_default_preset \"\" present" true
      (List.mem (Fusion_config.Missing_default_preset "") es)
  | Ok _ -> Alcotest.fail "expected Error Missing_default_preset"

(* Mirrors the disabled [fusion] seed shipped in config/runtime.toml: a
   populated default_preset + trio panel while enabled=false must parse to
   [Ok] (Empty_presets / Missing_default_preset are enabled-gated). Pins the
   seed-template structure against parser drift. *)
let seed_disabled_toml =
  {|
[fusion]
enabled = false
default_preset = "trio"
max_concurrent_panels = 2
[fusion.gate]
per_hour_budget = 20
[fusion.presets.trio]
web_tools = false
max_tool_calls_per_panel = 0
panel = [
  "deepseek.deepseek-v4-pro",
  "glm-coding.glm-5-turbo",
  "ollama_cloud.deepseek-v4-flash",
]
judge = "deepseek.deepseek-v4-pro"
panel_system_prompt = "answer independently"
judge_system_prompt = "synthesize the panel"
panel_timeout_s = 300.0
judge_timeout_s = 300.0
|}

let test_config_disabled_with_preset () =
  match Fusion_config.of_toml (parse seed_disabled_toml) with
  | Ok p ->
    Alcotest.(check bool) "seed disabled" false p.Fusion_policy.enabled;
    Alcotest.(check int) "trio preset present" 1 (List.length p.Fusion_policy.presets);
    (match p.Fusion_policy.presets with
     | [ preset ] ->
       Alcotest.(check int) "trio panel size" 3 (List.length preset.Fusion_policy.panel)
     | _ -> Alcotest.fail "expected exactly one preset")
  | Error es ->
    Alcotest.failf "seed [fusion] must parse, got errors: %s"
      (String.concat ", " (List.map Fusion_config.show_config_error es))

(* --- judge LLM-facing JSON parse (RFC-0252 §7.2) --- *)

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

(* --- budget counter (RFC-0252 §6/§10) --- *)

let ok_or_fail = function Ok n -> n | Error () -> Alcotest.fail "expected Ok"

let test_budget_basic () =
  let b = Fusion_budget.create () in
  Alcotest.(check int) "first" 1
    (ok_or_fail (Fusion_budget.try_incr_if_under b ~hour_bucket:"H1" ~limit:10));
  Alcotest.(check int) "second" 2
    (ok_or_fail (Fusion_budget.try_incr_if_under b ~hour_bucket:"H1" ~limit:10))

(* 검사+증가가 원자적: limit에 도달하면 Error로 거부하고 카운트를 늘리지 않는다. *)
let test_budget_limit () =
  let b = Fusion_budget.create () in
  ignore (ok_or_fail (Fusion_budget.try_incr_if_under b ~hour_bucket:"H1" ~limit:2) : int);
  ignore (ok_or_fail (Fusion_budget.try_incr_if_under b ~hour_bucket:"H1" ~limit:2) : int);
  Alcotest.(check bool) "at limit -> Error" true
    (Fusion_budget.try_incr_if_under b ~hour_bucket:"H1" ~limit:2 = Error ())

let test_budget_window_reset () =
  let b = Fusion_budget.create () in
  ignore (ok_or_fail (Fusion_budget.try_incr_if_under b ~hour_bucket:"H1" ~limit:10) : int);
  ignore (ok_or_fail (Fusion_budget.try_incr_if_under b ~hour_bucket:"H1" ~limit:10) : int);
  Alcotest.(check int) "new window resets to 1" 1
    (ok_or_fail (Fusion_budget.try_incr_if_under b ~hour_bucket:"H2" ~limit:10))

let test_budget_try_incr_if_under () =
  let b = Fusion_budget.create () in
  Alcotest.(check ok_int) "first under limit" (Ok 1)
    (Fusion_budget.try_incr_if_under b ~hour_bucket:"H1" ~limit:2);
  Alcotest.(check ok_int) "second under limit" (Ok 2)
    (Fusion_budget.try_incr_if_under b ~hour_bucket:"H1" ~limit:2);
  Alcotest.(check ok_int) "at limit -> error" (Error ())
    (Fusion_budget.try_incr_if_under b ~hour_bucket:"H1" ~limit:2);
  Alcotest.(check ok_int) "new bucket resets" (Ok 1)
    (Fusion_budget.try_incr_if_under b ~hour_bucket:"H2" ~limit:2)

let () =
  Alcotest.run "fusion_core"
    [ ( "gate"
      , [ Alcotest.test_case "disabled" `Quick test_disabled
        ; Alcotest.test_case "unknown_preset" `Quick test_unknown_preset
        ; Alcotest.test_case "depth_nested" `Quick test_depth_nested
        ; Alcotest.test_case "low_confidence_trigger_allowed" `Quick test_low_confidence_trigger_allowed
        ; Alcotest.test_case "high_stakes_trigger_allowed" `Quick test_high_stakes_trigger_allowed
        ; Alcotest.test_case "allow" `Quick test_allow
        ; Alcotest.test_case "explicit_still_budget_bound" `Quick test_explicit_still_budget_bound
        ] )
    ; ( "config"
      , [ Alcotest.test_case "absent" `Quick test_config_absent
        ; Alcotest.test_case "valid" `Quick test_config_valid
        ; Alcotest.test_case "empty_presets" `Quick test_config_empty_presets
        ; Alcotest.test_case "invalid_size" `Quick test_config_invalid_size
        ; Alcotest.test_case "missing_default" `Quick test_config_missing_default
        ; Alcotest.test_case "missing_prompt" `Quick test_config_missing_prompt
        ; Alcotest.test_case "missing_judge_model" `Quick test_config_missing_judge_model
        ; Alcotest.test_case "bad_concurrency" `Quick test_config_bad_concurrency
        ; Alcotest.test_case "bad_per_hour" `Quick test_config_bad_per_hour
        ; Alcotest.test_case "invalid_max_tool_calls" `Quick test_config_invalid_max_tool_calls
        ; Alcotest.test_case "empty_default_preset" `Quick test_config_empty_default_preset
        ; Alcotest.test_case "disabled_with_preset" `Quick test_config_disabled_with_preset
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
    ; ( "budget"
      , [ Alcotest.test_case "basic" `Quick test_budget_basic
        ; Alcotest.test_case "limit" `Quick test_budget_limit
        ; Alcotest.test_case "window_reset" `Quick test_budget_window_reset
        ; Alcotest.test_case "try_incr_if_under" `Quick test_budget_try_incr_if_under
        ] )
    ]
