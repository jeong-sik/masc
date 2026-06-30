(** Fusion — 심판 모델의 LLM-facing JSON 출력 → {!Fusion_types.judge_synthesis}.

    [ppx_deriving_yojson]의 variant 인코딩(예: [["Answer", ...]])은 LLM이 안정적으로
    내기 어렵다. 그래서 LLM이 내기 쉬운 자연스러운 JSON(named fields, [decision]은
    [{"kind": ...}] 태그 객체)을 받아 내부 타입으로 매핑하는 손-작성 파서를 둔다.

    순수 함수 — agent_sdk 의존 없이 fusion_core에서 단위 테스트 가능. OAS의
    [tool_param list] schema 구성은 소비자(lib/fusion/fusion_judge)가 담당한다.

    기대 JSON 형태 (LLM 지시용, {!expected_json_doc}와 일치):
    {[
      {
        "consensus":        [ { "text": "...", "supporting_models": ["m1"] } ],
        "contradictions":   [ { "topic": "...", "positions": [ {"model":"m1","stance":"..."} ],
                                "evidence": ["..."] } ],
        "partial_coverage": [ { "topic": "...", "addressed_by": ["m1"], "missing": "..." } ],
        "unique_insights":  [ { "text": "...", "model": "m1" } ],
        "blind_spots":      [ "..." ],
        "resolved_answer":  "...",
        "decision": { "kind": "answer", "answer": "..." }
      }
    ]}
    [decision.kind]는 ["answer"] | ["recommend"] | ["insufficient"] 중 하나:
    - answer:       [{ "kind": "answer", "answer": "..." }]
    - recommend:    [{ "kind": "recommend", "action": "...", "rationale": "..." }]
    - insufficient: [{ "kind": "insufficient", "missing": ["..."] }]

    설계 SSOT: docs/rfc/RFC-0252-fusion-panel-judge-deliberation.md §7.2 *)

(** 심판 프롬프트에 임베드할, 기대 JSON 형태 설명 (LLM 지시용). *)
val expected_json_doc : string

(** Wire field names consumed by {!of_json}. Provider-native output schemas must
    use these constants instead of duplicating field strings. *)
val wire_field_consensus : string
val wire_field_consensus_text : string
val wire_field_supporting_models : string
val wire_field_contradictions : string
val wire_field_topic : string
val wire_field_positions : string
val wire_field_model : string
val wire_field_stance : string
val wire_field_evidence : string
val wire_field_partial_coverage : string
val wire_field_addressed_by : string
val wire_field_missing : string
val wire_field_unique_insights : string
val wire_field_blind_spots : string
val wire_field_resolved_answer : string
val wire_field_decision : string
val wire_field_decision_kind : string
val wire_field_answer : string
val wire_decision_answer : string
val wire_decision_recommend : string
val wire_decision_insufficient : string
val wire_field_recommend_action : string
val wire_field_recommend_rationale : string

(** LLM JSON 값 → judge_synthesis.

    - 리스트 필드(consensus/contradictions/partial_coverage/unique_insights/blind_spots)는
      누락 시 [[]] 허용. 리스트 원소 중 필수 하위필드가 없는 것은 건너뛴다(advisory).
    - [resolved_answer]와 [decision]은 필수. 누락/형태 오류는 [Error msg].
    - [decision.kind]가 알 수 없는 값이면 [Error] (silent default 없음). *)
val of_json : Yojson.Safe.t -> (Fusion_types.judge_synthesis, string) result

(** JSON 문자열 파싱 편의. ```json 코드펜스를 허용하고 벗긴 뒤 {!of_json}. *)
val of_string : string -> (Fusion_types.judge_synthesis, string) result
