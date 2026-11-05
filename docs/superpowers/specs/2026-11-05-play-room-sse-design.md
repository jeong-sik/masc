# Play room SSE 전환 설계

## 목적과 성공 조건

Play room의 읽기와 presence를 기존 Observer SSE 연결에 결속해, 활성 화면의 `POST /api/v1/play/room` 2초 주기 호출을 제거한다. 실제 메시지·membership 변경은 `Workspace_dataset_event.Play_room`으로 알리고, TUI는 초기 진입·변경·실패·재연결·trailing 때만 정본 snapshot을 읽는다.

성공은 요청 수로 판정한다: 활성 idle POST 0, 변경 POST 1, pending 중 변경의 trailing POST 1, reconnect POST 1, hidden POST 0이다. 기존 durable message idempotency와 60초 presence expiry는 유지한다.

## 범위

- 실제 transaction 변경 metadata와 `play_room` dataset event
- Observer query의 `play_client_id`·`play_machine`과 정확한 SSE `client_id`를 묶은 presence lease
- 30초 SSE ping renewal과 disconnect cleanup
- TUI의 변경·실패·재연결·trailing read와 request-count 증거

Browser native event, closed PR #48180의 충돌·merge·rebase·운영 설치는 제외한다.

## 계약과 설계

### 대화는 machine 간 공유다

기존 `test_play_room`의 one cross-machine conversation 계약을 유지한다. `Play_room {machine}`의 machine은 변경을 일으킨 source의 metadata일 뿐, TUI가 transcript를 필터하는 기준이 아니다. 열린 Play room은 message나 public membership 변경이 어느 machine에서 왔든 재검증한다.

### 실제 변경만 알린다

`Play_room.perform_with_change`는 기존 transaction 안에서 `snapshot * change`를 반환한다. `change`는 `machine`, `message_committed`, `membership_changed`다. 기존 `perform`은 snapshot만 반환하는 wrapper로 유지한다.

- `message_committed`: 새 메시지를 실제 삽입한 경우만 true다. idempotent/conflicting retry는 새 삽입이 아니다.
- `membership_changed`: 공개 snapshot의 `(name, speaker, machine)` 집합이 바뀐 경우만 true다. `seen_at` 갱신은 제외한다.
- 같은 principal의 두 번째 tab이 이미 같은 public member를 제공하면 새 event가 아니다. 한 tab이 떠나도 다른 tab이 남아 public member가 유지되면 event가 아니다. 마지막 tab이 떠나거나 public member가 machine을 바꾸거나 expiry로 사라지면 event다.
- 이미 expiry된 raw row를 정리하는 것만으로 public snapshot이 바뀌지 않으면 event가 아니다. raw per-client row를 모두 감시하지 않는다.

HTTP route와 `masc_play_room` tool은 `message_committed || membership_changed`일 때만 `Workspace_dataset_event.Play_room {machine}`을 알린다. heartbeat나 seen_at-only renewal에는 알리지 않는다.

### HTTP Read/Say는 presence를 소유하지 않는다

`Read`와 `Say`는 membership row를 upsert하지 않는다. Read는 정본 snapshot만 반환하고, Say는 message만 기록한다. 따라서 늦은 HTTP Read/Say가 새 SSE lease의 machine이나 presence를 덮어쓰거나 부활시키지 않는다. 기존 `play_room.mli`의 “Read only; does not renew presence” 계약을 구현과 일치시킨다.

Join/Leave만 presence에 영향을 준다. HTTP Join은 활성 lease가 없을 때만 Join을 수행한다. HTTP Leave는 활성 lease가 있으면 무시하고 현재 snapshot을 반환한다. 활성 lease가 없을 때만 기존 Leave를 수행한다. 이렇게 오래된 HTTP Leave가 replacement presence를 지우지 못하게 한다. `Server_play_room_events`는 이 guard와 route를 제공하고, `masc_play_room` tool의 Say는 membership을 바꾸지 않으므로 같은 change/announce 경로를 공유한다.

### Presence는 Observer의 생명주기를 따른다

Query는 `play_client_id`와 `play_machine`을 사용한다. Control `machine`은 기존 machine advance에만 쓰고, `play_machine`은 room membership에만 쓴다. Watch machine은 진행하지 않는다.

`who`와 role은 정확한 register-returned `Sse.client`의 `agent_name`·`role`로 결정한다. body/query의 `who`는 신뢰하지 않는다. `Masc_domain.has_permission role CanPlayMachine`이 필요하며, play scope가 있으나 권한이 없으면 Observer를 등록하지 않고 거부한다. 현재 모든 역할이 permission을 가지므로 denial은 permission predicate를 교체하는 test seam으로 검증한다.

`Server_play_room_events`는 `(base_path, agent_name, play_client_id)`를 key로 `sse_client_id`와 `play_machine`을 보관한다.

- connect: Join 성공 후 lease를 등록한다. 실패하면 lease 없이 Observer 등록도 취소한다.
- ping renewal: key와 `sse_client_id`가 모두 일치할 때만 Join한다. 실패하면 로그를 남기고 Observer는 유지한다. 다음 ping을 기다리며, 갱신이 없으면 기존 60초 expiry가 적용된다.
- disconnect: key와 `sse_client_id`가 모두 일치할 때만 lease를 제거하고 Leave한다. registry removal과 Leave는 cancellation 보호 아래 완료하고, 실패는 로그와 expiry로 남긴다. 원래 cancellation은 숨기지 않는다.

Eio mutex로 key 교체와 DB 효과를 순서화한다. Sse registry·다른 store mutex는 잡지 않는다. connect/renew/disconnect는 key와 id를 다시 확인하며, replacement가 있으면 이전 id의 효과는 무시한다.

### reconnect는 새 lease를 먼저 만든다

기존 transport는 이전 session을 먼저 닫고 새 connection을 등록해 Leave/Join gap이 생긴다. 이를 바꿔 새 Observer와 새 presence lease를 먼저 만들고, 아직 새 connection이 transport registry에 게시되기 전에 이전 connection을 닫는다. 이전 disconnect callback은 새 `sse_client_id`와 다륵므로 replacement를 지우지 않는다. 일반 SSE handoff와 queue의 기존 동작은 유지한다.

### TUI는 성공한 polling을 멈춘다

초기 `next_read=0`은 첫 Read를 허용한다. 활성 Read 성공 후 `next_read=infinity`다. 실패는 기존 2초 retry를 유지한다. `revalidate`는 `next_read=0`으로 바꾸고 pending이 있으면 `changed_since=true`로 남긴다. 응답 시 changed_since면 즉시 trailing read를 예약하고, 아니면 성공은 infinity로 둔다. inactive 전환은 기존 Leave 의무와 재시도를 유지한다.

`Workspace_dataset_event.Play_room`은 열린 room에만 `revalidate`를 적용한다. machine 일치 여부로 transcript를 제한하지 않는다. hidden room은 기존 Leave 규칙을 유지하고, 재진입은 새 Read를 시작한다.

## 경계와 금지 사항

- `play_client_id`는 기존 identifier 계약과 동일한 1..128자의 ASCII letters/digits/dots/underscores/hyphens다.
- `play_machine` 없는 `play_client_id`나 `play_client_id` 없는 `play_machine`은 허용하지 않는다. 둘 다 없으면 Play scope가 없는 일반 Observer다.
- dataset event에는 메시지 본문·이미지·membership rows를 넣지 않는다. 정본 snapshot은 Read로 확인한다.
- failed Read는 재시도하지만 성공한 Read의 주기 polling은 복구하지 않는다.
- idempotent send·draft·viewer·pagination·inactive Leave 계약을 유지한다.
- 새 dependency, production 설치, `~/me/.masc` 변경, merge·rebase는 하지 않는다. 외부 coding session의 로컬 Dune build 대신 명시적 원격 suite와 exact-source PTY로 검증한다.

## 검증

1. `test_play_room`: 새 메시지와 public membership만 change이며, idempotent/no-op/seen_at-only는 change가 아니다. Read/Say가 presence를 바꾸지 않는 것도 확인한다.
2. `test_server_play_room_events`: connect·ping·disconnect, replacement stale 효과 차단, old HTTP Leave 차단, connect/renew/disconnect 실패와 cancellation, permission denial, query와 machine 비진행.
3. `test_tui_play_room`: 성공 후 polling 없음, 실패 retry, pending trailing, inactive Leave.
4. `test_tui_observer`: `play_room` dataset decode와 다른 dataset 영향 없음.
5. `test_tui_play_room_push.py`: exact-source PTY에서 초기 1, idle 0, 변경 1, trailing 1, reconnect 1, hidden 0 및 presence/query 계약 측정.
6. 기존 24 suite에 `test_play_room`, `test_h2_play_room`, `test_tui_play_room`, `test_server_play_room_events`, `test_tui_play_room_push`를 추가하고 독립 source review를 받는다.

## 후속 작업

Browser backend-native event는 별도 프로젝트로 분리한다. Play room이 끝나도 Browser server sampling은 남아 있으므로 전체 native push 완료로 부르지 않는다.
