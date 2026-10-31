# 재기동 뒤 Schedule 결과 불명과 재전달

2026-10-30 20:20:42–20:20:43 KST에 운영 기록을 읽기 전용으로 대조한
익명 파생 집계다. 서버 health가 보고한 실행 바이너리는
`a97919872890eb9b4e730f65b745ab094ed8ce12`, 시작 시각은 19:49:39 KST다.
Keeper 이름, event·trace ID, 메시지·prompt 원문과 자격증명은 싣지 않았다.
시각과 크기 조합을 다른 원장과 대조하면 연결될 가능성까지 제거한 것은 아니다.

- [context-aggregate.json](context-aggregate.json): provider의 400 context
  초과 관측과 turn 영수증, 해당 turn의 MASC 입력 구성. 최초 집계와 뒤의 입력
  구성 표본은 서로 다른 시각에 읽었다.
- [reaction-aggregate.json](reaction-aggregate.json): 위에서 선택한 여섯
  turn과 reaction ledger·pending snapshot을 별도로 대조한 결과.

여섯 관측은 Keeper와 turn 번호, 영수증 시간 창의 앞뒤 2초를 허용해 각각
유일한 효과 불명 영수증에 결속했다. 각 영수증 시간 창의 앞뒤 3초를 허용한
범위에는 동일한 `schedule_due` stimulus ID를 가리키는 `turn_started` 원장 행이
하나씩 있었다. 이 시작 행은 queue incarnation을 담지 않으므로 매번 같은
incarnation이었는지는 증명하지 않는다. 추가 읽기에서 같은 stimulus의 재기동 후
시작과 실패 종료 물리 행은 각각 일곱 개였다. 시작 행끼리, 종료 행끼리는 event
ID를 재사용하므로 일곱 행을 일곱 개의 고유 event ID로 세지 않는다. ACK·취소가
기록되는 별도 `keeper_event_queue_transition` source도 읽었으며, 같은 원본에
대한 해당 구간의 ACK·취소는 각각 0행이었다. 별도로 읽은 큐 snapshot에는 해당
원본 하나가 pending이었다. 원장, snapshot, WAL stat은 원자적인 같은 조회가
아니고, 이 관찰은 원본의 전체 생애에서 ACK가 없었다는 증거가 아니다.

선택한 turn의 MASC 입력 집계는 각각 메시지 4,325,449 B, 그중 도구 결과
2,526,116 B와 thinking 743,425 B였다. 이는 공식 client에 건넨 MASC 측
구성으로, client가 보유한 자체 이력이나 실제 provider 요청·토큰 수가 아니다.
선택한 영수증의 trace와 turn에 정확히 일치하는 Agent Core provider-input
snapshot은 읽은 저장소에서 찾지 못했다. 오류에 나타난 1,048,576은 provider가
표현한 context window이며 이 byte 수치에서 변환한 값이 아니다.

실행 경계는 [turn driver](https://github.com/jeong-sik/masc/blob/a97919872890eb9b4e730f65b745ab094ed8ce12/lib/keeper/keeper_turn_driver.ml#L895-L995)의
effect 관측이 확인되지 않을 때 같은 turn의 재시도를 막는다. 반면
[heartbeat batch 판정](https://github.com/jeong-sik/masc/blob/a97919872890eb9b4e730f65b745ab094ed8ce12/lib/keeper/keeper_heartbeat_loop.ml#L727-L735)은
실패 자체로 batch를 ACK하지 않아 다른 종료·취소가 없다면 다음 intake가 다시
선택할 수 있다. 서로 다른 turn에서 같은 stimulus ID가 재선택된 정황을 시간으로
대조했으나, 실제 외부
effect 발생·중복이나 무한 반복은 확인하지 못했다. 임의의 성공 ACK, 무조건
재생, 운영 큐 변경은 하지 않았다.
