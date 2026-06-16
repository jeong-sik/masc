(* Fusion — runtime.toml [fusion] 파싱 (구현).
   계약/문서: fusion_config.mli, docs/rfc/RFC-0252 §9 *)

type config_error =
  | Empty_presets
  | Invalid_panel_size of string * int
  | Missing_prompt of string
  | Missing_judge_model of string
  | Invalid_max_concurrent_panels of int
  | Invalid_per_hour_budget of int
  | Invalid_max_tool_calls of string * int
  | Missing_default_preset of string
  | Toml_type_error of string
[@@deriving show, eq]

let disabled : Fusion_policy.t =
  { enabled = false
  ; default_preset = ""
  ; max_concurrent_panels = 1
  ; presets = []
  ; low_confidence_threshold = 0.0
  ; high_stakes_task_kinds = []
  ; per_hour_budget = 0
  }

(* preset 한 명 파싱. 누락 필드는 명시적 default, 패널 크기는 검증(fail-fast). *)
let parse_preset (name, tbl) : (Fusion_policy.preset, config_error) result =
  let panel =
    Otoml.find_or ~default:[] tbl (Otoml.get_array Otoml.get_string) [ "panel" ]
  in
  let judge = Otoml.find_or ~default:"" tbl Otoml.get_string [ "judge" ] in
  (* 프롬프트는 행동을 정의하므로 코드 default로 채우지 않는다. 누락 시 ""로 읽혀
     아래 preset_prompts_present 검증에서 Missing_prompt로 fail-fast된다. *)
  let panel_system_prompt =
    Otoml.find_or ~default:"" tbl Otoml.get_string [ "panel_system_prompt" ]
  in
  let judge_system_prompt =
    Otoml.find_or ~default:"" tbl Otoml.get_string [ "judge_system_prompt" ]
  in
  let panel_timeout_s =
    Otoml.find_or ~default:Fusion_policy.default_timeout_s tbl Otoml.get_float
      [ "panel_timeout_s" ]
  in
  let judge_timeout_s =
    Otoml.find_or ~default:Fusion_policy.default_timeout_s tbl Otoml.get_float
      [ "judge_timeout_s" ]
  in
  let web_tools =
    Otoml.find_or ~default:false tbl Otoml.get_boolean [ "web_tools" ]
  in
  let max_tool_calls_per_panel =
    Otoml.find_or ~default:0 tbl Otoml.get_integer [ "max_tool_calls_per_panel" ]
  in
  let p : Fusion_policy.preset =
    { name
    ; panel
    ; judge
    ; panel_system_prompt
    ; judge_system_prompt
    ; panel_timeout_s
    ; judge_timeout_s
    ; web_tools
    ; max_tool_calls_per_panel
    }
  in
  if not (Fusion_policy.preset_size_ok p) then
    Error (Invalid_panel_size (name, List.length panel))
  else if not (Fusion_policy.preset_prompts_present p) then Error (Missing_prompt name)
  else if not (Fusion_policy.preset_judge_present p) then Error (Missing_judge_model name)
  else if max_tool_calls_per_panel < 0 || max_tool_calls_per_panel > 16 then
    Error (Invalid_max_tool_calls (name, max_tool_calls_per_panel))
  else Ok p

(* [fusion] 존재 확정 후의 본 파싱. Otoml.Type_error는 of_toml이 감싼다. *)
let parse_enabled (toml : Otoml.t) : (Fusion_policy.t, config_error list) result =
  let enabled = Otoml.find_or ~default:false toml Otoml.get_boolean [ "fusion"; "enabled" ] in
  let default_preset =
    Otoml.find_or ~default:"" toml Otoml.get_string [ "fusion"; "default_preset" ]
  in
  let max_concurrent_panels =
    Otoml.find_or ~default:1 toml Otoml.get_integer [ "fusion"; "max_concurrent_panels" ]
  in
  let low_confidence_threshold =
    Otoml.find_or ~default:0.0 toml Otoml.get_float
      [ "fusion"; "gate"; "low_confidence_threshold" ]
  in
  let high_stakes_task_kinds =
    Otoml.find_or ~default:[] toml (Otoml.get_array Otoml.get_string)
      [ "fusion"; "gate"; "high_stakes_task_kinds" ]
  in
  let per_hour_budget =
    Otoml.find_or ~default:0 toml Otoml.get_integer [ "fusion"; "gate"; "per_hour_budget" ]
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
  (* max_concurrent_panels는 Async_agent.all ~max_fibers로 직결된다. <1이면 Eio가
     예외를 던지고 패널이 전부 Timeout으로 오분류되므로 로드 단계에서 fail-fast. *)
  let errors =
    if enabled && max_concurrent_panels < 1 then
      Invalid_max_concurrent_panels max_concurrent_panels :: errors
    else errors
  in
  (* per_hour_budget는 gate가 `count >= budget`로 판정하므로(fusion_policy.ml),
     0/음수면 첫 호출부터 항상 deny-all = enabled-but-never-runs. 로드 단계 fail-fast. *)
  let errors =
    if enabled && per_hour_budget < 1 then
      Invalid_per_hour_budget per_hour_budget :: errors
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
              (fun (p : Fusion_policy.preset) -> String.equal p.name default_preset)
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
      ; presets
      ; low_confidence_threshold
      ; high_stakes_task_kinds
      ; per_hour_budget
      }

let of_toml (toml : Otoml.t) : (Fusion_policy.t, config_error list) result =
  match Otoml.find_opt toml Fun.id [ "fusion" ] with
  | None -> Ok disabled
  | Some _ ->
    (match parse_enabled toml with
     | result -> result
     | exception Otoml.Type_error msg -> Error [ Toml_type_error msg ])
