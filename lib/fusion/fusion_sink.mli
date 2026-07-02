(** Fusion — 심의 결과 가시화 (RFC-0252 §8, "결과를 키퍼 흐름에 녹이기" 개정).

    judge 결론(decision + resolved_answer)을 요청 키퍼의 *메인* chat lane에 authored
    메시지로 한 줄 남기고 SSE 브로드캐스트한다 → 키퍼가 다음 턴 observation
    ([recent_direct_conversation])으로 결론을 수령하고, librarian이 그 결론을 memory-os
    fact로 추출한다(fact 타입에 직접 의존하지 않는 강결합 없는 통합).

    패널 답변 N개 전체 + 심판 종합은 board post([Board.System_post] + [meta_json])에
    run_id로 묶인 쿼리 가능한 구조화 *증거*로 남긴다 — 사용자는 대시보드 board에서 상세를
    본다. chat lane에 패널 트랜스크립트를 쌓지 않는 이유: [Keeper_chat_store.load]는
    conversation을 필터하지 않아, 긴 패널 답변이 키퍼 [recent_direct_conversation]
    observation을 도배한다(§8.1 개정).

    설계 SSOT: docs/rfc/RFC-0252-fusion-panel-judge-deliberation.md §8 *)

(** [panel_meta o] — 패널 결과 한 건을 board meta_json의 [panel] 배열 원소로 직렬화.
    [Answered] → {model; status="answered"; answer; input_tokens; output_tokens},
    [Failed] → {model; status="failed"; reason_code; reason_detail; reason}.
    스키마는 프론트(board/fusion-evidence, fusion/fusion-surface)가 소비하는 공개 계약. *)
val panel_meta : Fusion_types.panel_outcome -> Yojson.Safe.t

(** [judge_meta judge] — 심판 종합을 board meta_json의 [judge] 원소로 직렬화.
    [Ok] → status/decision/resolved_answer/synthesis(평탄화 markdown, 구형 호환) +
    구조화 5섹션(consensus/contradictions/partial_coverage/unique_insights/blind_spots) +
    decision variant에 따른 최상위 [recommend] | [missing]. [Error] → {status="failed"; error}.
    구조화 필드 키(text/models/topic/addressed_by/...)는 {!Fusion_judge_parse}의
    LLM-facing JSON 스키마와 대칭이며, 프론트가 markdown 재파싱 없이 5섹션을 렌더한다. *)
val judge_meta : (Fusion_types.judge_synthesis, Fusion_types.judge_failure) result -> Yojson.Safe.t

(** [judge_node_meta o] — 심판 실행 노드 한 건을 board meta_json [judges] 배열 원소로
    직렬화 (RFC-0284). [Synthesized] → role/identity + judge_synthesis 5섹션 + 노드별
    실측 usage, [Judge_failed] → role/identity + status="failed" + error. [judge_meta]와
    같은 5섹션 스키마(judge_synthesis_fields)를 공유한다. role ∈ single|refine|first|meta,
    identity는 [First]면 panelist_id. 프론트는 배열 shape만으로 위상 구조를 렌더한다. *)
val judge_node_meta : Fusion_types.judge_outcome -> Yojson.Safe.t

(** judge 결론(성공/실패 모두)을 키퍼 메인 chat lane에 남기고 board에 패널/심판
    구조화 증거를 post한다.

    chat lane: judge가 [Ok]면 "결론 — resolved_answer" 한 줄, [Error]면 실패 사유
    (failure_code + 사유 + 실패 패널별 사유)를 메인 conversation에 append하고
    [chat_appended]로 대시보드에 알린다. 실패를 durable하게 남기는 이유: wake
    stimulus는 Running 키퍼에게만 배달되는 일회성 채널이라, chat lane이 비어 있으면
    비-Running 키퍼는 실패 사유에 도달할 tool-reachable 표면이 없다(2026-07-01 사고 —
    bare "judge failed"만 보고 keeper들이 원인을 추측·폴링). board headline도 같은
    실패 요약을 나른다. board: [Board_dispatch.create_post]로 meta_json(source/run_id/question/panel
    답변 전체/judge 종합/observed_usage = panel N + judge 1 합산) 증거를 남긴다. [judge_usage]는
    심판이 소비한 토큰(orchestrator가 [Fusion_judge.run]에서 분리해 주입). [judges]는 실제로
    실행된 심판 노드 관측 배열(RFC-0284)로 board meta_json [judges] 키에 panel과 동형으로
    직렬화된다 — canonical 단일 [judge] 키는 ADDITIVE 유지. [base_dir]는 호출자 주입.

    chat store append 실패는 [Error msg]로 반환한다. board post 생성 실패는 결론
    전달을 실패로 되돌리지 않는다: 경고를 남기고 [board_post_id = ""]로
    completion/wake를 진행한 뒤 [Ok ()]를 반환한다.
    [chat_appended] SSE broadcast는 {!Keeper_chat_broadcast} 정책을 따른다:
    non-cancel 예외는 counter+warn으로 흡수하는 best-effort 알림이며, chat/board
    영속 성공을 실패로 되돌리지 않는다. [Eio.Cancel.Cancelled]는 재전파한다. *)
val emit
  :  base_dir:string
  -> keeper:string
  -> run_id:string
  -> question:string
  -> panel:Fusion_types.panel_outcome list
  -> judge:(Fusion_types.judge_synthesis, Fusion_types.judge_failure) result
  -> judges:Fusion_types.judge_outcome list
  -> judge_usage:Fusion_types.usage
  -> (unit, string) result

(** RFC-0266: 심의 완료/실패 시 호출 키퍼를 typed [Fusion_completed] stimulus로 깨운다.

    resolved_answer가 다음 키퍼 턴의 actionable 입력으로 도착하게 한다(board post +
    chat append 영속과 별개의 hint+payload 경로). [ok = false]는 denied/sink_failed/
    aborted 실패 라벨을 [resolved_answer]에 싣고, board post가 없으면 [board_post_id = ""].

    [emit]은 chat lane append 성공 경로에서 이를 호출한다(board post가 없으면
    [board_post_id = ""]). 실패 경로는 fusion_tool의 append_chat_failure가
    호출한다(completion 타입당 단일 wake로 중복 방지).

    예외 안전: [Eio.Cancel.Cancelled]는 재전파, 그 외 예외는 흡수(sink 결과 비오염).
    Running이 아닌 키퍼는 silent no-op이며 결과는 board/chat 영속으로 남는다. *)
val wake_keeper_on_fusion_completion :
     base_dir:string
  -> keeper:string
  -> run_id:string
  -> ok:bool
  -> resolved_answer:string
  -> board_post_id:string
  -> unit

(** RFC-0266 §7 Phase 4: broadcast a [fusion_run_status] SSE event carrying the
    current registry snapshot of [run_id] so the dashboard fusion-runs panel
    reflects running→completed transitions live. Reads the canonical run back
    from [registry] and serializes it via [Fusion_run_registry.run_to_yojson]
    (same shape as the HTTP list endpoint). Best-effort: an unknown [run_id] is a
    no-op, and every exception except [Eio.Cancel.Cancelled] is swallowed +
    logged so a broadcast failure never aborts the fusion tool/sink. Callers
    invoke it right after [register_running] / [mark_completed]. *)
val broadcast_run_status : registry:Fusion_run_registry.t -> run_id:string -> unit
