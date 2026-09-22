(** Fusion 설정 작성기 — runtime.toml 의 [\[fusion\]] 구역을 typed 값으로 고친다.

    파일 전체를 다시 찍지 않는다. Otoml 로 다시 찍으면 주석이 모두 사라진다. 한 번에
    preset 하나의 구역만 typed 값으로 다시 쓰고, 나머지 줄은 바이트 그대로 둔다.

    preset 구역은 [\[fusion.presets.<이름>\]] 머리부터, 그 preset 밑이 아닌 다음 표
    머리 앞까지다. 그 사이의 [\[\[fusion.presets.<이름>.panels\]\]] 와
    [\[\[fusion.presets.<이름>.judges\]\]] 항목도 구역에 든다.

    주석 규칙:
    - preset 머리 바로 위 주석과 구역 밖의 줄은 건드리지 않는다.
    - 구역 안의 주석은 바로 아래 키나 항목 머리에 붙어 있다. 다시 쓴 구역에 같은 자리
      (같은 키, 같은 항목의 같은 키, 같은 항목 머리)가 있으면 그 위에 다시 놓고, 없으면
      키와 함께 사라진다. 항목은 panel 그룹이면 라벨(없으면 첫 경로), judge 면
      {!Fusion_policy.panelist_id} 로 알아본다.
    - 다음 표 머리 바로 위의 주석과 빈 줄은 다음 표의 것이라 구역에 넣지 않는다.

    패널 문법: 그룹이 하나이고 라벨이 없으면 평평한 [panel = \[...\]] 로, 그 밖에는
    [\[\[...panels\]\]] 항목으로 쓴다. 두 문법은 {!Fusion_config} 가 같은 preset 으로
    읽는다.

    이 모듈은 값을 검증하지 않는다. 호출자는 쓰기 전에
    {!Fusion_policy.Validated_preset.of_preset} 를, 쓴 뒤에 파일 전체의
    {!Fusion_config.of_toml} 를 돌린다.

    설계: docs/rfc/RFC-fusion-seat-routes.md §2.5, RFC-0306 §3.2 *)

type error =
  | Preset_absent of string
  | Preset_exists of string
  | Unaddressable_preset of string
      (** preset 이 자기 표 머리 없이 (점 키나 인라인 표로) 적혔거나, 하위 표가 구역
          밖에 흩어져 있거나, 구역 안에 panels/judges 가 아닌 하위 표가 있다. 줄
          편집으로는 안전하게 고칠 수 없다. *)

val error_message : error -> string

val upsert_preset : string -> Fusion_policy.preset -> (string, error) result
(** [preset.name] 의 구역을 [preset] 으로 다시 쓴다. 그 preset 이 없으면 [fusion]
    표들 가운데 마지막 구역 뒤에 새로 만든다. [fusion] 표가 하나도 없으면 파일 끝에
    만든다. *)

val delete_preset : string -> name:string -> (string, error) result
(** preset 구역과, 그 머리 바로 위에 빈 줄 없이 붙은 주석을 지운다. 그 주석은 이
    preset 에 대한 설명이라 preset 없이 남으면 틀린 문장이 된다.
    [default_preset] 은 바꾸지 않는다. *)

val rename_preset : string -> from:string -> target:string -> (string, error) result
(** preset 표와 하위 항목의 머리를 [target] 으로 바꾼다. 본문과 주석은 그대로다.
    [\[fusion\].default_preset] 이 [from] 이면 [target] 으로 같이 바꾼다. *)

type settings =
  { enabled : bool
  ; default_preset : string
  ; staged_judge_group_size : int
  }

val set_settings : string -> settings -> string
(** [\[fusion\]] 표의 세 값을 쓴다. 표가 없으면 파일 끝에 만든다. *)
