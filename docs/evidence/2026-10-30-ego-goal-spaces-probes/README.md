# ego Goal 공간 조사 프로브 (2026-10-30)

RFC-browser-ego-goal-spaces 의 미확인 두 항목을 잰다. 환경: ego-browser 0.6.1.13,
Chromium 156.0.8078.48, Node v24.22.1 (`sdk-version.txt`). 호출은
`ego-browser nodejs < script.mjs` (stdin). 스크립트의 조율 루트는
`/var/folders/bv/cjrbl01x52s6j80krdfb63400000gp/T/masc-ego-probe-20261030-fLER`.

## 시작 때의 공간 목록 (17:52 KST)

user 공간 6개(10-25 것 3개 포함) + agent 공간 `masc-keepers`(id 12) 1개.
10-28 이후 사라진 agent 공간 99~135, 8 은 어디에도 없다. user 공간은 5일째
살아 있고 agent 공간만 회수된다.

## 실험 A — 빈 공간 회수 가설 (기각)

가설: 마지막 탭을 닫으면 ego 가 공간을 회수한다.

`round-a-empty-reap.mjs`: 공간 2개를 만들고(15, 16) 각각 example.com 페이지를
연 뒤 하나의 페이지만 닫고, 5초 간격 24회(2분) `listTaskSpaces()` 로 관찰했다.

결과(`round-a-events.json`): 페이지를 닫은 공간도 24회 모두 목록에 남았다.
프로세스가 끝난 뒤 새 프로세스로 다시 읽어도 둘 다 살아 있었다. 즉시 회수는
일어나지 않는다. 기각.

덤: `finish({keep:[]})` 정리 때 공간 15 에 관리 밖 `about:blank` 탭이 하나
남아 있었다. ego 는 그 탭을 보존했고 공간 소유는 `user` 로 넘어갔다
(`cleanup.json`). 관리 밖 탭이 있는 공간은 finish 로 닫히지 않는다.

## 실험 B — 두 공간 동시 명령 (간섭 없음 확인)

가설: ego SDK 프로세스가 다른 공간의 명령을 막을 수 있다(`ego-native-session-gap`
의 같은 공간 관찰을 다른 공간으로 확정).

`server.py` 가 `fixture.html`(confirm 버튼) 을 127.0.0.1:54130 에 띄웠다.
`round-b-guardian.mjs` 가 공간 17 에서 confirm 을 열고 붙잡는다(17:57:10).
`round-b-observer.mjs` 가 그동안 공간 18 을 열어 이동·info·evaluate·tabs·
info 를 실행하고 단계별 시각을 기록했다.

결과(`observer-stage-*.json`, 17:57:47): 모든 단계가 hold 확인 뒤 266ms 안에
끝났다. 두 번째 info 는 0ms. guardian 이 confirm 을 붙잡은 동안 다른 공간의
어떤 명령도 막히지 않았다. guardian 은 신호 뒤 dismissDialog 성공
(`guardian-finished.json`, 17:58:01).

같은 공간에서 본 프로세스 간 차단(0.6.0.20 관찰)은 공간을 가리지 않는다.
Goal 공간마다 연결을 따로 두는 RFC 설계의 전제가 확인됐다.

## 남은 미확인 — agent 공간 회수 주체

빈 공간·프로세스 종료로는 회수가 일어나지 않고, user 공간은 회수되지 않는다.
회수 주체(시간 기반 회수, 앱 이벤트, 운영자의 창 닫음)는 분당 관찰자
(`watcher.sh`, 로그 `watcher.jsonl`) 가 다음 소실을 잡으면 정한다. 관찰자는
ego 앱 pid, ego 워커 pid, 공간 목록(id, ownership) 을 매 분 기록한다.
