---
rfc: "exec-shim-reports-request-acceptance"
title: "shim 이 요청을 받아 시작해도 좋은지 호스트와 먼저 맞춰서, 전달되지 않은 실행과 결과를 잃은 실행을 가른다"
status: Draft
created: 2026-10-29
updated: 2026-10-29
author: vincent + claude
related: ["0454", "0371"]
---

# RFC: 요청을 받은 순간을 먼저 맞춘다

## 0. 한 문장 요약

`container exec` 가 멈추면 호스트는 요청이 게스트에 닿았는지 알 길이 없어서, 닿지도 않은 실행까지 "이미 실행됐을 수 있다"로 굳히고 Keeper 의 턴을 끝낸다. shim 이 요청을 받았음을 먼저 알리고 호스트의 "시작해도 좋다" 신호를 받은 뒤에만 자식을 시작하게 하면, 호스트는 시간이 아니라 관측한 사건으로 둘을 가를 수 있다.

## 1. 문제 — 계측

측정 대상: `~/me/.masc/logs/system_log_2026-10-29.jsonl` 과 서버 시작 로그 `masc-start-20261029T113036Z.log`. 측정 시각은 2026-10-29 20:5x KST 이다.

- `terminal_effect_failed` 가 오늘 110건이다. 시간대별로 06Z 13, 08Z 6, 09Z 12, 10Z 8, 11Z 71건이다. 한 사건이 로그 여러 곳에 찍히므로 줄 수는 사건 수보다 크다.
- 09Z 이후 많이 맞은 Keeper 는 `code-reviewer-uncle`, `code-reviewer`, `masc-pro-builder`, `kidsnote-qa-hub-manager`, `e-masc-the-leader`, `context-reviewer`, `code-reviewer-brother`, `wkbl-front`, `music-sensei` 이다.
- 실패 문구는 모두 같다. `tool_execute` 가 "The endpoint did not provide a trustworthy command result. The remote effect may have happened" 를 돌려준다.
- 같은 서버 실행에서 `container exec -i` 가 19초, 29초, 44초에 시간 초과로 죽은 기록이 있다(`Process_eio ... Timeout after ...`).
- 20:33~20:35 에는 Keeper 명령이 아닌 `container stop`, `container delete --force`, `container inspect`, `container list --all` 도 30초 시간 초과가 났다. 같은 시각 컨테이너 런타임 로그에 `failed to close stdin: The transport threw an unexpected error` 가 여러 프로세스에서 이어진다.
- 측정 시점의 호스트 부하는 16코어에 평균 26 이었다. 정체와의 인과는 확인하지 못했다.
- 정체의 원인은 이 RFC 가 다루지 않고, 밝히지도 못했다. 알고 있는 것은 "정체가 일어나면 지금 구조는 턴을 끝낸다" 까지이다.

게스트 15개에 `container exec <vm> true` 를 던지면 모두 1초 안에 끝났다. 정체는 지속되지 않고 간헐적으로 생긴다.

## 2. 현재 동작

코드 좌표는 main `73b05a68a36` 기준이다.

1. `lib/keeper/keeper_sandbox_remote.ml:1004` 는 `container exec` 클라이언트를 띄우기 **전에** `observation := Execution_unavailable Transport_unavailable` 로 둔다. 이 값이 "효과를 알 수 없음" 이다.
2. 호스트가 기다리는 시간은 `local_wall_budget` (`:537`) 로, 연결 제한 + 명령 제한 + 4초이다.
3. 시간이 다 되거나 끝의 trailer 를 읽지 못하면 `completed_execution_observation` (`:867`) 이 `None` 을 돌려주어 1번의 값이 그대로 남는다.
4. 실행 수신 확인(`execution_receipt`) 은 trailer 안에만 있다(`lib/exec_ssh_protocol/exec_ssh_protocol.ml:524`). shim 은 자식이 보낸 경계 신호 `"A"`(샌드박스 적용) 를 자식이 끝난 뒤에야 읽고(`lib/exec_shim/exec_shim.ml:880`, 호출은 `:1296`), 맨 끝에 한 번 쓴다(`:1118`). 채널이 죽으면 이 정보도 함께 사라진다.
5. `lib/keeper/keeper_tool_execute_runtime.ml:53` 의 `command_observation` 은 위 값을 `Command_effect_unknown` 으로 바꾸고, 실행 결과는 `Dependency_unavailable` + `Effect_outcome_unknown` 이 된다.
6. `lib/keeper/keeper_tools_agent_core_handler.ml:143` 은 `Proven_pre_effect` 실패는 아무 일도 하지 않고, `Effect_outcome_unknown` 과 `Proven_post_effect` 는 턴을 끝내는 `Terminal_effect_failed` 로 올린다. 이 실패는 같은 턴을 다시 돌리지 않고 원인이 된 자극을 폐기한다(`keeper_terminal_reason.mli`).

그래서 턴이 끝나느냐는 클라이언트를 띄우기 전에 정한 값 하나에 달려 있고, 그 값을 바꿀 수 있는 정보는 시간 초과뿐이다.

## 3. 구분해야 하는 세 사건

| 사건 | 지금의 처리 | 실제 |
|---|---|---|
| A. 요청이 게스트에 닿지 못했다(관리 쪽 정체, 연결 실패) | 알 수 없음, 턴이 끝난다 | 효과가 없다. 다시 해도 안전하다 |
| B. 자식을 시작했는데 결과를 받지 못했다 | 알 수 없음, 턴이 끝난다 | 알 수 없음이 맞다 |
| C. trailer 까지 받았다 | 관측됨 | 정상 |

A 와 B 는 지금 같은 값이다. 이 RFC 는 A 를 `Request_not_sent` 로 떼어낸다. 이 값은 타입에 이미 있고(`Keeper_sandbox_remote.Request_not_sent`), `Proven_pre_effect` 로 이어져 턴을 끝내지 않는다.

## 4. 제안

### 4.1 한 방향 알림만으로는 부족하다

shim 이 "받았다" 를 먼저 알리기만 하면 안 된다. 알림을 쓰는 것과 자식을 시작하는 것 사이에 호스트가 알림을 읽는다는 보장이 없어서, 호스트가 알림을 못 받았는데도 자식이 이미 시작됐을 수 있다. 그러면 "알림을 못 받았으니 효과가 없다" 는 거짓이 된다.

### 4.2 두 단계로 맞춘다

1. 호스트가 요청을 보낸다.
2. shim 이 요청을 읽고 샌드박스를 적용한 뒤, 자식을 시작하기 **전에** 수신 프레임을 낸다. 자식은 경계 신호 `"A"` 를 쓴 다음 시작 신호를 기다린다.
3. 호스트는 수신 프레임을 읽은 뒤에만 시작 신호를 보낸다.
4. shim 은 시작 신호를 받으면 자식을 시작한다. 정해진 시간 안에 받지 못하면 자식을 시작하지 않고 거절 trailer 로 끝낸다.

이렇게 하면 다음이 성립한다.

- 호스트가 수신 프레임을 못 읽었다면 시작 신호를 보내지 않았으므로 자식은 시작되지 않았다. 시간 초과든 비정상 종료든 `Request_not_sent` 이다.
- 시작 신호를 보낸 뒤 trailer 를 받지 못하면 `Transport_unavailable`(알 수 없음) 이다. 지금과 같다.
- 시작 신호를 쓰는 중에 오류가 나면(`EPIPE` 등) shim 은 신호를 받지 못했으므로 `Request_not_sent` 이다.

`keeper_sandbox_remote.ml:1004` 의 대입은 시작 신호를 보낸 **뒤로** 옮긴다. 새 분류 상태는 만들지 않는다.

### 4.3 프로토콜

- 프로토콜을 V4 로 올리고, V2/V3 읽기 코드는 만들지 않는다(하위 호환 reader 금지 규칙). 프로브(`render_probe`) 가 이미 shim 릴리스를 싣고 있어 `remote_shim_outdated` 경고가 나는 구조를 그대로 쓴다.
- 수신 프레임은 stderr 맨 앞에 trailer 와 같은 구분자로 감싼 JSON 으로 낸다. 자식이 시작하기 전이라 자식 출력과 섞이지 않는다. 호스트의 stderr 스트림 분리 코드(`stream_stderr_chunk`)는 이미 끝의 trailer 를 위해 꼬리를 쥐고 있어서, 맨 앞 프레임을 하나 떼는 일을 더하면 된다.
- 시작 신호는 요청 프레임 다음에 stdin 으로 보내는 고정 형태의 프레임이다.

### 4.4 시간 값은 판정에 쓰지 않는다

시작 신호를 기다리는 시한 `G` 는 shim 이 스스로 포기하는 데에만 쓰고, 호스트의 분류는 어느 프레임을 받았는지로만 정한다. `G` 는 수신 프레임을 낸 순간부터 호스트가 신호를 쓰기까지의 왕복에 여유를 더한 값으로, 설정 한 곳(SSOT)에서 읽는다. 값은 배포 전에 왕복 지연의 99백분위수를 재서 정한다(지금은 재지 않았다).

## 5. 검증

에이전트 하네스 원칙에 따라, 분류가 맞는지를 측정할 수 있게 먼저 만든다. 화면 문구를 검사하는 테스트는 만들지 않는다.

1. **순수 분류 함수.** `(받은 프레임들, 종료 원인) -> observation` 을 경우를 다 따지는 `match` 로 쓰고, 표 전체를 테스트한다. 시작 신호를 보낸 뒤에는 `Request_not_sent` 가 나올 수 없다는 성질을 같이 건다.
2. **가짜 shim 하네스.** 다음 다섯 동작을 하는 스크립트를 `container exec` 자리에 둔다: 표준 입력을 읽지 않고 멈춤 / 수신 프레임을 내고 시작 신호를 기다리다 멈춤 / 시작 신호를 받고 부수효과 파일을 만든 뒤 멈춤 / 정상 종료 / 잘못된 프레임. 자식이 부수효과 파일을 만들게 해서 "`Request_not_sent` 로 분류했는데 파일이 있다" 가 한 건도 없음을 확인한다. 클라이언트를 임의 지점에서 죽이는 반복 시험으로 같은 성질을 본다.
3. **운영 측정.** `tool_execute` 실패에 `observation` 값을 필드로 남기고, 배포 전후로 `Request_not_sent` 와 `unknown` 의 건수를 센다. 기준선은 오늘의 110건이다. 목표 수치는 기준선을 더 모은 뒤 정한다.

## 6. 검토한 대안과 거절 이유

- **시간 초과를 늘린다.** 정체가 길어지면 같은 오류가 나고 Keeper 가 더 오래 막힌다. 판정이 시간에 달린 것은 그대로이다.
- **재시도나 쿨다운을 얹는다.** 효과가 있었을 수 있는 명령을 두 번 실행할 위험이 있고, 증상을 가리는 방식이다.
- **먼저 `container exec ... true` 로 살아 있는지 확인한다.** 확인과 실제 호출 사이에 상태가 바뀔 수 있고, 이것도 시간으로 판정한다.
- **한 방향 수신 알림만 둔다.** 4.1 에서 보인 대로 "못 받음" 이 "시작 안 됨" 을 보장하지 못한다.
- **결과를 잃은 뒤 요청 번호로 게스트에 물어본다.** 사건 B 를 줄일 수 있지만 정체된 관리 채널로 다시 물어야 하고, 게스트에 실행 기록(영속 상태)을 새로 둬야 한다. 이 RFC 의 범위가 아니며 필요하면 후속 RFC 로 다룬다.

## 7. 범위 밖

- 관리 쪽 정체 자체(`failed to close stdin`, `exec -i` 의 파이프 누수, 죽은 클라이언트가 게스트를 붙잡는 문제). 별도 이슈로 다룬다.
- 사건 B 의 해소. 이 RFC 는 B 를 알 수 없음으로 남긴다.

## 8. 비용과 위험

- 프로토콜이 V4 로 올라가는 hard cut 이다. 게스트 이미지(`masc-sandbox-ocaml:*`)와 원격 엔드포인트의 shim 을 모두 새 릴리스로 맞춰야 한다. 서버를 먼저 올리면 옛 shim 이 모두 거절되고, shim 을 먼저 올리면 옛 서버가 모두 거절된다. 배포 순서와 중단 시간은 운영자가 정한다.
- 왕복이 한 번 늘어서 명령마다 지연이 조금 늘어난다. 늘어나는 양은 아직 재지 않았다.
- 시작 신호를 기다리는 동안 자식은 샌드박스가 적용된 채 멈춰 있다. 시한 `G` 가 지나면 정리한다.

## 9. 열린 결정

1. **D1.** 하위 호환 없이 V4 로 올리고 배포 순서를 정한다.
2. **D2.** 수신 프레임을 stderr 맨 앞(권장)에 둘지 stdout 맨 앞에 둘지. stderr 는 이미 trailer 분리 코드가 있어 변경이 작고, stdout 은 이진 출력 모드(`Binary_bytes`)와 얽힌다.
3. **D3.** 시한 `G` 의 값과 근거. 왕복 지연을 먼저 잰다.
4. **D4.** `Observe` 와 `Guest_local` 모드에도 같은 두 단계를 적용할지. 읽기 전용이라도 분류를 통일하는 편이 단순하다.

## 10. 구현 단계

RFC 가 `Active` 가 된 뒤, 아래 순서로 스택 PR 을 만든다.

1. 프로토콜 V4 타입과 순수 분류 함수, 표 테스트.
2. shim: 수신 프레임, 시작 신호 대기, 시한.
3. 호스트 실행기: 프레임 분리, 시작 신호 전송, `observation` 대입 위치 이동.
4. `tool_execute` 연결과 `observation` 필드 계측.
5. 게스트 이미지와 원격 엔드포인트 배포 절차.

## 11. 근거 좌표

- 로그: `~/me/.masc/logs/system_log_2026-10-29.jsonl`, `masc-start-20261029T113036Z.log`, `container system logs --last 2h`.
- 코드: 위 §2 의 파일과 줄.
- 관련: RFC-0454(실패한 keeper 요청은 typed 값), RFC-0371(effect 경계).
