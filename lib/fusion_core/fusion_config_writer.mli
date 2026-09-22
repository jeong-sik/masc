(** Fusion 설정 작성기 — runtime.toml 의 [\[fusion\]] 구역을 typed 값으로 고친다.

    파일 전체를 다시 찍지 않는다. Otoml 로 다시 찍으면 주석이 모두 사라진다. 한 번에
    preset 하나의 구역만 고치고, 구역 밖의 줄은 바이트 그대로 둔다.

    preset 구역은 [\[fusion.presets.<이름>\]] 머리부터, 그 preset 밑이 아닌 다음 표
    머리 앞까지다. 그 사이의 [\[\[fusion.presets.<이름>.panels\]\]] 와
    [\[\[fusion.presets.<이름>.judges\]\]] 항목도 구역에 든다.

    구역 안에서도 원래 줄이 기본이다.
    - 값이 그대로인 키는 줄을 그대로 둔다. 자리, 줄바꿈, 배열 안 주석, 줄 끝 주석이
      모두 남는다. 같은 preset 을 그대로 다시 쓰면 파일이 바이트 그대로다.
    - 값이 바뀐 키는 그 자리에서 다시 쓴다. 바로 위 주석은 남고, 원래 값 줄 안의
      주석(배열 안, 줄 끝)은 사라진다.
    - preset 에서 빠진 키는 바로 위 주석과 함께 지운다.
    - 파일에 없던 키는 그 표의 마지막 키 뒤에 붙인다. 기본값과 같은 선택 키
      ([label = ""], [web_tools = false], [min_answered = 1])는 파일에 없으면 새로
      쓰지 않는다.
    - 작성기가 모르는 키는 그대로 둔다.

    항목(panels, judges)은 같은 라벨과 같은 경로를 가진 원래 항목의 줄을 이어받는다.
    그런 항목이 없으면 같은 라벨(비어 있지 않고 양쪽에서 하나뿐)인 항목을 이어받는다.
    둘 다 없으면 새로 쓴다. 항목 순서는 preset 의 순서를 따르되, panels 와 judges 가
    파일에서 섞여 있던 자리는 그대로 쓴다.

    패널 문법: 원래 preset 이 [\[\[...panels\]\]] 항목을 썼으면 항목으로, 평평한
    [panel = \[...\]] 을 썼으면 그룹이 하나인 동안 평평하게 쓴다. 새 preset 은 그룹이
    하나이고 라벨이 없을 때만 평평하게 쓴다. 두 문법은 {!Fusion_config} 가 같은
    preset 으로 읽는다.

    설계: docs/rfc/RFC-fusion-seat-routes.md §2.5, RFC-0306 §3.2 *)

type error =
  | Preset_absent of string
  | Preset_exists of string
  | Unaddressable_preset of string
      (** preset 이 자기 표 머리 없이 (점 키나 인라인 표로) 적혔거나, 그 preset 의 키나
          하위 표가 구역 밖에 있거나, 구역 안에 panels/judges 가 아닌 하위 표가 있다.
          줄 편집으로는 안전하게 고칠 수 없다. *)
  | Unreadable of string
      (** 파일이 TOML 로 읽히지 않는다. payload 는 파서의 문장이다. *)

val error_message : error -> string

val upsert_preset
  :  string
  -> Fusion_policy.Validated_preset.t
  -> (string, error) result
(** preset 이름의 구역을 그 preset 으로 고친다. 그 preset 이 없으면 [fusion] 표들
    가운데 마지막 구역 뒤에 새로 만든다. [fusion] 표가 하나도 없으면 파일 끝에
    만든다. 검증된 preset 만 받는다. 항목을 알아보는 라벨·경로가 겹치지 않는다는 것을
    검증이 보장한다. *)

val delete_preset : string -> name:string -> (string, error) result
(** preset 구역과, 그 머리 바로 위에 빈 줄 없이 붙은 주석을 지운다. 그 주석은 이
    preset 에 대한 설명이라 preset 없이 남으면 틀린 문장이 된다.
    [default_preset] 은 바꾸지 않는다. *)

val rename_preset : string -> from:string -> target:string -> (string, error) result
(** preset 표와 하위 항목의 머리를 [target] 으로 바꾼다. 본문, 주석, 머리 끝 주석은
    그대로다. [\[fusion\].default_preset] 이 [from] 이면 [target] 으로 같이 바꾼다. *)

type settings =
  { enabled : bool
  ; default_preset : string
  ; staged_judge_group_size : int
  }

val set_settings : string -> settings -> string
(** [\[fusion\]] 표의 세 값을 preset 과 같은 규칙으로 쓴다. 값이 그대로인 키는 줄이
    그대로고, 새 키는 표의 마지막 키 뒤에 붙는다. [staged_judge_group_size] 는 기본값과
    같고 파일에 없으면 새로 쓰지 않는다. [\[fusion\]] 표가 없으면 첫 [fusion] 하위 표
    앞에, 그것도 없으면 파일 끝에 만든다. *)
