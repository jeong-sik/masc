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

## 4. 제안

요청 프레임을 stdin 대신 **호스트가 쓰는 파일**로 넘기고, `container exec` 를 `-i` 없이 불러요.

1. 호스트와 게스트가 함께 보는 요청 디렉터리를 키퍼 VM 마다 하나 둬요(쓰기 가능한 bind 공유).
   호스트 경로는 키퍼마다 따로예요.
2. 호스트가 프레임을 임시 이름으로 쓰고 `rename` 해서 요청 파일을 만들어요. 모드는 0600, 소유자는
   `--user` 로 뜨는 uid 예요. 이름은 요청마다 새로 만드는 임의 id 예요.
3. `container exec <guest> masc-exec-shim --request-file <게스트 경로>` 를 `-i` 없이 불러요.
   요청 데이터는 여전히 argv 에 없어요. 경로만 있어요.
4. shim 은 파일을 읽자마자 지우고(`unlink`), 프레임을 stdin 으로 읽었을 때와 같은 코드로 풀어서 실행해요.
   프레임 형식과 trailer 는 바꾸지 않아요.
5. 호스트는 `--probe` 가 보고한 능력으로 새 방식을 쓸 수 있는지 알아요. 새 shim 이 아니면 지금처럼
   stdin 으로 보내요. 두 방식이 한동안 같이 있어요.
6. 호스트는 실행이 끝나면 요청 파일이 남았는지 보고, 남았으면 지워요(shim 이 읽기 전에 죽은 경우).

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

## 6. 열린 질문 (측정 대기)

아래는 아직 재지 않았어요. 설계의 전제라서 결과가 나쁘면 이 RFC 는 접어요.

1. 호스트가 파일을 쓰고 바로 `container exec` 가 읽을 때 게스트에서 파일이 보이는 비율과 지연.
   virtiofs 캐시 때문에 안 보이는 순간이 있으면 shim 이 짧게 다시 시도해야 하는데, 그건 임계값을 정하는 일이에요.
2. 이 방식으로 exec 를 50번 한 뒤 `container-runtime-linux` 의 PIPE 개수가 늘지 않는지.
3. 공유 파일의 소유 uid 와 모드가 `--user uid:gid` 로 뜬 프로세스에서 읽히는지.
4. 쓰기 가능한 공유를 키퍼마다 하나 더 붙이는 비용. 지금 작업 볼륨은 virtiofs 가 호스트 descriptor 를
   많이 먹어서 ext4 볼륨으로 바꿨어요(`keeper_sandbox_microvm.ml` 의 작업 볼륨 주석). 요청 디렉터리는
   파일이 몇 개뿐이라 작지만, 실제 descriptor 수를 재야 해요.
5. VM 의 마운트 계획이 바뀌면 기존 VM 은 다음 턴에 교체돼요. 교체되는 동안 턴이 끊기지 않는지는
   microvm_memory 를 바꿔 교체해 본 시험(턴 경계에서 교체, 턴 도중 실패 없음)과 같은 경로라서 같을 것으로 보지만
   이 변경으로는 아직 해 보지 않았어요.

## 7. 검증 계획

- `Exec_ssh_protocol`: 프레임을 파일로 쓰고 읽어도 stdin 으로 읽은 것과 같은 요청이 나오는 왕복 테스트.
- shim: `--request-file` 로 받은 요청이 실행되고, 읽은 파일이 지워지고, 파일이 없거나 길이가 맞지 않으면
  `remote_ssh_transport_error` 로 끝나는 테스트.
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
