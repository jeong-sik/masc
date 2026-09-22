(** Antigravity 입력의 틀.

    Antigravity CLI 에는 system prompt 채널이 없다. 그래서 지시문과 목표를 입력 안에
    라벨을 붙인 구역으로 싣고, 구역 사이는 [section_separator] 로 나눈다. 키퍼 턴
    ({!Keeper_antigravity_runtime})과 Fusion 의 한 번짜리 턴
    ({!Fusion_official_client})이 이 라벨과 구분자를 같이 쓴다. *)

val system_instructions_label : unit -> (string, string) result
(** 지시문 구역의 라벨과 줄바꿈. 라벨 프롬프트 자산이 비었으면 그 키를 담은
    [Error] 다. *)

val current_goal_label : unit -> (string, string) result
(** 목표 구역의 라벨과 줄바꿈. 실패는 {!system_instructions_label} 과 같다. *)

val section_separator : string
(** 구역 사이의 빈 줄. *)
