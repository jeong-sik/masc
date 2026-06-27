(* Standalone alcotest for the pure fusion core (RFC-0252 §6/§9, RFC-0252-A).
   Proves: deterministic gate branches, TOML config validation + heterogeneous
   panel-group parsing + legacy flat desugar (byte-identity), depth guard, and
   the pure judge-arg derivations that keep a single-group preset behaving as
   today. *)

open Fusion_types

(* alcotest testable over the derived show/eq of gate_decision. *)
let gate = Alcotest.testable pp_gate_decision equal_gate_decision

(* alcotest testable over a preset — the @@deriving eq is the byte-identity
   contract for the legacy-flat == single-group golden. *)
let preset_t = Alcotest.testable Fusion_policy.pp_preset Fusion_policy.equal_preset

let base_group : Fusion_policy.panel_group =
  { Fusion_policy.models = [ "a"; "b"; "c" ]
  ; label = ""
  ; system_prompt = "panel"
  ; web_tools = false
  ; max_tool_calls = 0
  ; max_output_tokens = None
  ; timeout_s = 300.0
  }

(* RFC-0280: presets는 [Validated_preset.t]라 private — of_preset로만 생성. 테스트
   리터럴은 유효하므로 get_ok (실패하면 테스트 setup 버그). *)
let validated (p : Fusion_policy.preset) : Fusion_policy.Validated_preset.t =
  match Fusion_policy.Validated_preset.of_preset p with
  | Ok vp -> vp
  | Error _ -> Alcotest.fail "test setup: preset literal failed validation"

(* validated preset에서 raw preset 필드를 읽는 coercion 단축. *)
let raw = Fusion_policy.Validated_preset.preset

let base_policy : Fusion_policy.t =
  { Fusion_policy.enabled = true
  ; default_preset = "trio"
  ; max_concurrent_panels = 2
  ; max_concurrent_judges = Fusion_policy.default_max_concurrent_judges
  ; staged_judge_group_size = Fusion_policy.default_staged_judge_group_size
  ; presets =
      [ validated
          { Fusion_policy.name = "trio"
          ; panels = [ base_group ]
          ; judge = "a"
          ; judge_system_prompt = "judge"
          ; judge_timeout_s = 300.0
          ; judge_max_output_tokens = None
          ; judges = []
          ; min_answered = Fusion_policy.default_min_answered
          }
      ]
  }

let req ?(preset = "trio") ?(depth = Fusion_depth.Top) ?(trigger = Explicit_tool_call)
    ?(web_tools = false) () : fusion_request =
  { run_id = "r1"; keeper = "k"; prompt = "p"; preset; web_tools; depth; trigger }

let decide ?(policy = base_policy) r = Fusion_policy.decide ~policy r

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
   키퍼/LLM이 판단). 구조(enabled/preset/depth)만 통과하면 어떤 trigger든 Allow. *)
let test_low_confidence_trigger_allowed () =
  let r = req ~trigger:Low_confidence () in
  Alcotest.check gate "low_confidence label -> allow" (Allow r) (decide r)

let test_high_stakes_trigger_allowed () =
  let r = req ~trigger:(High_stakes "anything") () in
  Alcotest.check gate "high_stakes label -> allow" (Allow r) (decide r)

let test_allow () =
  let r = req () in
  Alcotest.check gate "all pass -> allow" (Allow r) (decide r)

(* --- config (RFC-0252 §9, RFC-0252-A) --- *)

let parse s = Otoml.Parser.from_string s

let test_config_absent () =
  match Fusion_config.of_toml (parse "foo = 1") with
  | Ok p -> Alcotest.(check bool) "absent [fusion] -> disabled" false p.Fusion_policy.enabled
  | Error _ -> Alcotest.fail "expected Ok disabled"

let valid_toml =
  {|
[fusion]
enabled = true
default_preset = "trio"
max_concurrent_panels = 2
max_concurrent_judges = 4
staged_judge_group_size = 3
[fusion.presets.trio]
web_tools = false
max_tool_calls_per_panel = 0
panel = ["a", "b", "c"]
judge = "j"
panel_system_prompt = "answer independently"
judge_system_prompt = "synthesize the panel"
|}

let test_config_valid () =
  match Fusion_config.of_toml (parse valid_toml) with
  | Ok p ->
    Alcotest.(check bool) "enabled" true p.Fusion_policy.enabled;
    Alcotest.(check int) "judge concurrency" 4 p.Fusion_policy.max_concurrent_judges;
    Alcotest.(check int) "staged judge group size" 3
      p.Fusion_policy.staged_judge_group_size;
    Alcotest.(check int) "one preset" 1 (List.length p.Fusion_policy.presets);
    (match p.Fusion_policy.presets with
     | [ vp ] ->
       let preset = raw vp in
       Alcotest.(check int) "one group (legacy desugar)" 1
         (List.length preset.Fusion_policy.panels);
       Alcotest.(check int) "three models total" 3
         (List.length (Fusion_policy.preset_models preset));
       (match preset.Fusion_policy.panels with
        | [ g ] ->
          Alcotest.(check bool) "web_tools" false g.Fusion_policy.web_tools;
          Alcotest.(check int) "max_tool_calls" 0 g.Fusion_policy.max_tool_calls;
          Alcotest.(check (option int)) "max_output_tokens default" None
            g.Fusion_policy.max_output_tokens
        | _ -> Alcotest.fail "expected one group")
     | _ -> Alcotest.fail "expected exactly one preset")
  | Error es ->
    Alcotest.failf "expected Ok, got errors: %s"
      (String.concat ", " (List.map Fusion_config.show_config_error es))

(* --- byte-identity: legacy flat preset == single explicit panel group --- *)

let golden_flat_toml =
  {|
[fusion]
enabled = true
default_preset = "p"
[fusion.presets.p]
web_tools = true
max_tool_calls_per_panel = 4
max_output_tokens_per_panel = 2048
panel_timeout_s = 123.0
panel = ["a", "b", "c"]
judge = "j"
panel_system_prompt = "answer independently"
judge_system_prompt = "synthesize"
judge_timeout_s = 99.0
judge_max_output_tokens = 1024
|}

let golden_single_group_toml =
  {|
[fusion]
enabled = true
default_preset = "p"
[fusion.presets.p]
judge = "j"
judge_system_prompt = "synthesize"
judge_timeout_s = 99.0
judge_max_output_tokens = 1024
[[fusion.presets.p.panels]]
panel = ["a", "b", "c"]
panel_system_prompt = "answer independently"
web_tools = true
max_tool_calls_per_panel = 4
max_output_tokens_per_panel = 2048
panel_timeout_s = 123.0
|}

let test_config_panels_golden () =
  match
    Fusion_config.of_toml (parse golden_flat_toml),
    Fusion_config.of_toml (parse golden_single_group_toml)
  with
  | Ok flat, Ok grouped ->
    Alcotest.check preset_t "length-1 panels-list == flat desugar"
      (raw (List.hd flat.Fusion_policy.presets))
      (raw (List.hd grouped.Fusion_policy.presets));
    (* legacy(라벨 없음) 패널 정체성 = model 그대로 → 정체성 축도 byte-identical
       (RFC-0278). 라벨이 도입돼도 기존 config의 정체성은 변하지 않는다. *)
    Alcotest.(check (list string)) "legacy panelist ids = models"
      [ "a"; "b"; "c" ]
      (Fusion_policy.preset_panelist_ids (raw (List.hd flat.Fusion_policy.presets)))
  | _ -> Alcotest.fail "both must parse Ok"

(* --- heterogeneous multi-group parse --- *)

let multi_group_toml =
  {|
[fusion]
enabled = true
default_preset = "mixed"
[fusion.presets.mixed]
judge = "j"
judge_system_prompt = "synthesize"
[[fusion.presets.mixed.panels]]
panel = ["fast1", "fast2"]
panel_system_prompt = "quick"
web_tools = false
max_tool_calls_per_panel = 0
[[fusion.presets.mixed.panels]]
panel = ["careful1"]
panel_system_prompt = "deliberate"
web_tools = true
max_tool_calls_per_panel = 4
panel_timeout_s = 180.0
|}

let test_config_heterogeneous () =
  match Fusion_config.of_toml (parse multi_group_toml) with
  | Ok p ->
    (match p.Fusion_policy.presets with
     | [ vp ] ->
       let preset = raw vp in
       Alcotest.(check int) "two groups" 2 (List.length preset.Fusion_policy.panels);
       Alcotest.(check int) "three models total" 3
         (List.length (Fusion_policy.preset_models preset));
       (match preset.Fusion_policy.panels with
        | [ g1; g2 ] ->
          Alcotest.(check bool) "g1 no web" false g1.Fusion_policy.web_tools;
          Alcotest.(check bool) "g2 web" true g2.Fusion_policy.web_tools;
          Alcotest.(check int) "g2 tool budget" 4 g2.Fusion_policy.max_tool_calls;
          Alcotest.(check (option int)) "g1 default max output" None
            g1.Fusion_policy.max_output_tokens;
          Alcotest.(check (float 0.001)) "g2 timeout" 180.0 g2.Fusion_policy.timeout_s;
          Alcotest.(check (float 0.001)) "g1 default timeout"
            Fusion_policy.default_timeout_s g1.Fusion_policy.timeout_s
        | _ -> Alcotest.fail "expected two groups")
     | _ -> Alcotest.fail "expected exactly one preset")
  | Error es ->
    Alcotest.failf "expected Ok, got errors: %s"
      (String.concat ", " (List.map Fusion_config.show_config_error es))

(* --- strict config errors (Unknown→Permissive 회피) --- *)

let test_config_empty_panels () =
  let s =
    {|
[fusion]
enabled = true
default_preset = "p"
[fusion.presets.p]
panels = []
judge = "j"
judge_system_prompt = "x"
|}
  in
  match Fusion_config.of_toml (parse s) with
  | Error es ->
    Alcotest.(check bool) "Empty_panels present" true
      (List.mem (Fusion_config.Empty_panels "p") es)
  | Ok _ -> Alcotest.fail "expected Error Empty_panels"

let test_config_conflicting_grammar () =
  let s =
    {|
[fusion]
enabled = true
default_preset = "p"
[fusion.presets.p]
panel = ["a"]
panel_system_prompt = "y"
judge = "j"
judge_system_prompt = "x"
[[fusion.presets.p.panels]]
panel = ["b"]
panel_system_prompt = "z"
|}
  in
  match Fusion_config.of_toml (parse s) with
  | Error es ->
    Alcotest.(check bool) "Conflicting_panel_grammar present" true
      (List.mem (Fusion_config.Conflicting_panel_grammar "p") es)
  | Ok _ -> Alcotest.fail "expected Error Conflicting_panel_grammar"

(* 라벨 없는 두 그룹의 동일 model → 같은 정체성("dup") → Duplicate_panelist. *)
let test_config_duplicate_panelist () =
  let s =
    {|
[fusion]
enabled = true
default_preset = "p"
[fusion.presets.p]
judge = "j"
judge_system_prompt = "x"
[[fusion.presets.p.panels]]
panel = ["dup", "other"]
panel_system_prompt = "y"
[[fusion.presets.p.panels]]
panel = ["dup"]
panel_system_prompt = "z"
|}
  in
  match Fusion_config.of_toml (parse s) with
  | Error es ->
    Alcotest.(check bool) "Duplicate_panelist present" true
      (List.mem (Fusion_config.Duplicate_panelist ("p", "dup")) es)
  | Ok _ -> Alcotest.fail "expected Error Duplicate_panelist"

(* 같은 model을 서로 다른 라벨로 둔 두 그룹(persona ensemble) → 정체성이 달라
   ["skeptic (claude)"; "optimist (claude)"] → Ok. RFC-0278의 핵심 시나리오. *)
let same_model_diff_prompt_toml =
  {|
[fusion]
enabled = true
default_preset = "dialectic"
[fusion.presets.dialectic]
judge = "j"
judge_system_prompt = "synthesize"
[[fusion.presets.dialectic.panels]]
panel = ["claude"]
label = "skeptic"
panel_system_prompt = "argue against"
[[fusion.presets.dialectic.panels]]
panel = ["claude"]
label = "optimist"
panel_system_prompt = "argue for"
|}

let test_config_same_model_diff_prompt () =
  match Fusion_config.of_toml (parse same_model_diff_prompt_toml) with
  | Ok p ->
    (match p.Fusion_policy.presets with
     | [ vp ] ->
       let preset = raw vp in
       Alcotest.(check int) "two groups" 2 (List.length preset.Fusion_policy.panels);
       Alcotest.(check int) "two models total (same id twice raw)" 2
         (List.length (Fusion_policy.preset_models preset));
       Alcotest.(check (list string)) "distinct panelist identities"
         [ "skeptic (claude)"; "optimist (claude)" ]
         (Fusion_policy.preset_panelist_ids preset);
       Alcotest.(check bool) "no duplicate panelist" true
         (Fusion_policy.preset_duplicate_panelist preset = None)
     | _ -> Alcotest.fail "expected exactly one preset")
  | Error es ->
    Alcotest.failf "expected Ok, got errors: %s"
      (String.concat ", " (List.map Fusion_config.show_config_error es))

(* 같은 model을 라벨 없이 두 그룹에 두면 정체성 충돌 → Duplicate_panelist (모호성 거부). *)
let test_config_same_model_no_label_rejected () =
  let s =
    {|
[fusion]
enabled = true
default_preset = "p"
[fusion.presets.p]
judge = "j"
judge_system_prompt = "x"
[[fusion.presets.p.panels]]
panel = ["claude"]
panel_system_prompt = "a"
[[fusion.presets.p.panels]]
panel = ["claude"]
panel_system_prompt = "b"
|}
  in
  match Fusion_config.of_toml (parse s) with
  | Error es ->
    Alcotest.(check bool) "Duplicate_panelist (claude) present" true
      (List.mem (Fusion_config.Duplicate_panelist ("p", "claude")) es)
  | Ok _ -> Alcotest.fail "expected Error Duplicate_panelist (no label, same model)"

(* panelist_id SSOT: 라벨 없으면 model 그대로(byte-identity), 있으면 "label (model)". *)
let test_panelist_id () =
  Alcotest.(check string) "no label -> model" "claude"
    (Fusion_policy.panelist_id ~label:"" ~model:"claude");
  Alcotest.(check string) "label -> label (model)" "skeptic (claude)"
    (Fusion_policy.panelist_id ~label:"skeptic" ~model:"claude")

(* panelist_id 포맷("%s (%s)")은 단사가 아니다: label=""+model="skeptic (claude)"와
   label="skeptic"+model="claude"가 같은 "skeptic (claude)"로 렌더된다. 이 둘은 정체성
   namespace에서 실제로 충돌(심판이 동일 태그 둘을 구분 못 함)하므로, 같은 렌더 정체성을
   parse-time에 거부하는 것이 sound하다 — fail-closed (silent 손실 아님). 현실 provider.model
   id는 " (...)"를 포함하지 않아 latent하지만, 비단사 경계의 거부 동작을 핀한다. *)
let test_config_panelist_id_collision_fail_closed () =
  let s =
    {|
[fusion]
enabled = true
default_preset = "p"
[fusion.presets.p]
judge = "j"
judge_system_prompt = "x"
[[fusion.presets.p.panels]]
panel = ["skeptic (claude)"]
panel_system_prompt = "a"
[[fusion.presets.p.panels]]
panel = ["claude"]
label = "skeptic"
panel_system_prompt = "b"
|}
  in
  match Fusion_config.of_toml (parse s) with
  | Error es ->
    Alcotest.(check bool) "Duplicate_panelist (skeptic (claude)) present" true
      (List.mem (Fusion_config.Duplicate_panelist ("p", "skeptic (claude)")) es)
  | Ok _ ->
    Alcotest.fail "expected Error Duplicate_panelist (non-injective panelist_id collision)"

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

let test_config_invalid_min_answered () =
  let check_invalid value =
    let s =
      Printf.sprintf
        {|
[fusion]
enabled = true
default_preset = "p"
[fusion.presets.p]
panel = ["a", "b"]
panel_system_prompt = "y"
judge = "j"
judge_system_prompt = "x"
min_answered = %d
|}
        value
    in
    match Fusion_config.of_toml (parse s) with
    | Error es ->
      Alcotest.(check bool) "Invalid_min_answered present" true
        (List.mem (Fusion_config.Invalid_min_answered ("p", value)) es)
    | Ok _ -> Alcotest.fail "expected Error Invalid_min_answered"
  in
  check_invalid 0;
  check_invalid (-1);
  (* 2 panels -> max allowed is 2, so 3 is out of range *)
  check_invalid 3

let test_config_missing_default () =
  let s =
    {|
[fusion]
enabled = true
default_preset = "ghost"
[fusion.presets.trio]
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

let test_config_bad_judge_concurrency () =
  let s =
    {|
[fusion]
enabled = true
default_preset = "p1"
max_concurrent_judges = 0
[fusion.presets.p1]
panel = ["a", "b"]
judge = "a"
panel_system_prompt = "p"
judge_system_prompt = "j"
|}
  in
  match Fusion_config.of_toml (parse s) with
  | Error es ->
    Alcotest.(check bool) "Invalid_max_concurrent_judges present" true
      (List.mem (Fusion_config.Invalid_max_concurrent_judges 0) es)
  | Ok _ -> Alcotest.fail "expected Error Invalid_max_concurrent_judges"

let test_config_bad_staged_judge_group_size () =
  let s =
    {|
[fusion]
enabled = true
default_preset = "p1"
staged_judge_group_size = 1
[fusion.presets.p1]
panel = ["a", "b"]
judge = "a"
panel_system_prompt = "p"
judge_system_prompt = "j"
|}
  in
  match Fusion_config.of_toml (parse s) with
  | Error es ->
    Alcotest.(check bool) "Invalid_staged_judge_group_size present" true
      (List.mem (Fusion_config.Invalid_staged_judge_group_size 1) es)
  | Ok _ -> Alcotest.fail "expected Error Invalid_staged_judge_group_size"

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

let test_config_invalid_max_output_tokens () =
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
max_output_tokens_per_panel = 0
judge_max_output_tokens = -1
|}
  in
  match Fusion_config.of_toml (parse s) with
  | Error es ->
    Alcotest.(check bool) "Invalid_max_output_tokens present" true
      (List.exists
         (function Fusion_config.Invalid_max_output_tokens _ -> true | _ -> false)
         es)
  | Ok _ -> Alcotest.fail "expected Error Invalid_max_output_tokens"

(* enabled인데 default_preset 생략(="") → preset 생략 호출이 폭빽할 default가 없어
   항상 Preset_unknown ""로 deny. 빈 default_preset도 로드 거부. *)
let test_config_empty_default_preset () =
  let s =
    {|
[fusion]
enabled = true
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

(* Mirrors the disabled [fusion] seed shipped in config/runtime.toml: a populated
   default_preset + trio panel while enabled=false must parse to [Ok]
   (Empty_presets / Missing_default_preset are enabled-gated). Pins the
   seed-template structure (legacy flat grammar) against parser drift. *)
let seed_disabled_toml =
  {|
[fusion]
enabled = false
default_preset = "trio"
max_concurrent_panels = 2
max_concurrent_judges = 3
staged_judge_group_size = 3
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
    Alcotest.(check int) "seed judge concurrency" 3
      p.Fusion_policy.max_concurrent_judges;
    Alcotest.(check int) "seed staged group size" 3
      p.Fusion_policy.staged_judge_group_size;
    Alcotest.(check int) "trio preset present" 1 (List.length p.Fusion_policy.presets);
    (match p.Fusion_policy.presets with
     | [ vp ] ->
       let preset = raw vp in
       Alcotest.(check int) "trio panel size (flattened)" 3
         (List.length (Fusion_policy.preset_models preset))
     | _ -> Alcotest.fail "expected exactly one preset")
  | Error es ->
    Alcotest.failf "seed [fusion] must parse, got errors: %s"
      (String.concat ", " (List.map Fusion_config.show_config_error es))

(* --- RFC-0280: Validated_preset.of_preset smart constructor (검증 SSOT) ---
   config의 config_error 매핑과 별개로 smart constructor 자체를 직접 핀한다. 각 테스트는
   목표 결함 하나만 두고 나머지는 유효하게 해, 검증 순서(size→prompt→judge→dup→mtc)에서
   그 변형이 발화하는지 확인한다. private 타입이라 외부는 of_preset로만 t를 만든다. *)
let mk_preset ?(panels = [ base_group ]) ?(judge = "j") ?(judge_prompt = "synthesize")
    ?(judges = []) ?(min_answered = Fusion_policy.default_min_answered)
    (name : string) : Fusion_policy.preset =
  { Fusion_policy.name
  ; panels
  ; judge
  ; judge_system_prompt = judge_prompt
  ; judge_timeout_s = 300.0
  ; judge_max_output_tokens = None
  ; judges
  ; min_answered
  }

let test_validated_ok () =
  match Fusion_policy.Validated_preset.of_preset (mk_preset "ok") with
  | Ok vp ->
    Alcotest.(check int) "validated preset reads panels via coercion" 1
      (List.length (raw vp).Fusion_policy.panels)
  | Error _ -> Alcotest.fail "expected Ok for a valid preset"

let test_validated_bad_size () =
  let empty_group = { base_group with Fusion_policy.models = [] } in
  match
    Fusion_policy.Validated_preset.of_preset (mk_preset ~panels:[ empty_group ] "empty")
  with
  | Error (Fusion_policy.Validated_preset.Bad_size 0) -> ()
  | _ -> Alcotest.fail "expected Bad_size 0 for zero models"

let test_validated_missing_prompt () =
  let no_prompt = { base_group with Fusion_policy.system_prompt = "" } in
  match Fusion_policy.Validated_preset.of_preset (mk_preset ~panels:[ no_prompt ] "np") with
  | Error Fusion_policy.Validated_preset.Missing_prompt -> ()
  | _ -> Alcotest.fail "expected Missing_prompt for empty system_prompt"

let test_validated_missing_judge () =
  match Fusion_policy.Validated_preset.of_preset (mk_preset ~judge:"" "nj") with
  | Error Fusion_policy.Validated_preset.Missing_judge_model -> ()
  | _ -> Alcotest.fail "expected Missing_judge_model for empty judge"

let test_validated_duplicate_panelist () =
  let g model = { base_group with Fusion_policy.models = [ model ] } in
  match
    Fusion_policy.Validated_preset.of_preset (mk_preset ~panels:[ g "x"; g "x" ] "dup")
  with
  | Error (Fusion_policy.Validated_preset.Duplicate_panelist "x") -> ()
  | _ -> Alcotest.fail "expected Duplicate_panelist x for same model no label"

let test_validated_bad_max_tool_calls () =
  let over =
    { base_group with Fusion_policy.max_tool_calls = Fusion_policy.max_tool_calls_ceiling + 1 }
  in
  match Fusion_policy.Validated_preset.of_preset (mk_preset ~panels:[ over ] "mtc") with
  | Error (Fusion_policy.Validated_preset.Bad_max_tool_calls v) ->
    Alcotest.(check int) "over-ceiling value reported" 17 v
  | _ -> Alcotest.fail "expected Bad_max_tool_calls over ceiling"

let test_validated_bad_max_output_tokens () =
  let bad = { base_group with Fusion_policy.max_output_tokens = Some 0 } in
  match Fusion_policy.Validated_preset.of_preset (mk_preset ~panels:[ bad ] "mot") with
  | Error (Fusion_policy.Validated_preset.Bad_max_output_tokens 0) -> ()
  | _ -> Alcotest.fail "expected Bad_max_output_tokens 0"

(* --- JOJ 1차 심판 목록 검증 (RFC-0283) --- *)

let base_judge : Fusion_policy.judge_spec =
  { Fusion_policy.jmodel = "jm"
  ; jlabel = ""
  ; jsystem_prompt = "lens"
  ; jweb_tools = false
  ; jmax_tool_calls = 0
  ; jmax_output_tokens = None
  ; jtimeout_s = 300.0
  }

(* judges=[]면 (simple/refine/conditional preset) 기존과 동일하게 유효 = byte-identity. *)
let test_validated_judges_empty_ok () =
  match Fusion_policy.Validated_preset.of_preset (mk_preset ~judges:[] "je") with
  | Ok _ -> ()
  | Error _ -> Alcotest.fail "empty judges must stay valid (simple/refine/conditional)"

(* 두 1차 심판이 같은 lens(다른 model)면 통과; 같은 정체성이면 Duplicate_judge. *)
let test_validated_judges_ok () =
  let j m = { base_judge with Fusion_policy.jmodel = m } in
  match Fusion_policy.Validated_preset.of_preset (mk_preset ~judges:[ j "a"; j "b" ] "jok") with
  | Ok _ -> ()
  | Error _ -> Alcotest.fail "distinct judge models must validate"

let test_validated_judge_prompt_missing () =
  let no_lens = { base_judge with Fusion_policy.jsystem_prompt = "" } in
  match
    Fusion_policy.Validated_preset.of_preset (mk_preset ~judges:[ base_judge; no_lens ] "jnp")
  with
  | Error Fusion_policy.Validated_preset.Judge_panel_prompt_missing -> ()
  | _ -> Alcotest.fail "expected Judge_panel_prompt_missing for empty judge lens"

let test_validated_duplicate_judge () =
  let j m = { base_judge with Fusion_policy.jmodel = m } in
  match
    Fusion_policy.Validated_preset.of_preset (mk_preset ~judges:[ j "x"; j "x" ] "jdup")
  with
  | Error (Fusion_policy.Validated_preset.Duplicate_judge "x") -> ()
  | _ -> Alcotest.fail "expected Duplicate_judge x for same judge identity"

let test_validated_judge_bad_max_tool_calls () =
  let over =
    { base_judge with
      Fusion_policy.jmax_tool_calls = Fusion_policy.max_tool_calls_ceiling + 1
    }
  in
  (* 단일 over-ceiling judge — panel-side test_validated_bad_max_tool_calls(~panels:[ over ])와
     대칭. base_judge를 더하면 jmodel="jm" 정체성이 겹쳐 Duplicate_judge가 먼저 발동하므로,
     max_tool_calls 검사에 도달하려면 정체성 충돌이 없어야 한다. judges는 of_preset 레벨에서
     최소 개수 요구가 없다(JOJ <2 에러는 orchestrator 런타임 책임). *)
  match Fusion_policy.Validated_preset.of_preset (mk_preset ~judges:[ over ] "jmtc") with
  | Error (Fusion_policy.Validated_preset.Bad_max_tool_calls 17) -> ()
  | _ -> Alcotest.fail "expected Bad_max_tool_calls 17 for over-ceiling judge"

let test_validated_judge_bad_max_output_tokens () =
  let bad = { base_judge with Fusion_policy.jmax_output_tokens = Some (-1) } in
  match Fusion_policy.Validated_preset.of_preset (mk_preset ~judges:[ bad ] "jmot") with
  | Error (Fusion_policy.Validated_preset.Bad_max_output_tokens (-1)) -> ()
  | _ -> Alcotest.fail "expected Bad_max_output_tokens -1 for judge"

let judge_named model = { base_judge with Fusion_policy.jmodel = model }

let test_staged_judge_groups_exact_3x3 () =
  let judges = List.init 9 (fun i -> judge_named (Printf.sprintf "j%d" (i + 1))) in
  match Fusion_policy.staged_judge_groups ~group_size:3 judges with
  | Ok groups ->
    Alcotest.(check int) "three groups" 3 (List.length groups);
    Alcotest.(check (list int)) "3x3 group sizes" [ 3; 3; 3 ]
      (List.map List.length groups);
    (match groups with
     | first :: _ ->
       (match first with
        | j :: _ -> Alcotest.(check string) "first judge preserved" "j1" j.Fusion_policy.jmodel
        | [] -> Alcotest.fail "first group should not be empty")
     | [] -> Alcotest.fail "expected groups")
  | Error e ->
    Alcotest.failf "expected 3x3 groups, got %s"
      (Fusion_policy.show_staged_judge_group_error e)

let test_staged_judge_groups_too_few () =
  let judges = List.init 5 (fun i -> judge_named (Printf.sprintf "j%d" (i + 1))) in
  match Fusion_policy.staged_judge_groups ~group_size:3 judges with
  | Error (Fusion_policy.Staged_too_few_judges { group_size = 3; judges = 5 }) -> ()
  | _ -> Alcotest.fail "expected Staged_too_few_judges for 5 judges at group size 3"

let test_staged_judge_groups_ragged () =
  let judges = List.init 8 (fun i -> judge_named (Printf.sprintf "j%d" (i + 1))) in
  match Fusion_policy.staged_judge_groups ~group_size:3 judges with
  | Error (Fusion_policy.Staged_ragged_judges { group_size = 3; judges = 8 }) -> ()
  | _ -> Alcotest.fail "expected Staged_ragged_judges for 8 judges at group size 3"

let test_staged_judge_groups_bad_size () =
  match Fusion_policy.staged_judge_groups ~group_size:1 [ judge_named "j1"; judge_named "j2" ] with
  | Error (Fusion_policy.Staged_group_size_below_min 1) -> ()
  | _ -> Alcotest.fail "expected Staged_group_size_below_min"

(* --- JOJ 1차 심판 TOML 파싱 (RFC-0283). parse_judge_spec + finish_preset의
       [[...judges]] array-of-tables 리더를 end-to-end로 검증한다. 위 of_preset
       검증 테스트는 OCaml record를 직접 구성해 config 레이어를 우회하므로, TOML 키
       이름(model/label/system_prompt/web_tools/max_tool_calls/timeout_s)과 getter
       매핑은 이 테스트만 커버한다 — 잘못된 키/getter는 여기서만 잡힌다. panel
       sub-table에는 동형 golden(test_config_panels_golden 등)이 있으나 judge에는
       없었다. --- *)
let judges_toml =
  {|
[fusion]
enabled = true
default_preset = "joj"
[fusion.presets.joj]
judge = "meta-model"
judge_system_prompt = "reconcile"
[[fusion.presets.joj.panels]]
panel = ["p1", "p2"]
panel_system_prompt = "answer"
[[fusion.presets.joj.judges]]
model = "judge-a"
label = "strict"
system_prompt = "lens A"
web_tools = true
max_tool_calls = 3
max_output_tokens = 1536
timeout_s = 222.0
[[fusion.presets.joj.judges]]
model = "judge-b"
label = "lenient"
system_prompt = "lens B"
|}

let test_config_judges_parse () =
  match Fusion_config.of_toml (parse judges_toml) with
  | Ok p ->
    (match p.Fusion_policy.presets with
     | [ vp ] ->
       (match (raw vp).Fusion_policy.judges with
        | [ ja; jb ] ->
          (* judge-a: 6개 키를 모두 distinct 값으로 채워 키↔getter 매핑을 핀한다. *)
          Alcotest.(check string) "ja model" "judge-a" ja.Fusion_policy.jmodel;
          Alcotest.(check string) "ja label" "strict" ja.Fusion_policy.jlabel;
          Alcotest.(check string) "ja prompt" "lens A" ja.Fusion_policy.jsystem_prompt;
          Alcotest.(check bool) "ja web" true ja.Fusion_policy.jweb_tools;
          Alcotest.(check int) "ja tool budget" 3 ja.Fusion_policy.jmax_tool_calls;
          Alcotest.(check (option int)) "ja max output" (Some 1536)
            ja.Fusion_policy.jmax_output_tokens;
          Alcotest.(check (float 0.001)) "ja timeout" 222.0 ja.Fusion_policy.jtimeout_s;
          (* judge-b: 누락 키는 find_or default 경로 (web=false / budget=0 / timeout=default). *)
          Alcotest.(check string) "jb model" "judge-b" jb.Fusion_policy.jmodel;
          Alcotest.(check string) "jb prompt" "lens B" jb.Fusion_policy.jsystem_prompt;
          Alcotest.(check bool) "jb web default" false jb.Fusion_policy.jweb_tools;
          Alcotest.(check int) "jb budget default" 0 jb.Fusion_policy.jmax_tool_calls;
          Alcotest.(check (option int)) "jb max output default" None
            jb.Fusion_policy.jmax_output_tokens;
          Alcotest.(check (float 0.001)) "jb timeout default"
            Fusion_policy.default_timeout_s jb.Fusion_policy.jtimeout_s
        | _ -> Alcotest.fail "expected exactly two parsed judges")
     | _ -> Alcotest.fail "expected exactly one preset")
  | Error es ->
    Alcotest.failf "expected Ok, got errors: %s"
      (String.concat ", " (List.map Fusion_config.show_config_error es))

(* judges sub-table 없는 preset → preset.judges = [] (단일 심판 위상 config). *)
let test_config_no_judges () =
  match Fusion_config.of_toml (parse golden_single_group_toml) with
  | Ok p ->
    (match p.Fusion_policy.presets with
     | [ vp ] ->
       Alcotest.(check int) "no judges sub-table = empty list" 0
         (List.length (raw vp).Fusion_policy.judges)
     | _ -> Alcotest.fail "expected one preset")
  | Error _ -> Alcotest.fail "golden must parse Ok"

(* --- execution-axis byte-identity: judge args + outer timeout derivations
       (RFC-0252-A §4.4, fixes adversarial findings 1.1/1.2/1.3). A single
       group must reproduce today's judge/outer-timeout mapping; the parse-level
       golden cannot see this (it compares two new-shape records), so it is
       pinned here on the pure derivations. --- *)

let g_web4 : Fusion_policy.panel_group =
  { Fusion_policy.models = [ "a" ]
  ; label = ""
  ; system_prompt = "p"
  ; web_tools = true
  ; max_tool_calls = 4
  ; max_output_tokens = None
  ; timeout_s = 123.0
  }

let test_judge_args_single_group_identity () =
  let groups = [ g_web4 ] in
  Alcotest.(check (float 0.001)) "outer timeout = sole group timeout" 123.0
    (Fusion_policy.panel_outer_timeout_of groups);
  Alcotest.(check bool) "judge web = req||group, req=false, group=true" true
    (Fusion_policy.judge_web_tools_of ~req_web_tools:false groups);
  Alcotest.(check bool) "judge web = req||group, both false" false
    (Fusion_policy.judge_web_tools_of ~req_web_tools:false
       [ { g_web4 with Fusion_policy.web_tools = false } ]);
  Alcotest.(check bool) "judge web = req||group, req=true overrides" true
    (Fusion_policy.judge_web_tools_of ~req_web_tools:true
       [ { g_web4 with Fusion_policy.web_tools = false } ]);
  Alcotest.(check int) "judge tool budget = sole group" 4
    (Fusion_policy.judge_tool_budget_of groups)

let test_judge_args_multi_group () =
  let g_unlimited = { g_web4 with Fusion_policy.models = [ "x" ]; max_tool_calls = 0 } in
  let g_slow = { g_web4 with Fusion_policy.models = [ "y" ]; timeout_s = 200.0 } in
  Alcotest.(check (float 0.001)) "outer timeout = max over groups" 200.0
    (Fusion_policy.panel_outer_timeout_of [ g_web4; g_slow ]);
  Alcotest.(check int) "judge tool budget: 0 (unlimited) absorbs" 0
    (Fusion_policy.judge_tool_budget_of [ g_web4; g_unlimited ]);
  Alcotest.(check int) "judge tool budget: max when none unlimited" 4
    (Fusion_policy.judge_tool_budget_of
       [ { g_web4 with Fusion_policy.models = [ "z" ]; max_tool_calls = 2 }; g_web4 ])

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

(* ---- 심의 위상(topology) ---------------------------------------------- *)

(* round-trip drift-guard: of_string(to_string t) = Some t (전수). 닫힌 합이라
   forward는 컴파일러가 보장하지만 역방향(string→variant)은 string 입력이라 강제되지
   않으므로 여기서 핀(closed-sum-string-whitelist 안티패턴의 역방향 단언). *)
let test_topology_roundtrip () =
  List.iter
    (fun t ->
      Alcotest.(check (option string))
        (Printf.sprintf "roundtrip %s" (fusion_topology_to_string t))
        (Some (fusion_topology_to_string t))
        (Option.map fusion_topology_to_string
           (fusion_topology_of_string (fusion_topology_to_string t))))
    all_fusion_topologies

(* fail-closed: 닫힌 합 밖(오타·대문자·빈문자열·미래 위상명)은 None. *)
let test_topology_unknown_is_none () =
  List.iter
    (fun s ->
      Alcotest.(check bool)
        (Printf.sprintf "unknown %S -> None" s)
        true
        (Option.is_none (fusion_topology_of_string s)))
    [ ""; "Simple"; "REFINE"; "Judge_of_judges"; "joj"; "bogus"; " simple" ]

(* wire vocabulary 핀 — 도구 스키마 허용값/에러 메시지가 이 목록에서 파생된다. *)
let test_topology_strings () =
  Alcotest.(check (list string))
    "all topology wire strings"
    [ "simple"; "refine"; "conditional"; "judge_of_judges"; "staged_judge_of_judges" ]
    all_fusion_topology_strings

(* Conditional 에스컬레이트 정책 — 닫힌 합 전수 값-핀. Insufficient만 escalate. *)
let test_escalation_policy () =
  Alcotest.(check bool) "Insufficient escalates" true
    (decision_warrants_escalation (Insufficient { missing_for_decision = [ "x" ] }));
  Alcotest.(check bool) "Answer does not escalate" false
    (decision_warrants_escalation (Answer "done"));
  Alcotest.(check bool) "Recommend does not escalate" false
    (decision_warrants_escalation (Recommend { action = "a"; rationale = "r" }))

(* ---- render_prior_synthesis (refine 프롬프트 입력) --------------------- *)

let str_contains ~needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  if nl = 0 then true
  else begin
    let rec scan i =
      if i + nl > hl then false
      else if String.equal (String.sub haystack i nl) needle then true
      else scan (i + 1)
    in
    scan 0
  end

let full_synthesis decision : judge_synthesis =
  { consensus = [ { text = "C-TEXT"; supporting_models = [ "m1"; "m2" ] } ]
  ; contradictions =
      [ { topic = "TOPIC-X"
        ; positions = [ ("m1", "yes"); ("m2", "no") ]
        ; evidence = [ "EV-1" ]
        }
      ]
  ; partial_coverage =
      [ { gap_topic = "GAP-Y"; addressed_by = [ "m1" ]; missing = Some "MISS-Z" } ]
  ; unique_insights = [ { insight_text = "INSIGHT-W"; from_model = "m3" } ]
  ; blind_spots = [ "BLIND-V" ]
  ; resolved_answer = "RESOLVED-U"
  ; decision
  }

let check_contains label needle hay =
  Alcotest.(check bool) (Printf.sprintf "contains %s" label) true
    (str_contains ~needle hay)

(* lossless: 7필드 전부 렌더 문자열에 살아남는다 (resolved_answer로 collapse하지 않음 —
   B2/워크어라운드#2 회피의 회귀 가드). *)
let test_render_lossless_fields () =
  let r = render_prior_synthesis (full_synthesis (Answer "ANS-T")) in
  check_contains "consensus text" "C-TEXT" r;
  check_contains "supporting model" "m2" r;
  check_contains "contradiction topic" "TOPIC-X" r;
  check_contains "contradiction stance" "no" r;
  check_contains "evidence" "EV-1" r;
  check_contains "coverage gap" "GAP-Y" r;
  check_contains "coverage missing" "MISS-Z" r;
  check_contains "insight" "INSIGHT-W" r;
  check_contains "insight model" "m3" r;
  check_contains "blind spot" "BLIND-V" r;
  check_contains "resolved answer" "RESOLVED-U" r

(* decision 닫힌 합 3변형이 서로 구분되게 렌더된다 (exhaustive match, catch-all 없음). *)
let test_render_decision_answer () =
  let r = render_prior_synthesis (full_synthesis (Answer "ANS-T")) in
  check_contains "answer decision" "Answer: ANS-T" r

let test_render_decision_recommend () =
  let r =
    render_prior_synthesis
      (full_synthesis (Recommend { action = "ACT-R"; rationale = "WHY-R" }))
  in
  check_contains "recommend action" "ACT-R" r;
  check_contains "recommend rationale" "WHY-R" r

let test_render_decision_insufficient () =
  let r =
    render_prior_synthesis
      (full_synthesis (Insufficient { missing_for_decision = [ "NEED-A"; "NEED-B" ] }))
  in
  check_contains "insufficient label" "Insufficient" r;
  check_contains "insufficient missing a" "NEED-A" r;
  check_contains "insufficient missing b" "NEED-B" r

(* 빈 리스트는 "(none)"으로 렌더 — 섹션 구조가 항상 노출되어 테스트/모델이 의존 가능. *)
let test_render_empty_lists () =
  let empty : judge_synthesis =
    { consensus = []
    ; contradictions = []
    ; partial_coverage = []
    ; unique_insights = []
    ; blind_spots = []
    ; resolved_answer = ""
    ; decision = Answer ""
    }
  in
  let r = render_prior_synthesis empty in
  check_contains "consensus header" "CONSENSUS:" r;
  check_contains "blind spots header" "BLIND SPOTS:" r;
  check_contains "none placeholder" "(none)" r

(* --- RFC-0284: judge_outcome 관측 record yojson round-trip ---
   판 노드 관측이 직렬화/역직렬화 무손실인지(board judges:[] emit + 디스크/SSE 호환).
   First는 panelist_id를, decision 닫힌 합 3변형을, 성공/실패 노드를 모두 핀한다. *)
let test_judge_outcome_roundtrip () =
  let synth d : judge_synthesis =
    { consensus = [ { text = "c"; supporting_models = [ "m" ] } ]
    ; contradictions = []
    ; partial_coverage = []
    ; unique_insights = []
    ; blind_spots = [ "b" ]
    ; resolved_answer = "ra"
    ; decision = d }
  in
  let nodes =
    [ Synthesized
        { role = Single
        ; synthesis = synth (Answer "a")
        ; usage = { input_tokens = 1; output_tokens = 2 } }
    ; Synthesized
        { role = First "skeptic (claude)"
        ; synthesis = synth (Recommend { action = "do"; rationale = "why" })
        ; usage = zero_usage }
    ; Synthesized
        { role = Meta
        ; synthesis = synth (Insufficient { missing_for_decision = [ "x" ] })
        ; usage = zero_usage }
    ; Synthesized
        { role = Refine_pass; synthesis = synth (Answer "r"); usage = zero_usage }
    ; Judge_failed
        { failed_role = Meta
        ; error = "boom"
        ; usage = { input_tokens = 9; output_tokens = 10 }
        }
    ]
  in
  List.iter
    (fun o ->
      match judge_outcome_of_yojson (judge_outcome_to_yojson o) with
      | Ok o' ->
        Alcotest.(check bool) "judge_outcome roundtrip" true (equal_judge_outcome o o')
      | Error e -> Alcotest.failf "judge_outcome roundtrip failed: %s" e)
    nodes

(* RFC-0252 all-panel-fail guard: 0 answered panels => judge skipped with a
   typed quorum reason; >= 1 answered => judge runs. Reverting [judge_skip_reason]
   to always-[None] turns the first two checks red (non-vacuous). *)
let test_judge_skip_reason () =
  let answered m a : panel_outcome = Answered { model = m; answer = a; usage = zero_usage } in
  let failed m : panel_outcome = Failed { failed_model = m; reason = Provider_error "x" } in
  let skips ~min_answered os = Option.is_some (judge_skip_reason ~min_answered os) in
  (* default floor 1: all-failed/empty => skip; >= 1 answered => run *)
  Alcotest.(check bool) "min1 all failed => skip" true
    (skips ~min_answered:1 [ failed "a"; failed "b" ]);
  Alcotest.(check bool) "min1 empty => skip" true (skips ~min_answered:1 []);
  Alcotest.(check bool) "min1 one answered => run" false
    (skips ~min_answered:1 [ failed "a"; answered "b" "hi" ]);
  (* quorum 2 (e.g. trio min_answered=2): 1 answered => skip, 2 answered => run *)
  Alcotest.(check bool) "min2 one answered => skip" true
    (skips ~min_answered:2 [ answered "a" "x"; failed "b"; failed "c" ]);
  Alcotest.(check bool) "min2 two answered => run" false
    (skips ~min_answered:2 [ answered "a" "x"; answered "b" "y"; failed "c" ]);
  (* skip reason reports structured quorum counts; rendering is boundary-only. *)
  match judge_skip_reason ~min_answered:2 [ answered "a" "x"; failed "b" ] with
  | Some (Quorum_not_met { answered; total; required } as reason) ->
    Alcotest.(check int) "answered count" 1 answered;
    Alcotest.(check int) "total count" 2 total;
    Alcotest.(check int) "required count" 2 required;
    Alcotest.(check string) "rendered reason"
      "fusion aborted: 1 of 2 panels answered, preset requires at least 2"
      (render_skip_reason reason)
  | None -> Alcotest.fail "expected skip when 1 < min_answered 2"

(* min_answered must be in the policy range 1..total panels (inclusive).
   base_group has 3 models, so 0 and 4 are rejected; full-panel quorum (3) is allowed. *)
let test_validated_bad_min_answered () =
  let check_bad mn label =
    match Fusion_policy.Validated_preset.of_preset (mk_preset ~min_answered:mn label) with
    | Error (Fusion_policy.Validated_preset.Min_answered_below_min got)
    | Error (Fusion_policy.Validated_preset.Min_answered_above_max got) ->
      Alcotest.(check int) (label ^ " reports value") mn got
    | _ -> Alcotest.failf "%s: expected min_answered error" label
  in
  check_bad 0 "min_answered=0";
  check_bad 4 "min_answered>panels";
  (* full-panel quorum is now allowed (3 answered required for 3 panels). *)
  (match Fusion_policy.Validated_preset.of_preset (mk_preset ~min_answered:3 "ok3") with
   | Ok _ -> ()
   | Error _ -> Alcotest.fail "min_answered=3 with 3 panels should be Ok");
  (* in-range stays Ok (3 models, require 2) *)
  match Fusion_policy.Validated_preset.of_preset (mk_preset ~min_answered:2 "ok2") with
  | Ok _ -> ()
  | Error _ -> Alcotest.fail "min_answered=2 with 3 panels should be Ok"

let test_min_answered_constants () =
  Alcotest.(check int) "default_min_answered" 1 Fusion_policy.default_min_answered;
  Alcotest.(check int) "min_answered_floor" 1 Fusion_policy.min_answered_floor

let () =
  Alcotest.run "fusion_core"
    [ ( "gate"
      , [ Alcotest.test_case "disabled" `Quick test_disabled
        ; Alcotest.test_case "unknown_preset" `Quick test_unknown_preset
        ; Alcotest.test_case "depth_nested" `Quick test_depth_nested
        ; Alcotest.test_case "low_confidence_trigger_allowed" `Quick
            test_low_confidence_trigger_allowed
        ; Alcotest.test_case "high_stakes_trigger_allowed" `Quick
            test_high_stakes_trigger_allowed
        ; Alcotest.test_case "allow" `Quick test_allow
        ] )
    ; ( "config"
      , [ Alcotest.test_case "absent" `Quick test_config_absent
        ; Alcotest.test_case "valid" `Quick test_config_valid
        ; Alcotest.test_case "panels_golden" `Quick test_config_panels_golden
        ; Alcotest.test_case "heterogeneous" `Quick test_config_heterogeneous
        ; Alcotest.test_case "empty_panels" `Quick test_config_empty_panels
        ; Alcotest.test_case "conflicting_grammar" `Quick test_config_conflicting_grammar
        ; Alcotest.test_case "duplicate_panelist" `Quick test_config_duplicate_panelist
        ; Alcotest.test_case "same_model_diff_prompt" `Quick
            test_config_same_model_diff_prompt
        ; Alcotest.test_case "same_model_no_label_rejected" `Quick
            test_config_same_model_no_label_rejected
        ; Alcotest.test_case "panelist_id" `Quick test_panelist_id
        ; Alcotest.test_case "panelist_id_collision_fail_closed" `Quick
            test_config_panelist_id_collision_fail_closed
        ; Alcotest.test_case "empty_presets" `Quick test_config_empty_presets
        ; Alcotest.test_case "invalid_size" `Quick test_config_invalid_size
        ; Alcotest.test_case "invalid_min_answered" `Quick
            test_config_invalid_min_answered
        ; Alcotest.test_case "missing_default" `Quick test_config_missing_default
        ; Alcotest.test_case "missing_prompt" `Quick test_config_missing_prompt
        ; Alcotest.test_case "missing_judge_model" `Quick test_config_missing_judge_model
        ; Alcotest.test_case "bad_concurrency" `Quick test_config_bad_concurrency
        ; Alcotest.test_case "bad_judge_concurrency" `Quick
            test_config_bad_judge_concurrency
        ; Alcotest.test_case "bad_staged_judge_group_size" `Quick
            test_config_bad_staged_judge_group_size
        ; Alcotest.test_case "invalid_max_tool_calls" `Quick
            test_config_invalid_max_tool_calls
        ; Alcotest.test_case "invalid_max_output_tokens" `Quick
            test_config_invalid_max_output_tokens
        ; Alcotest.test_case "empty_default_preset" `Quick test_config_empty_default_preset
        ; Alcotest.test_case "disabled_with_preset" `Quick test_config_disabled_with_preset
        ; Alcotest.test_case "judges_parse" `Quick test_config_judges_parse
        ; Alcotest.test_case "no_judges" `Quick test_config_no_judges
        ] )
    ; ( "validated_preset"
      , [ Alcotest.test_case "ok" `Quick test_validated_ok
        ; Alcotest.test_case "bad_size" `Quick test_validated_bad_size
        ; Alcotest.test_case "missing_prompt" `Quick test_validated_missing_prompt
        ; Alcotest.test_case "missing_judge" `Quick test_validated_missing_judge
        ; Alcotest.test_case "duplicate_panelist" `Quick test_validated_duplicate_panelist
        ; Alcotest.test_case "bad_max_tool_calls" `Quick test_validated_bad_max_tool_calls
        ; Alcotest.test_case "bad_max_output_tokens" `Quick
            test_validated_bad_max_output_tokens
        ; Alcotest.test_case "judges_empty_ok" `Quick test_validated_judges_empty_ok
        ; Alcotest.test_case "judges_ok" `Quick test_validated_judges_ok
        ; Alcotest.test_case "judge_prompt_missing" `Quick test_validated_judge_prompt_missing
        ; Alcotest.test_case "duplicate_judge" `Quick test_validated_duplicate_judge
        ; Alcotest.test_case "judge_bad_max_tool_calls" `Quick
            test_validated_judge_bad_max_tool_calls
        ; Alcotest.test_case "judge_bad_max_output_tokens" `Quick
            test_validated_judge_bad_max_output_tokens
        ] )
    ; ( "staged_judge_groups"
      , [ Alcotest.test_case "exact_3x3" `Quick test_staged_judge_groups_exact_3x3
        ; Alcotest.test_case "too_few" `Quick test_staged_judge_groups_too_few
        ; Alcotest.test_case "ragged" `Quick test_staged_judge_groups_ragged
        ; Alcotest.test_case "bad_size" `Quick test_staged_judge_groups_bad_size
        ] )
    ; ( "judge_args"
      , [ Alcotest.test_case "single_group_identity" `Quick
            test_judge_args_single_group_identity
        ; Alcotest.test_case "multi_group" `Quick test_judge_args_multi_group
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
    ; ( "topology"
      , [ Alcotest.test_case "roundtrip" `Quick test_topology_roundtrip
        ; Alcotest.test_case "unknown_is_none" `Quick test_topology_unknown_is_none
        ; Alcotest.test_case "wire_strings" `Quick test_topology_strings
        ; Alcotest.test_case "escalation_policy" `Quick test_escalation_policy
        ; Alcotest.test_case "render_lossless_fields" `Quick test_render_lossless_fields
        ; Alcotest.test_case "render_decision_answer" `Quick test_render_decision_answer
        ; Alcotest.test_case "render_decision_recommend" `Quick
            test_render_decision_recommend
        ; Alcotest.test_case "render_decision_insufficient" `Quick
            test_render_decision_insufficient
        ; Alcotest.test_case "render_empty_lists" `Quick test_render_empty_lists
        ] )
    ; ( "judge_outcome"
      , [ Alcotest.test_case "roundtrip" `Quick test_judge_outcome_roundtrip ] )
    ; ( "panel_guard"
      , [ Alcotest.test_case "judge_skip_reason" `Quick test_judge_skip_reason
        ; Alcotest.test_case "min_answered_range" `Quick test_validated_bad_min_answered
        ; Alcotest.test_case "min_answered_constants" `Quick test_min_answered_constants
        ] )
    ]
