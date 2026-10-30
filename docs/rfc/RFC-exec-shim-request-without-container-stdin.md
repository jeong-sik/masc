---
rfc: "exec-shim-request-without-container-stdin"
title: "microVM 레인이 요청을 stdin 대신 파일로 넘겨요 — container exec -i 를 요청마다 부르지 않으려고"
status: Draft
created: 2026-10-28
updated: 2026-10-28
author: claude
supersedes: []
superseded_by: null
related: ["0395", "0405", "0427"]
---

## 1. 문제

Keeper 가 도구를 한 번 쓸 때마다 호스트의 `container-runtime-linux` 프로세스가 pipe 하나를
닫지 않고 쥐고 있어요. 쌓인 pipe 가 커널 pipe 메모리를 먹으면 새 pipe 가 512 바이트로 줄고,
그 상태에서 출력이 512 바이트를 넘는 프로세스는 읽는 쪽이 조금만 늦어도 출력이 잘려요.

2026-10-27~28 실측이에요.

- 키퍼 VM 23개가 짝 없는 pipe 10,770개를 쥐고 있었어요(13.7시간 뒤, 한 VM 최대 2,095개).
  이후 분당 20~30개씩 늘었어요.
- claude_code 런타임 키퍼의 턴이 `Parse error: auth status: invalid JSON ... (stdout 512 bytes)`
  로 실패했어요. 48시간에 38건, 11개 키퍼에 걸쳤고 크기를 알 수 있는 33건은 모두 정확히 512 바이트예요.
  `claude auth status --json` 출력은 935 바이트예요.
- 누수가 큰 VM 두 개(sister, code-reviewer)를 비웠더니 새 pipe 가 65,536 바이트로 돌아왔어요.
  `auth status` 가 읽는 쪽이 0.4초 늦어도 12/12 온전했어요. 비우기 전에는 12/12 가 512 바이트에서 잘렸어요.
- 효과는 오래 가지 않아요. 새 VM 도 바로 다시 새서, 야간에는 약 1시간, 낮에는 몇 분 만에
  다시 512 바이트로 내려왔어요. 문턱은 누수 개수 하나로 정해지지 않아요(프로브가 올라 있을 때
  합계 8,379~10,864, 내려가 있을 때 8,641~14,701로 겹쳐요).

## 2. 원인

`container exec -i` 한 번마다 pipe 끝 하나가 남아요. `-i` 없이 exec 하면 남지 않아요.
stdout 이나 stderr 를 pipe 로 받는 것은 영향이 없어요. stdin 을 `/dev/null` 에서 받아도 남아요.

| 호출 | 10번 exec 뒤 늘어난 pipe |
|---|---|
| `container exec -i leaktest true < /dev/null` | 10 |
| `container exec leaktest true` | 0 |
| `echo hi \| container exec -i leaktest cat` | 10 |

재현 명령과 환경은 Apple 에 낼 이슈 초안에 있어요. 설치된 container 는 1.3.1 이에요.
초안은 `XPCMessage.swift` 가 1.3.1 과 1.6.1 에서 바이트 단위로 같다고 적고 있어서,
Apple 쪽 버전을 올려도 같은 증상이 남을 수 있어요. 업스트림에서 같은 증상을 확인한 이슈는
찾지 못했어요.

## 3. 지금 구조

- 원격 레인(`Keeper_sandbox_remote`)은 키퍼의 명령 하나를 `masc-exec-shim` 한 번 실행으로 보내요.
  요청은 `Exec_ssh_protocol` 프레임 하나이고 stdin 으로 들어가요.
  명령 하나가 `container exec -i` 한 번이에요(`keeper_sandbox_remote.ml` 의
  `run_argv_with_stdin_held_open_and_status_split`).
- `-i` 는 `Keeper_sandbox_microvm.shim_exec_prefix_for ~stdin:true` 가 붙여요. 호출은
  `keeper_turn_sandbox_runtime.ml` 에 두 곳이에요. 요청 실행용은 `~stdin:true`, 능력 확인용
  `--probe` 는 `~stdin:false` 이고 프레임 없이 돌아요.
- 요청 데이터는 transport 의 argv 에 싣지 않는다는 규칙이 있어요(`keeper_sandbox_remote.ml` 의
  `shim_command` 위 주석). 환경 변수와 인증 정보가 `ps` 에 보이지 않게 하려는 규칙이에요.
- shim 은 stdin 에서 길이 접두 프레임 하나를 읽고 `decode_request` 로 풀어요
  (`exec_shim.ml`, 프레임 읽기 부분). 읽은 뒤 payload 를 자식 프로세스로 띄워요.
- 프로토콜은 `V2`, `V3` 두 major 이고, 프로브가 보고하는 major 로 서로 맞춰요. 새 major 를
  만들지 않고 능력을 더하는 길은 프로브의 보고 항목이에요.
- **stdin 은 취소 신호이기도 해요.** shim 은 프레임을 읽은 뒤에도 자기 stdin 을 계속 지켜봐요. 읽을 수 있게
  되면 남는 바이트는 버리고, EOF 가 오면 "채널이 닫혔다 = 취소"로 보고 payload 를 죽여요
  (`exec_shim.ml` 의 감시 루프, `start_kill On_eof`). 호스트가 취소할 때 stdin 을 닫는 것이 지금의 취소 방법이에요.
  `-i` 없이 부르면 shim 의 stdin 은 처음부터 EOF 라서 그대로는 모든 요청이 시작하자마자 취소돼요.

## 4. 제안

요청 프레임을 stdin 대신 **호스트가 쓰는 파일**로 넘기고, `container exec` 를 `-i` 없이 불러요.

1. 호스트와 게스트가 함께 보는 요청 디렉터리를 키퍼 VM 마다 하나 둬요. 게스트에는 읽기 전용(`ro`)으로
   마운트해요. 호스트 경로는 키퍼마다 따로예요. 요청 프레임의 환경 변수에 토큰이 들어갈 수 있고,
   게스트는 공유 파일의 모드 비트로 읽기를 막지 않으므로(6절 3번) 접근 경계는 "어느 VM 이 그 디렉터리를
   마운트하느냐"예요. 그래서 VM 마다 디렉터리를 따로 둬요.
2. 호스트가 프레임을 임시 이름으로 쓰고 새 이름으로 `rename` 해서 요청 파일을 만들어요. 모드는 0600,
   소유자는 `--user` 로 뜨는 uid 예요. 이름은 요청마다 새로 만드는 임의 토큰이고, 한 번 쓴 이름은
   다시 쓰지 않아요(6절 4번).
3. `container exec <guest> masc-exec-shim --request-file <게스트 경로>` 를 `-i` 없이 불러요.
   요청 데이터는 여전히 argv 에 없어요. 경로만 있어요.
4. shim 은 파일을 읽고, 프레임을 stdin 으로 읽었을 때와 같은 코드로 풀어서 실행해요. 프레임 형식과
   trailer 는 바꾸지 않아요. 마운트가 읽기 전용이라 shim 은 파일을 지우지 못해요.
5. 호스트는 `--probe` 가 보고한 능력으로 새 방식을 쓸 수 있는지 알아요. 새 shim 이 아니면 지금처럼
   stdin 으로 보내요. 두 방식이 한동안 같이 있어요.
6. 호스트가 호출이 끝나면(성공, 실패, 시간 초과 모두) 요청 파일을 지워요. 호스트 프로세스가 중간에 죽어
   남은 파일은 디렉터리를 열 때 정리해요.
7. **취소.** `--request-file` 로 뜬 shim 은 stdin EOF 를 취소로 읽지 않아요. 대신 요청 파일과 짝인
   취소 표식 이름(`<토큰>.cancel`)을 감시 루프의 주기(지금 0.2초)로 확인하고, 생기면 지금의 EOF 와 같은
   경로(`start_kill`)로 payload 를 죽여요. 호스트는 취소하려고 이 표식을 새로 만들어요(이미 있던 이름이
   아니라서 6절 4번의 이름 재사용 함정에 걸리지 않아요). 시간 초과는 shim 이 요청의 deadline 으로 이미
   게스트 안에서 세요. `container exec` 클라이언트를 죽여도 게스트 프로세스가 죽지 않으므로(6절 6번)
   호스트는 클라이언트를 죽이는 것으로 취소하지 않고 표식을 만들어요.

바뀌는 것은 요청을 shim 에 건네는 길뿐이에요. 출력과 trailer 는 지금처럼 stdout 으로 와요.

## 5. 검토한 대안

| 대안 | 왜 아닌가 |
|---|---|
| container 를 1.6.1 로 올려요 | 초안이 가리키는 파일이 같아서 효과가 없을 수 있어요. 올려 봐야 알고, VM 전체가 멈추는 시스템 변경이에요. 효과가 확인되면 이 RFC 는 필요 없어져요. |
| VM 을 주기적으로 교체해요 | 낮에는 몇 분짜리 완화예요. 교체 자체가 키퍼 턴 경계에 걸리는 운영 작업이고, 증상을 덮는 장치예요. |
| 요청을 argv 나 환경 변수로 넘겨요 | 규칙을 깨요. `ps` 에 보여요. |
| stdin 을 `/dev/null` 이나 파일로 바꿔요 | `-i` 가 있으면 누수가 그대로예요(위 표 첫 줄). |
| 게스트마다 `exec -i` 를 하나만 열어 두고 요청을 다중화해요 | 누수는 줄지만 프로토콜을 요청 id 가 있는 스트림으로 바꾸는 큰 변경이에요. 한 shim 이 죽으면 그 게스트의 요청이 모두 영향받아요. 이 RFC 의 범위보다 커요. |
| 호스트에서 pipe 수를 세다가 넘으면 VM 을 다시 띄워요 | 원인을 두고 증상을 쫓는 장치예요. 만들지 않아요. |

## 6. 측정 결과와 남은 질문

리소스 세션이 scratch 컨테이너(python:3.12-slim, 512M, container 1.3.1)에 호스트 디렉터리를 `/req` 로
`ro` 마운트하고, 호스트가 쓴 파일을 `container exec --user 502:20 <컨테이너> cat`(`-i` 없음, stdout 은
pipe)으로 읽어 쟀어요. `masc-exec-shim` 은 돌리지 않았고 Keeper VM 도 아니에요. 일부는 서버를 다시 올리는
동안 돌아서 시간은 흔들려요.

1. **보이는지, 얼마나 걸리는지.** 호스트가 새 이름으로 쓰고 바로 다음 exec 가 읽기: 100/100 정확.
   지연 p50 411ms, p90 1.0s, p99 1.4s. 같은 조건의 `exec true` 는 p50 542ms, p90 1.6s(10번)라서 파일 읽기가
   exec 자체보다 더 걸리지 않아요. 게스트가 없는 이름을 먼저 조회한 뒤 호스트가 만들어도 100/100,
   임시 이름으로 쓰고 새 이름으로 rename 해도 100/100. 크기는 8 MiB 5/5, 64 MiB 3/3 에서 sha256 이
   일치했어요(시료가 적어 크기 의존성은 못 봤어요).
2. **pipe.** `-i` 없이 50번 exec 한 뒤 runtime 의 PIPE fd 는 0 에서 0. `-i` 는 1회당 +1 이었어요.
3. **소유자와 권한.** 게스트는 호스트 파일의 소유자와 모드를 그대로 봐요(502:20, 0600/0640/0644,
   디렉터리 0700). Keeper exec 는 `--user uid:gid`(`shim_exec_prefix_for`)라서 4/4 읽혔어요.
   다만 `--user 1000:1000` 은 실제로 적용되는데도(게스트 안 root 0600 파일은 Permission denied)
   공유 위의 호스트 0600 파일은 읽었어요(마운트 `virtiofs /req virtiofs ro,relatime`). 게스트가 모드 비트로
   막지 않으므로 파일 모드는 경계가 아니에요. 4절 1번이 VM 별 디렉터리를 요구하는 이유예요.
4. **이름 재사용은 실패해요.** 게스트가 읽은 이름을 호스트가 rename 으로 덮어쓰거나 unlink 후 다시 만들면 다음
   exec 가 `No such file or directory`(exit 1)로 실패해요. 바로 직전에 읽은 이름은 29/29, 0.5초쯤 지난 이름은
   33/49 실패했고, 0.66~1.20초 뒤에는 다시 읽혔어요(게스트의 이름 캐시가 1초 안팎으로 보여요). 제자리
   truncate 후 재기록은 50/50 새 내용을 읽었지만 기댈 동작이 아니에요. 요청마다 새 이름이면 1번처럼 100/100
   이에요. 그래서 4절 2번이 요청마다 새 임의 토큰을 써요.

5. **취소 표식은 폴링 주기 안에 보여요.** 게스트의 python 루프가 0.2초마다 `os.stat` 하다가 호스트가 아직 없던
   이름을 만든 경우 100회: 최소 3ms, p50 115ms, p90 185ms, 최대 204ms. 250ms 초과 0건, 1초 초과 0건이에요.
   분포가 폴링 주기(0~200ms) 위상에 몇 ms 를 더한 모양이라 음성 캐시는 보이지 않아요. 디렉터리
   `os.listdir` 로 확인해도 50회 p50 124ms, 최대 269ms 였어요. 4번의 1초 지연은 이미 있던 이름이 바뀔 때
   이야기이고, 없던 이름이 생기는 쪽은 캐시되지 않았어요.
6. **클라이언트를 죽여도 게스트 프로세스는 남아요.** `-i` 없이 부른 `container exec <c> sleep N` 의 호스트 쪽
   클라이언트를 죽인 시험(각 10회, 2초·10초·30초 뒤 확인): SIGTERM 은 클라이언트를 죽이지 못했고 게스트 sleep 도
   10/10 남았어요. SIGKILL 은 클라이언트를 죽였지만 게스트 sleep 은 10/10 남았어요. runtime 의 PIPE fd 는 살아
   있는 exec 하나에 2개였고 SIGKILL 전후로 변하지 않았어요. 따라서 1.3.1 에서는 클라이언트를 죽여서 게스트
   프로세스를 취소할 수 없어요. 4절 7번의 취소 표식이 필요해요.

남은 질문:

- 쓰기 가능한 공유를 키퍼마다 하나 더 붙이는 비용. 지금 작업 볼륨은 virtiofs 가 호스트 descriptor 를 많이
  먹어서 ext4 볼륨으로 바꿨어요(`keeper_sandbox_microvm.ml` 의 작업 볼륨 주석). 요청 디렉터리는 파일이 몇
  개뿐이지만 실제 descriptor 수는 아직 재지 않았어요.
- VM 의 마운트 계획이 바뀌면 기존 VM 은 다음 턴에 교체돼요. `microvm_memory` 를 바꿔 교체해 본 시험(턴
  경계에서 교체, 턴 도중 실패 없음)과 같은 경로라서 같을 것으로 보지만 이 변경으로는 해 보지 않았어요.
- 실제 `masc-exec-shim` 과 Keeper VM 에서의 확인. 위 측정은 `cat` 으로 읽었어요.
- 호스트 프로세스가 중간에 죽으면 shim 은 지금처럼 stdin EOF 로 알지 못해요. `-i` 방식은 호스트가 사라지면
  EOF 로 payload 를 죽이지만, 파일 방식은 요청의 deadline 이나 취소 표식이 올 때까지 payload 가 돌아요.
  이 차이는 감수할 수 있는지 리뷰에서 정해야 해요.
- SIGINT 와 1.6.1 의 신호 전달 수정은 시험하지 않았어요. 업그레이드하면 7번의 전제가 바뀔 수 있어요.
- shim 의 stdin 읽기는 위 3절의 한 곳(프레임)과 감시 루프(EOF 확인과 남는 바이트 버리기) 두 곳이에요.
  `encode_request` 는 프레임 전체(8바이트 길이 + JSON + raw stdin)를 문자열 하나로 만들어서 파일 하나에 그대로
  담겨요. payload 의 stdin 입력이 큰 경우는 프레임 안에 이미 들어 있어요.

## 7. 검증 계획

- `Exec_ssh_protocol`: 프레임을 파일로 쓰고 읽어도 stdin 으로 읽은 것과 같은 요청이 나오는 왕복 테스트.
- shim: `--request-file` 로 받은 요청이 실행되고, 파일이 없거나 길이가 맞지 않으면
  `remote_ssh_transport_error` 로 끝나는 테스트.
- 호스트: 호출이 성공, 실패, 시간 초과로 끝나도 요청 파일이 지워지고, 요청마다 이름이 다르고, 디렉터리를
  열 때 남은 파일이 정리되는 테스트.
- 레인 runner: 새 능력을 보고하지 않는 shim 에는 stdin 방식으로 보내고, 보고하는 shim 에는 파일 방식으로
  보내는 테스트. 두 경우의 argv 에 요청 데이터가 없다는 것도 확인해요.
- 운영 실측: 적용 전후 `.tmp/keeper-vm-memory/pipeleak.py` 의 VM 별 orphan 증가율. 목표는 증가율이
  요청 수에 비례하지 않는 것(0 에 가까움)이고, 새 pipe 가 낮 시간 부하에서도 65,536 으로 유지되는 것이에요.

## 8. 되돌리기

능력 보고를 끄면 호스트가 stdin 방식으로 돌아가요. 요청 디렉터리 마운트는 남아 있어도 해가 없어요.
shim 의 `--request-file` 인자는 stdin 방식과 독립이라 남겨 둬도 돼요.

## 9. 범위 밖

- Apple container 업그레이드와 Apple 에 이슈를 올리는 일. 사용자 결정이에요.
- 이미 쌓인 pipe 를 비우는 일. VM 을 교체하는 운영 작업이에요.
- `docker`, `openssh` 전송. 이 RFC 는 Apple container 의 `exec -i` 만 다뤄요.

## 10. 근거

- pipe 누수 측정과 재현: 리소스 세션의 `.tmp/keeper-vm-memory/` 샘플(`samples-20261027.jsonl`,
  `pipeleak-20261028.jsonl`)과 Apple 이슈 초안(`apple-container-issue-draft.md`).
- `auth status` 절단 38건: 키퍼 `*.decisions.jsonl` 의 `outcome=error` 턴(`stdout 512 bytes`).
- 코드: `lib/keeper/keeper_sandbox_microvm.ml` 의 `shim_exec_prefix_for`, `lib/keeper/keeper_turn_sandbox_runtime.ml`,
  `lib/keeper/keeper_sandbox_remote.ml`, `lib/exec_shim/exec_shim.ml`, `lib/exec_ssh_protocol/exec_ssh_protocol.mli`.
