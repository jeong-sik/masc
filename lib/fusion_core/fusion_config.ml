(* Fusion — runtime.toml [fusion] 파싱 (구현).
   계약/문서: fusion_config.mli, docs/rfc/RFC-0252 §9 *)

type config_error =
  | Empty_presets
  | Invalid_panel_size of string * int
  | Empty_panels of string
  | Conflicting_panel_grammar of string
  | Duplicate_panelist of string * string
  | Missing_prompt of string
  | Missing_judge_model of string
  | Invalid_max_concurrent_panels of int
  | Invalid_max_concurrent_judges of int
  | Invalid_staged_judge_group_size of int
  | Invalid_max_tool_calls of string * int
  | Missing_default_preset of string
  | Judge_panel_prompt_missing of string  (** preset 이름; JOJ 1차 심판 prompt 누락 (RFC-0283) *)
  | Duplicate_judge of string * string  (** (preset 이름, 중복 judge 정체성) (RFC-0283) *)
  | Invalid_min_answered of string * int
      (** (preset 이름, min_answered): policy 허용 범위 밖 *)
  | Toml_type_error of string
[@@deriving show, eq]

let disabled : Fusion_policy.t =
  { enabled = false
  ; default_preset = ""
  ; max_concurrent_panels = 1
  ; max_concurrent_judges = Fusion_policy.default_max_concurrent_judges
  ; staged_judge_group_size = Fusion_policy.default_staged_judge_group_size
  ; presets = []
  }

(* 패널 그룹 한 개 파싱. 그룹 sub-table(새 [[...panels]] 문법)에도, preset table
   자체(legacy flat 문법의 desugar)에도 동일하게 적용된다 — 두 문법이 같은 키
   이름(panel/label/panel_system_prompt/web_tools/max_tool_calls_per_panel/panel_timeout_s)을
   쓰므로 코드 재사용. 누락 필드는 명시적 default. label 기본 ""(정체성=model 그대로)
   → legacy flat은 label 키가 없으므로 byte-identical (RFC-0278). *)
let parse_group (tbl : Otoml.t) : Fusion_policy.panel_group =
  { models =
      Otoml.find_or ~default:[] tbl (Otoml.get_array Otoml.get_string) [ "panel" ]
  ; label = Otoml.find_or ~default:"" tbl Otoml.get_string [ "label" ]
  ; system_prompt =
      Otoml.find_or ~default:"" tbl Otoml.get_string [ "panel_system_prompt" ]
  ; web_tools = Otoml.find_or ~default:false tbl Otoml.get_boolean [ "web_tools" ]
  ; max_tool_calls =
      Otoml.find_or ~default:0 tbl Otoml.get_integer [ "max_tool_calls_per_panel" ]
  ; timeout_s =
      Otoml.find_or ~default:Fusion_policy.default_timeout_s tbl Otoml.get_float
        [ "panel_timeout_s" ]
  }

(* JOJ 1차 심판 한 명 파싱 (RFC-0283). [[fusion.presets.NAME.judges]] sub-table의
   키 model/label/system_prompt/web_tools/max_tool_calls/timeout_s를 읽는다. sub-table
   이름(judges)이 scope를 주므로 키는 비-접두. parse_group과 동형. 누락 system_prompt는
   ""로 읽혀 Validated_preset 검증에서 Judge_panel_prompt_missing으로 fail-fast된다. *)
let parse_judge_spec (tbl : Otoml.t) : Fusion_policy.judge_spec =
  { jmodel = Otoml.find_or ~default:"" tbl Otoml.get_string [ "model" ]
  ; jlabel = Otoml.find_or ~default:"" tbl Otoml.get_string [ "label" ]
  ; jsystem_prompt =
      Otoml.find_or ~default:"" tbl Otoml.get_string [ "system_prompt" ]
  ; jweb_tools = Otoml.find_or ~default:false tbl Otoml.get_boolean [ "web_tools" ]
  ; jmax_tool_calls =
      Otoml.find_or ~default:0 tbl Otoml.get_integer [ "max_tool_calls" ]
  ; jtimeout_s =
      Otoml.find_or ~default:Fusion_policy.default_timeout_s tbl Otoml.get_float
        [ "timeout_s" ]
  }

let parse_min_answered _name tbl =
  match Otoml.find_opt tbl Otoml.get_integer [ "min_answered" ] with
  | None -> Ok Fusion_policy.default_min_answered
  | Some v -> Ok v

(* 패널 그룹을 확정한 뒤 preset 완성 + 검증. judge_* 는 preset table에서 직접 읽는다
   (단일 심판 = simple/refine/conditional 심판이자 JOJ meta). [[...judges]] sub-table이
   있으면 JOJ 1차 심판 목록으로 파싱(없으면 []). 검증 순서: 크기(총합) → 패널 프롬프트 →
   심판모델 → 패널 정체성 중복 → 패널 max_tool_calls → 1차 심판 prompt/정체성/max_tool_calls
   → min_answered. *)
let finish_preset name tbl (panels : Fusion_policy.panel_group list)
  : (Fusion_policy.Validated_preset.t, config_error) result =
  let judge = Otoml.find_or ~default:"" tbl Otoml.get_string [ "judge" ] in
  (* 프롬프트는 행동을 정의하므로 코드 default로 채우지 않는다. 누락 시 ""로 읽혀
     Validated_preset.of_preset 검증에서 Missing_prompt로 fail-fast된다. *)
  let judge_system_prompt =
    Otoml.find_or ~default:"" tbl Otoml.get_string [ "judge_system_prompt" ]
  in
  let judge_timeout_s =
    Otoml.find_or ~default:Fusion_policy.default_timeout_s tbl Otoml.get_float
      [ "judge_timeout_s" ]
  in
  let judges =
    match Otoml.find_opt tbl (Otoml.get_array Otoml.get_value) [ "judges" ] with
    | Some entries -> List.map parse_judge_spec entries
    | None -> []
  in
  (* 런타임 quorum. 미설정 시 [default_min_answered] = 기존 동작(>= 1 응답이면 심판 실행).
     허용 범위는 1 이상 패널 모델 총합 이하; 검증 SSOT는 Validated_preset.of_preset. *)
  Result.bind (parse_min_answered name tbl) (fun min_answered ->
    let p : Fusion_policy.preset =
      { name; panels; judge; judge_system_prompt; judge_timeout_s; judges; min_answered }
    in
    (* 검증 SSOT는 Validated_preset.of_preset (RFC-0280). config는 그 [invalid]에 preset
     이름을 붙여 자기 [config_error]로 매핑만 한다 (운영자에게 어느 preset인지 알림).
     [open] 안 함 — invalid와 config_error가 Missing_prompt 등 동명 변형을 가져 LHS만
     full-qualify해 shadow를 피한다. *)
    match Fusion_policy.Validated_preset.of_preset p with
    | Ok vp -> Ok vp
    | Error invalid ->
      Error
        (match invalid with
         | Fusion_policy.Validated_preset.Bad_size n -> Invalid_panel_size (name, n)
         | Fusion_policy.Validated_preset.Missing_prompt -> Missing_prompt name
         | Fusion_policy.Validated_preset.Missing_judge_model -> Missing_judge_model name
         | Fusion_policy.Validated_preset.Duplicate_panelist id ->
           Duplicate_panelist (name, id)
         | Fusion_policy.Validated_preset.Bad_max_tool_calls v ->
           Invalid_max_tool_calls (name, v)
         | Fusion_policy.Validated_preset.Judge_panel_prompt_missing ->
           Judge_panel_prompt_missing name
         | Fusion_policy.Validated_preset.Duplicate_judge id ->
           Duplicate_judge (name, id)
         | Fusion_policy.Validated_preset.Min_answered_below_min v
         | Fusion_policy.Validated_preset.Min_answered_above_max v ->
           Invalid_min_answered (name, v)))

(* preset 한 명 파싱. 두 문법 분기:
   - 새 문법 [[fusion.presets.NAME.panels]] (array-of-tables) → 그룹별 파싱.
   - legacy flat panel=[...] → 정확히 길이-1 그룹으로 desugar (운영자 TOML 무변경,
     단일 그룹이면 오늘과 byte-identical).
   둘 다 있으면 Conflicting_panel_grammar, panels=[](그룹 0개)면 Empty_panels로 명시적
   거부 (silent 한쪽 선택 금지). 빈 panel=[](모델 0개)은 legacy 길이-1 그룹으로 desugar
   되어 size 검증에서 Invalid_panel_size(_, 0)으로 잡힌다 — "그룹 0개"(Empty_panels)와
   "모델 0개"(Invalid_panel_size)는 다른 조건이므로 다른 variant로 구분한다.
   panels가 스칼라 등 malformed면 get_array가 Type_error를 내고, find_opt/find_or는
   Key_error만 삼키고 Type_error는 전파하므로(otoml_base.ml:332-337) of_toml의
   Type_error 핸들러가 Toml_type_error로 fail-fast한다. 여기서 find_opt는 panels/panel
   존재 여부(Some/None) 판별에만 쓰인다 — Type_error 회피 목적이 아니다. *)
let parse_preset (name, tbl) : (Fusion_policy.Validated_preset.t, config_error) result =
  let groups_opt = Otoml.find_opt tbl (Otoml.get_array Otoml.get_value) [ "panels" ] in
  let has_flat_panel = Option.is_some (Otoml.find_opt tbl Otoml.get_value [ "panel" ]) in
  match groups_opt, has_flat_panel with
  | Some _, true -> Error (Conflicting_panel_grammar name)
  | Some [], _ -> Error (Empty_panels name)
  | Some (_ :: _ as gs), false -> finish_preset name tbl (List.map parse_group gs)
  | None, _ -> finish_preset name tbl [ parse_group tbl ]

(* [fusion] 존재 확정 후의 본 파싱. Otoml.Type_error는 of_toml이 감싼다. *)
let parse_enabled (toml : Otoml.t) : (Fusion_policy.t, config_error list) result =
  let enabled = Otoml.find_or ~default:false toml Otoml.get_boolean [ "fusion"; "enabled" ] in
  let default_preset =
    Otoml.find_or ~default:"" toml Otoml.get_string [ "fusion"; "default_preset" ]
  in
  let max_concurrent_panels =
    Otoml.find_or ~default:1 toml Otoml.get_integer [ "fusion"; "max_concurrent_panels" ]
  in
  let max_concurrent_judges =
    Otoml.find_or ~default:Fusion_policy.default_max_concurrent_judges toml
      Otoml.get_integer [ "fusion"; "max_concurrent_judges" ]
  in
  let staged_judge_group_size =
    Otoml.find_or ~default:Fusion_policy.default_staged_judge_group_size toml
      Otoml.get_integer [ "fusion"; "staged_judge_group_size" ]
  in
  let preset_entries =
    match Otoml.find_opt toml Otoml.get_table [ "fusion"; "presets" ] with
    | Some entries -> entries
    | None -> []
  in
  let parsed = List.map parse_preset preset_entries in
  let presets = List.filter_map (function Ok p -> Some p | Error _ -> None) parsed in
  let errors = List.filter_map (function Error e -> Some e | Ok _ -> None) parsed in
  (* 추가 검증 — enabled일 때만 강제 (disabled면 빈 config 허용). *)
  let errors =
    if enabled && presets = [] then Empty_presets :: errors else errors
  in
  (* Structural concurrency bounds are validated unconditionally even when
     [enabled] is [false].  A disabled config is still persisted and can be
     re-enabled without reloading, so invalid bounds must be rejected at the
     source rather than deferred to runtime.  Only preset-related rules (empty
     presets, default preset membership) are gated on [enabled] because they
     describe the active policy surface, not the underlying resource limits. *)
  (* max_concurrent_panels는 Async_agent.all ~max_fibers로 직결된다. <1이면 Eio가
     예외를 던지고 패널이 전부 Timeout으로 오분류되므로 로드 단계에서 fail-fast. *)
  let errors =
    if max_concurrent_panels < 1
    then Invalid_max_concurrent_panels max_concurrent_panels :: errors
    else errors
  in
  (* JOJ judge waves do not share the panel cap.  A low panel cap is often
     provider backpressure for panel models; coupling judges to it serializes
     independent judge lenses and lets one slow judge delay the rest. *)
  let errors =
    if max_concurrent_judges < 1
    then Invalid_max_concurrent_judges max_concurrent_judges :: errors
    else errors
  in
  (* Staged JOJ uses this as an exact reducer group size.  Values below 2
     silently degenerate the tree into pass-through, so reject them at load. *)
  let errors =
    if staged_judge_group_size < Fusion_policy.min_staged_judge_group_size
    then Invalid_staged_judge_group_size staged_judge_group_size :: errors
    else errors
  in
  (* enabled면 default_preset가 비어있지 않고 presets에 존재해야 한다. preset 생략
     호출이 default_preset로 폭빽하는데, ""는 find_preset에서 항상 None→Preset_unknown
     ""로 deny되므로 빈 문자엏도 거부한다(silent per-call deny 방지). *)
  let errors =
    if
      enabled
      && not
           (List.exists
              (fun (vp : Fusion_policy.Validated_preset.t) ->
                String.equal (Fusion_policy.Validated_preset.preset vp).name default_preset)
              presets)
    then Missing_default_preset default_preset :: errors
    else errors
  in
  if errors <> [] then Error (List.rev errors)
  else
    Ok
      { Fusion_policy.enabled
      ; default_preset
      ; max_concurrent_panels
      ; max_concurrent_judges
      ; staged_judge_group_size
      ; presets
      }

let of_toml (toml : Otoml.t) : (Fusion_policy.t, config_error list) result =
  match Otoml.find_opt toml Fun.id [ "fusion" ] with
  | None -> Ok disabled
  | Some _ ->
    (match parse_enabled toml with
     | result -> result
     | exception Otoml.Type_error msg -> Error [ Toml_type_error msg ])
