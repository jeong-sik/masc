(** Fusion — runtime.toml [fusion] 테이블 → {!Fusion_policy.t} (fail-fast).

    알 수 없는/누락된/잘못된 config는 silent default로 압축하지 않고 [Error]로
    낸다 (CLAUDE.md §Unknown→Permissive 회피). [fusion] 섹션 자체가 없으면
    {!disabled}(비활성)을 반환한다 — opt-in OFF 기본.

    설계 SSOT: docs/rfc/RFC-0252-fusion-panel-judge-deliberation.md §9 *)

(** config 파싱/검증 에러 — 닫힌 합. *)
type config_error =
  | Empty_presets  (** enabled=true인데 preset 0개 *)
  | Invalid_panel_size of string * int  (** (preset 이름, 패널 수) — 1..8 위반 *)
  | Missing_prompt of string
      (** preset의 panel/judge system prompt가 비어있음 (코드 default 금지) *)
  | Missing_judge_model of string
      (** preset의 judge 모델 id가 비어있음 (필수, 빈 문자열 default 거부) *)
  | Invalid_max_concurrent_panels of int  (** max_concurrent_panels < 1 *)
  | Invalid_per_hour_budget of int
      (** enabled인데 per_hour_budget < 1 — gate가 `count >= budget`로 deny하므로
          0/음수는 모든 호출을 silent deny-all로 만든다 (enabled-but-never-runs). *)
  | Invalid_max_tool_calls of string * int
      (** (preset 이름, 값) — 0..16 범위 위반 *)
  | Invalid_timeout of string * float
      (** (preset 필드 경로, 값) — 0/음수/NaN/무한대 타임아웃 *)
  | Missing_default_preset of string
      (** enabled인데 default_preset가 비었거나 presets에 없음. 빈 문자엏도 거부 —
          preset 생략 호출이 default_preset로 폭빽하는데 ""는 항상 Preset_unknown로
          deny되기 때문. *)
  | Toml_type_error of string  (** 필드 타입 불일치 (Otoml.Type_error) *)
[@@deriving show, eq]

(** [fusion] 섹션 부재 시 비활성 기본 정책. *)
val disabled : Fusion_policy.t

(** 전체 runtime.toml(Otoml.t)에서 [fusion]을 읽어 정책 생성.

    - [fusion] 부재 → [Ok disabled].
    - enabled=true인데 preset 부재 → [Error [Empty_presets]].
    - 패널 크기 1..8 위반 → [Error [Invalid_panel_size _]].
    - panel/judge system prompt 누락 → [Error [Missing_prompt _]].
    - judge 모델 id 누락 → [Error [Missing_judge_model _]].
    - max_concurrent_panels < 1 → [Error [Invalid_max_concurrent_panels _]].
    - enabled + per_hour_budget < 1 → [Error [Invalid_per_hour_budget _]].
    - max_tool_calls_per_panel이 0..16 범위 밖 → [Error [Invalid_max_tool_calls _]].
    - default_preset가 presets에 없음 → [Error [Missing_default_preset _]].
    - 필드 타입 불일치 → [Error [Toml_type_error _]].
    여러 에러는 누적되어 한 번에 반환된다. *)
val of_toml : Otoml.t -> (Fusion_policy.t, config_error list) result
