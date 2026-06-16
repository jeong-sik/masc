(** Fusion — runtime.toml [fusion] 테이블 → {!Fusion_policy.t} (fail-fast).

    알 수 없는/누락된/잘못된 config는 silent default로 압축하지 않고 [Error]로
    낸다 (CLAUDE.md §Unknown→Permissive 회피). [fusion] 섹션 자체가 없으면
    {!disabled}(비활성)을 반환한다 — opt-in OFF 기본.

    설계 SSOT: docs/rfc/RFC-0249-fusion-panel-judge-deliberation.md §9 *)

(** config 파싱/검증 에러 — 닫힌 합. *)
type config_error =
  | Empty_presets  (** enabled=true인데 preset 0개 *)
  | Invalid_panel_size of string * int  (** (preset 이름, 패널 수) — 1..8 위반 *)
  | Missing_prompt of string
      (** preset의 panel/judge system prompt가 비어있음 (코드 default 금지) *)
  | Missing_default_preset of string  (** default_preset가 presets에 없음 *)
  | Toml_type_error of string  (** 필드 타입 불일치 (Otoml.Type_error) *)
[@@deriving show, eq]

(** [fusion] 섹션 부재 시 비활성 기본 정책. *)
val disabled : Fusion_policy.t

(** 전체 runtime.toml(Otoml.t)에서 [fusion]을 읽어 정책 생성.

    - [fusion] 부재 → [Ok disabled].
    - enabled=true인데 preset 부재 → [Error [Empty_presets]].
    - 패널 크기 1..8 위반 → [Error [Invalid_panel_size _]].
    - default_preset가 presets에 없음 → [Error [Missing_default_preset _]].
    - 필드 타입 불일치 → [Error [Toml_type_error _]].
    여러 에러는 누적되어 한 번에 반환된다. *)
val of_toml : Otoml.t -> (Fusion_policy.t, config_error list) result
