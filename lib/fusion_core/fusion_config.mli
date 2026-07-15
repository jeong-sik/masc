(** Fusion — runtime.toml [fusion] 테이블 → {!Fusion_policy.t} (fail-fast).

    알 수 없는/누락된/잘못된 config는 silent default로 압축하지 않고 [Error]로
    낸다 (CLAUDE.md §Unknown→Permissive 회피). [fusion] 섹션 자체가 없으면
    {!disabled}(비활성)을 반환한다 — opt-in OFF 기본.

    설계 SSOT: docs/rfc/RFC-0252-fusion-panel-judge-deliberation.md §9 *)

(** config 파싱/검증 에러 — 닫힌 합. *)
type config_error =
  | Empty_presets  (** enabled=true인데 preset 0개 *)
  | Invalid_panel_size of string * int
      (** (preset 이름, 모델 총합) — 그룹 모델 총합 1..8 위반 (빈 panel=[] 포함). *)
  | Empty_panels of string
      (** preset의 [panels]가 빈 배열 (그룹 0개). "모델 0개"(Invalid_panel_size)와 구분. *)
  | Conflicting_panel_grammar of string
      (** 같은 preset에 [[...panels]]와 flat [panel] 둘 다 존재 (silent 선택 금지). *)
  | Duplicate_panelist of string * string
      (** (preset 이름, panelist_id) — 두 패널이 같은 정체성을 가짐. 라벨 없는 두
          그룹의 동일 model, 한 그룹 내 동일 model, 동일 라벨+model을 흡수한다.
          서로 다른 라벨의 동일 model은 통과 (same-model-different-prompt, RFC-0278). *)
  | Missing_prompt of string
      (** preset의 panel/judge system prompt가 비어있음 (코드 default 금지) *)
  | Missing_judge_model of string
      (** preset의 judge 모델 id가 비어있음 (필수, 빈 문자열 default 거부) *)
  | Invalid_staged_judge_group_size of int
      (** staged_judge_group_size < Fusion_policy.min_staged_judge_group_size *)
  | Invalid_max_output_tokens of string * int
      (** (preset 이름, 값) — max_output_tokens override는 양수여야 함 *)
  | Missing_default_preset of string
      (** enabled인데 default_preset가 비었거나 presets에 없음. 빈 문자엏도 거부 —
          preset 생략 호출이 default_preset로 폭빽하는데 ""는 항상 Preset_unknown로
          deny되기 때문. *)
  | Judge_panel_prompt_missing of string
      (** preset 이름 — JOJ 1차 심판 system prompt 누락 (RFC-0283). *)
  | Duplicate_judge of string * string
      (** (preset 이름, 중복 judge 정체성) — 두 JOJ 1차 심판이 같은 정체성 (RFC-0283). *)
  | Invalid_min_answered of string * int
      (** (preset 이름, min_answered) — [min_answered]가 policy 허용 범위(1..패널
          모델 총합) 밖. full-panel quorum([총합])도 명시적으로 설정할 수 있다. *)
  | Invalid_meta_timeout of string * float
      (** (preset 이름, meta_timeout_s) — 양수 유한수가 아님. *)
  | Invalid_judge_wave_budget of string * float
      (** (preset 이름, judge_wave_budget_s) — 0 미만이거나 최장 1차 심판 타임아웃/
          [meta_timeout_s]보다 작음. *)
  | Invalid_adaptive_timeout_factor of string * float
      (** (preset 이름, adaptive_timeout_factor) — 1.0 미만. *)
  | Toml_type_error of string  (** 필드 타입 불일치 (Otoml.Type_error) *)
[@@deriving show, eq]

(** [fusion] 섹션 부재 시 비활성 기본 정책. *)
val disabled : Fusion_policy.t

(** 전체 runtime.toml(Otoml.t)에서 [fusion]을 읽어 정책 생성.

    - [fusion] 부재 → [Ok disabled].
    - enabled=true인데 preset 부재 → [Error [Empty_presets]].
    - 패널 모델 총합 1..8 위반 → [Error [Invalid_panel_size _]].
    - [panels] 빈 배열(그룹 0개) → [Error [Empty_panels _]].
    - [[...panels]]와 flat [panel] 동시 → [Error [Conflicting_panel_grammar _]].
    - 패널 정체성(panelist_id) 중복 → [Error [Duplicate_panelist _]]. 라벨이 다르면
      같은 model이라도 통과(same-model-different-prompt, RFC-0278).
    - panel/judge system prompt 누락 → [Error [Missing_prompt _]].
    - judge 모델 id 누락 → [Error [Missing_judge_model _]].
    - staged_judge_group_size < 2 → [Error [Invalid_staged_judge_group_size _]].
    - max_output_tokens override가 0 이하 → [Error [Invalid_max_output_tokens _]].
    - min_answered가 1..패널 모델 총합 범위 밖 → [Error [Invalid_min_answered _]].
    - default_preset가 presets에 없음 → [Error [Missing_default_preset _]].
    - 필드 타입 불일치 → [Error [Toml_type_error _]].
    여러 에러는 누적되어 한 번에 반환된다. *)
val of_toml : Otoml.t -> (Fusion_policy.t, config_error list) result
