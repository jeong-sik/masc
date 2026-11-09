# Keeper memory lag와 catch-up 경로 점검

2026-11-09, effective base path `/Users/dancer/me`.
운영 서버의 `~/me/.masc`를 읽고 원본 요청의 상태 전이와 구현을 대조했다.
서버 재시작, 설정 변경, 요청 재전송, cursor/ACK 수정은 하지 않았다.

## 확인한 상태와 판단 한계

19:05 KST 관측에서 다음 두 Keeper가 오래 정체되어 있었다.

| Keeper | 미처리 턴 합계 | 마지막 digest 이후 | Memory gap atoms |
| --- | ---: | ---: | ---: |
| code-reviewer | 1,646 | 39.36시간 | 4,209 |
| pr-updater | 1,272 | 70.11시간 | 905 |

`lagging`은 미처리 턴이 있다는 뜻이다. 짧게 나타났다 사라지는 lag도 있다.
`gap`은 Librarian의 위치가 provider가 받아들인 context 시작보다 뒤에 있어,
그 사이 atoms가 요청 context에서 빠졌다는 관측이다. 이것만으로 저장된 원본이
삭제되었다고 판단할 수 없다.

11월 6–9일 system log 785,684줄을 읽었다. 파싱 실패는 없었다.
현재 날짜의 로그는 읽는 중에도 늘어났고 owner 파일은 별도로 읽었으므로,
전체를 하나의 원자적 snapshot으로 취급하지 않는다.
선택한 상태와 파일 크기·시각·owner hash는
[audit-summary.json](../evidence/librarian-catch-up-20261109/audit-summary.json)에 남겼다.
원본 로그와 요청 본문은 Git에 넣지 않았다.

code-reviewer의 원본 owner에는 `dispatch_intended` 601회,
`capacity_wait` 거절 600회 뒤 `worker_absent` 관측 1회가 있었다.
pr-updater는 각각 296회, 295회, 1회였다. 둘 다 마지막 dispatch에 대한
명시적 거절이나 완료 증거가 없는 상태다.

여기서 `capacity_wait`은 provider의 동시 실행 수나 quota가 아니다.
[exact_worker.py](../../addons/exact_worker.py)는 보류 중인 host 요청을 합친
listing이 Add-on의 `max_reply_bytes`를 넘을 때 이 답을 반환한다.
이 거절은 worker 요청을 만들지 않는다. 한 요청만으로 frame을 넘는 경우는
별도 terminal refusal로 저장된다.

실행 중인 Add-on 0.2.3의 manifest 한도는 4,194,304 bytes였다.
컨테이너 image identity를 대조한 뒤 `/exact_worker.py`를 읽기 전용으로
복사해 비교했다. 실행 worker와 후보 소스의 SHA-256이 같았다.
호스트 소스만 보고 worker의 동작을 추정한 결과가 아니다.

이후의 `absent`는 조회한 worker가 그 요청을 보유하지 않는다는 증거다.
마지막 전송이 실행되지 않았다는 증거까지 되지는 않는다.
앞선 거절들을 근거로 마지막 불확실한 dispatch를 자동 재전송할 수 없다.
owner mtime이 오래되었다는 사실도 시도 부재를 증명하지 않는다.
동일한 `Absent` 재관측은 기존 journal을 다시 쓰지 않는 구현이다.

설치된 서버는 `6a6ec4c28e2f26edcf272e37115ac2f655005f2b`,
구현 시작점은 `ce6a2e21963cbbcc485c1f8189eb983fa6e0335a`다.
관련 원본 dispatch·owner·floor·refresh·wake 경로는 설치 commit과 대조했다.
아래 변경은 후보 소스이며, 이 운영 서버에 설치되었다는 뜻은 아니다.

## 부족했던 경로

1. **접수 전 용량 대기를 깨우는 신호.** 실제 Exact 결과 전달은 해당 원본의
   Keeper를 깨운다. 용량 거절된 다른 Keeper는 worker에 등록되지 않아 자기 결과
   이벤트를 받지 않는다. 새 턴이나 설정 변경도 없으면 다음 입력을 기다린다.
2. **원래 대기 사유.** durable consumer가 worker 대기, publication 대기,
   basis 변경을 모두 payload 없는 Pending으로 올렸다. explicit admission과 긴
   메시지 floor의 worker 대기도 일반 문자열로 접혀 같은 진단 손실이 있었다.
3. **채팅에서의 직접 제어와 새 관측.** `/memory`는 journal 표시 전환이었다.
   선택한 Keeper의 catch-up 요청이나 새 상태 조회를 하는 명령은 없었다.
4. **불확실한 전송의 안내.** 수동 작업의 POST가 취소되거나 응답을 잃었을 때
   서버 거절과 접수 결과 미확인을 구분하고 원래 workspace에 묶인 결과를 남겨야 한다.

기존 자동 경로 자체는 있었다. 턴 후, launch/boot, 설정·export 변경,
Exact 결과 전달이 원본을 재검토하며, 진전이 있으면 저장된 cursor부터 계속 읽는다.
따라서 타이머나 backlog 수치에 따른 강제 재전송을 추가하지 않는다.
로그의 `inventoried original changed` 경고도 개별 inventory 읽기 실패만
보여 준다. 설정 변경 경로는 이미 큐에 있던 이름을 보존하므로,
경고만으로 모든 wake가 유실되었다고 결론낼 수 없다.

## n부터 n+m까지의 환경·도착 순서

| 순서 | 환경 또는 전이 | 지켜야 할 동작 | 확인 방법 |
| --- | --- | --- | --- |
| n | 새 입력과 새 원본 | 원본 ID와 입력을 먼저 보존하고 기존 lane으로 처리한다. | 기존 owner/consumer 소스 대조 |
| n+1 | 다른 Keeper가 listing frame을 차지함 | 접수 전 Capacity를 보존한다. 용량이 풀리는 실제 결과에서 같은 installation의 대기자를 깨운다. | worker 회귀 테스트 실행, host 회귀 테스트 추가 |
| n+2 | 완료 신호가 대기 측정 등록보다 먼저 옴 | pass 시작과 등록 후의 immutable mark를 대조해 자기 wake를 남긴다. | host 순서 경합 회귀 테스트 추가 |
| n+3 | 등록 후 완료, 다른 workspace 또는 installation의 완료 | 해당 범위의 Capacity만 깨운다. 결과 불확실 대기는 Capacity로 바꾸지 않는다. | host 범위 회귀 테스트 추가 |
| n+4 | 용량 거절 후 worker 재시작 | 같은 원본 ID로 재검토한다. 확정된 접수 전 거절만 새 submit을 허용한다. | worker 저장소 재개 회귀 테스트 실행 |
| n+5 | dispatch 후 응답 유실, Unknown 또는 Absent | 원본 ID와 결과 불확실 상태를 표시한다. 재전송이나 ACK를 추측으로 하지 않는다. | retained owner와 Submit_once 소스 대조 |
| n+6 | worker가 처리 중이거나 연결 불가 | Processing과 Unreachable을 구분한다. 보존된 원본을 조회한다. | typed 상태 전파 및 decoder 회귀 테스트 |
| n+7 | 긴 입력이 원본 하나로도 frame을 넘음 | 실제 size refusal을 근거로만 입력을 줄인다. floor의 leaf worker ID와 대기 사유도 보존한다. | floor/dispatch 소스 대조 |
| n+8 | Memory 기록·gate·ACK 사이 중단 | publication 대기를 구분하고 receipt가 확인된 입력만 ACK한다. | 기존 commit/ACK 경로를 유지했는지 소스 대조 |
| n+9 | paused Keeper 또는 조용한 Keeper | 새 Keeper 턴 없이 독립 Memory lane의 기존 작업을 깨운다. | catch-up route와 queue 연결 소스 검토 |
| n+10 | Librarian 전체 Disabled/Invalid 또는 executor 미초기화 | 수동 접수를 거절한다. Add-on만 unattached라면 기존 commit/ACK 복구를 위해 wake를 접수할 수 있으며, 이후 실제 대기를 구분한다. | route·owner 분기 소스 검토 |
| n+11 | workspace A→B→A, POST 전후 취소 | 전송 전 실패와 접수 결과 미확인을 구분한다. 결과는 원래 대상에 남기고 후속 read/retry 권한을 주지 않는다. | TUI 요청 소유권·취소·결과 경로 소스 검토 |
| n+12 | fleet snapshot이 오래됨, 채팅 화면에서 상태 조회 | 선택한 Keeper의 row를 새로 읽고 조회 시각과 마지막 처리 관측 시각을 따로 보여 준다. | scoped GET·owned completion 소스 검토 |
| n+m | durable·explicit admission·floor가 같은 worker를 공유 | 세 경로의 Capacity를 누락하지 않는다. admission의 관측을 durable pass 시각과 섞지 않는다. | 별도 admission 관측과 floor typed 전파 소스 검토 |

## 후보 변경과 사용법

Keeper 채팅에서:

- `/memory status`: 현재 Keeper의 memory health row를 새로 조회한다.
- `/memory sync`: 기존 Memory lane에 따라잡기를 요청한다. 접수/합쳐짐과
  처리 완료를 구분한다. paused Keeper에도 요청할 수 있다.
- `/memory`: 기존 journal 표시 전환을 유지한다.

관리자 POST는 `/api/v1/keepers/memory-catch-up`다. Keeper 이름과 필수
`expected_workspace`를 검증하고, `202`의 엄격한 영수증으로
`submitted` 또는 `coalesced`, `completion: "unobserved"`를 돌려준다.
이 경로도 기존 원본을 먼저 복구하므로 불확실한 원본을 우회하지 않는다.

health v11은 원본 request ID·installation ID와 구체적인 pending 원인을 보존한다.
별도의 `admission_wait`는 durable pass가 drained여도 explicit admission의
실제 worker 대기를 보여 준다. main의 나이 구간 변경이 v10을 사용하므로
후보는 v11로 분리했다. v9/v10 서버와 새 decoder를 혼용하면 읽기 실패를
표시하므로 서버와 TUI/dashboard를 함께 갱신해야 한다.

실제 결과가 전달되면 같은 workspace·installation의 알려진 Capacity 대기자만
다시 깨운다. durable, explicit admission, floor의 대기에 적용한다.
다른 원인 대기를 임의로 실패 또는 재전송 가능 상태로 바꾸지 않는다.

## 검증 범위와 남은 운영 문제

worker 회귀 8개와 admission wait를 포함한 dashboard 관련 테스트 103개,
TypeScript 검사가 통과했다. 변경한 OCaml 50개 파일의 문법 검사도 통과했다.
host/OCaml 회귀 테스트는 작성했으나 이 세션에서 실행하지 않았다.
저장소 실행 규약에 따라 로컬 Dune 빌드와 CI 대기 루프는 실행하지 않는다.
OCaml 문법 검사와 소스 리뷰는 타입 검사·실행 검증을 대신하지 않는다.

기존 두 정체 요청의 마지막 dispatch 결과는 이 관측만으로 확정하지 못했다.
수동 sync와 새 wake 경로도 이 사실을 해소하지 않는다. 실제 원본의 실행·완료
증거 또는 명시적인 접수 전 거절 증거가 필요하다. 이번 작업은 그 상태를 숨기지
않고 진단·제어할 경로와, 확정된 Capacity 대기가 방치되는 예방 경로를 제공한다.
