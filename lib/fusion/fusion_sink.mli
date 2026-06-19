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

(** judge 결론을 키퍼 메인 chat lane에 남기고 board에 패널/심판 구조화 증거를 post한다.

    chat lane: judge가 [Ok]면 "결론 — resolved_answer" 한 줄을 메인 conversation에
    append하고 [chat_appended]로 대시보드에 알린다(judge 실패면 메인 흐름 비오염을 위해
    생략). board: [Board_dispatch.create_post]로 meta_json(source/run_id/question/panel
    답변 전체/judge 종합/observed_usage = panel N + judge 1 합산) 증거를 남긴다. [judge_usage]는
    심판이 소비한 토큰(orchestrator가 [Fusion_judge.run]에서 분리해 주입). [base_dir]는 호출자 주입.

    chat store append, broadcast, board post 중 예외가 발생하면 [Error msg]를 반환한다.
    [Eio.Cancel.Cancelled]는 재전파한다. *)
val emit
  :  base_dir:string
  -> keeper:string
  -> run_id:string
  -> question:string
  -> panel:Fusion_types.panel_outcome list
  -> judge:(Fusion_types.judge_synthesis, string) result
  -> judge_usage:Fusion_types.usage
  -> (unit, string) result

(** RFC-0266: 심의 완료/실패 시 호출 키퍼를 typed [Fusion_completed] stimulus로 깨운다.

    resolved_answer가 다음 키퍼 턴의 actionable 입력으로 도착하게 한다(board post +
    chat append 영속과 별개의 hint+payload 경로). [ok = false]는 denied/sink_failed/
    aborted 실패 라벨을 [resolved_answer]에 싣고, board post가 없으면 [board_post_id = ""].

    [emit]은 성공 경로(board post 생성됨)에서 이를 호출하고, 실패 경로는 fusion_tool의
    append_chat_failure가 호출한다(completion 타입당 단일 wake로 중복 방지).

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
