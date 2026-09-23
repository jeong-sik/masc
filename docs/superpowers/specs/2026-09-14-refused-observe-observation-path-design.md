# Refused-observe 관측 경로 설계 — task-1568 (#36032 후속)

## 배경

PR #36032 3차 리뷰(review 5192723206, jeong-sik, 23:26:52Z)의 결론:

> 단축을 정당화하려면 'A' ack 이후의 시도를 관찰해야 한다. 그 경로가 생기기
> 전까지 main처럼 Observed_refused을 항상 판정자로. 단축은 관찰 경로와 같이
> 따로 가는 게 어떨까.

PR #36032는 이 결론대로 단축을 완전히 제거했다(c35986f7, dfed5b7d, 20e2d66d) —
`Keeper_gate.decide_after_observation`은 `refusal_kind`·`network_mode` 조합과
무관하게 모든 `Observed_refused`를 판정자에게 보낸다(main HEAD 기준 현재도
동일). 이 문서는 그 뒤에 필요한 "관찰 경로"를 설계한다.

## 왜 "A ack 이후 시도"가 지금 안 보이는가

`masc-exec-shim`의 박스(RFC-0422)는 child가 `Unix.execvpe` 직전에
`ocaml_shim_restrict_self`로 Landlock(파일쓰기)·seccomp(소켓)를 설치한다
(`exec_shim.ml:449-505`, `observe_stub.c`). 설치가 끝나면 child는 부모에게
"A"(Sandbox_applied)를 boundary 파이프로 ack하고 그 즉시 exec한다.

`deny_sockets()`의 현재 seccomp 필터(`observe_stub.c`)는:

```c
{ BPF_JMP_JEQ_K, 0, 1, (uint32_t) SYS_socket },
{ BPF_RET_K, 0, 0, SECCOMP_RET_ERRNO | (EPERM & 0xffff) },
```

`socket(2)`를 커널이 필터 안에서 즉시 EPERM으로 되돌린다 — payload 프로세스
자신은 그 실패를 볼 수 있지만(errno=EPERM), **shim(부모)은 그 순간을 전혀
관측하지 못한다.** shim이 아는 건 오직 두 가지뿐이다: (1) "A" ack — 필터가
설치됐다, (2) payload의 최종 exit code — 대개 라이브러리가 EPERM을 잡고
다른 코드로 종료하므로 "소켓을 시도했다가 막혔다"와 "애초에 소켓을 안 썼다"를
구별할 신호가 exit code에 없다. 이게 review 5192723206이 지적한 정확한 갭:
설정 성공(ack)과 시도 차단(attempt-blocked)은 서로 다른 사실인데, 현재 shim은
후자를 볼 방법이 아예 없다.

## 후보 비교

### (a) SECCOMP_RET_USER_NOTIF (권장)

seccomp 필터의 `socket(2)` 분기를 `SECCOMP_RET_ERRNO`에서
`SECCOMP_RET_USER_NOTIF`로 바꾸면, 커널은 그 syscall을 즉시 처리하는 대신
필터 설치 시점에 `SECCOMP_FILTER_FLAG_NEW_LISTENER`로 받은 "listener fd"에
알림을 큐잉하고 payload 스레드를 블록한다. 그 fd를 쥔 프로세스(=listener)가
`ioctl(fd, SECCOMP_IOCTL_NOTIF_RECV, &req)`로 시도(`req.data.nr`,
`req.data.args[]` — 소켓 family/type/protocol 포함)를 읽고,
`ioctl(fd, SECCOMP_IOCTL_NOTIF_SEND, &resp)`로 응답(`resp.error = EPERM`)해야
payload가 풀려난다.

장점:
- **동기적**: 응답 전까지 payload가 블록되므로 "시도했다"는 사실이 관측
  시점과 정확히 일치한다 — audit처럼 나중에 로그를 뒤질 필요가 없다.
- **shim이 이미 소유한 권한만 필요** — root나 `CAP_AUDIT_CONTROL` 불필요.
  listener fd를 쥔 프로세스는 필터를 설치한 스레드(또는 그 fd를 넘겨받은
  프로세스)일 뿐이다.
- **기존 구조와 자연스럽게 이어진다** — shim은 이미 `Unix.select` 기반
  단일 스레드 supervision 루프로 child의 stdout/stderr/boundary 3개 파이프를
  드레인한다(`exec_shim.ml` 하단 "Every instant in this loop..." 절). notify
  fd를 네 번째 감시 대상으로 추가하는 모양이 된다.
- 외부 동작(payload가 보는 결과)을 안 바꾼다 — 여전히 EPERM으로 응답하면
  된다. 이 문서가 제안하는 변화는 순수하게 **관측**이지 **정책**이 아니다.

한계:
- **fd 전달이 필요하다.** listener fd는 `seccomp(2)`를 호출한 스레드가
  받는다 — 그 호출은 child가 exec 직전에 하므로(`restrict_self`), fd는
  child 안에 생긴다. 부모(shim)가 그 fd로 poll하려면 child→parent로 fd를
  건네야 하는데, 현재 boundary 파이프는 평범한 `Unix.pipe`라 fd 자체는
  못 건넨다(바이트만 건넨다) — `sendmsg(2)`의 `SCM_RIGHTS` ancillary data로
  유닉스 도메인 소켓을 통해서만 fd를 옮길 수 있다. OCaml stdlib `Unix`
  모듈은 `SCM_RIGHTS`를 노출하지 않으므로 **새 C 스텁**이 필요하다
  (`sendmsg`/`recvmsg` 래퍼). boundary 파이프를 `Unix.socketpair`로 바꾸거나
  별도 소켓을 하나 더 여는 두 갈래 중 하나를 골라야 한다.
- **응답 지연이 곧 payload 지연**이다 — supervisor 루프가 다른 파이프
  드레인에 매여 있는 동안 notify 응답이 늦으면 payload의 소켓 시도 자체가
  그만큼 느려진다(타임아웃까지는 아니지만). 지금의 단일스레드 select 루프
  주기 안에서 처리 가능한 수준이라고 보지만, 실측은 phase 2에서 필요하다.
- **커널 버전 하한**: `SECCOMP_FILTER_FLAG_NEW_LISTENER`는 Linux 5.0+
  (2019). 이 문서를 쓰는 이 샌드박스는 Linux 6.18 aarch64로 문제없지만,
  구형 커널에서는 `false`로 떨어져야 한다 — 그래서 이 PR은 그 자체를 probe
  하는 함수부터 만든다(아래).

### (b) audit 로그 구독

`auditctl`로 `socket` syscall에 규칙을 걸고 `/var/log/audit/audit.log`(또는
netlink `AUDIT` 소켓)를 구독해 나중에(또는 별도 스레드에서) 매칭한다.

장점: 커널 seccomp 필터를 안 바꿔도 된다 — 기존 `SECCOMP_RET_ERRNO` 그대로
두고 곁다리로 관측만 붙일 수 있다.

한계(review 원문의 "audit 로그 구독, 비동기, 정합성 약함"과 일치):
- **비동기·비정합**: audit 이벤트는 커널 auditd 큐를 거쳐 늦게(수 ms~수백ms)
  도착할 수 있고, 여러 child가 동시에 실행 중이면 이벤트를 pid로 되짚어야
  하는데 pid 재사용 경합이 생긴다. "이 특정 요청의 이 특정 시도"라는 1:1
  대응을 audit만으로 강하게 보장하기 어렵다.
- **권한**: `CAP_AUDIT_CONTROL`(규칙 설치) + `CAP_AUDIT_READ`(로그 구독)가
  필요하다 — shim은 지금 그런 권한을 요구하지 않고, microVM/Docker 게스트
  마다 auditd가 아예 없거나 죽어 있을 수 있다(이 워크스페이스의 여러 keeper
  microVM이 이미 "sandbox VM microvm_vm_not_running"류 실패를 겪는다).
- **shim이 단일 프로세스인데 auditd는 시스템 전역** — 같은 호스트에서 여러
  shim 인스턴스(여러 keeper)가 동시에 뜨면 규칙·구독을 전역 자원으로 공유해야
  하고 조율 비용이 든다. user_notif는 프로세스별로 자연히 격리된다.

### 결론

**(a) SECCOMP_RET_USER_NOTIF를 선택한다.** 동기성·권한 최소성·기존 구조와의
정합성이 audit보다 명백히 낫고, review가 언급한 두 후보 중 "정합성 약함"이라고
스스로 약점을 적어둔 쪽이 audit이다. 유일한 진짜 비용은 fd-passing 스텁을
새로 써야 한다는 것 — 그 자체가 RFC-0422 박스 경계를 건드리는 별도의 검토
단위이므로 phase를 나눈다.

## 이 PR(task-1568)의 스코프 — Phase 1만

`decide_after_observation`의 판정 로직은 **하나도 바꾸지 않는다**
(task-1568 completion_contract ①: "판정자 없이 Allow를 내는 분기가
re-introduce되지 않는다"). 이 PR이 하는 일은 오직:

1. `Exec_shim.user_notif_supported : unit -> bool` — 커널이
   `SECCOMP_FILTER_FLAG_NEW_LISTENER`를 받아들이는지 probe. 부수효과 없음:
   fork한 자식 안에서만 allow-all 리스너 필터 설치를 시도하고 즉시 종료하므로
   호출 스레드 자신의 seccomp 상태는 건드리지 않는다(필터는 한번 걸면 제약만
   늘릴 수 있어 in-process로는 부수효과 없이 probe할 방법이 없다).
2. 이 probe는 **어디에도 아직 연결되지 않는다** — `probe()`의
   `capabilities` 목록에도, `decide_after_observation`에도 안 들어간다.
   과거 이 PR 계보에서 두 번(review 5192723206, 5195604213) "안 쓰이는
   분기/필드는 dead code"라는 지적을 받았으므로, 이번엔 소비자 없는 표면을
   와이어에 노출하지 않는다.
3. 회귀 테스트(`test_keeper_gate_effect_coverage.ml`): probe를 같은
   프로세스 안에서 호출한 *직후* `Observed_refused`를 판정자에게 defer하는
   기존 불변이 안 깨졌는지 고정한다 — probe 함수가 존재한다는 사실만으로
   미래의 누군가 실수로 gate 분기를 새로 연결하지 못하게 하는 핀.

## Phase 2(별도 PR, 이 문서 밖)

- boundary 파이프를 fd-passing 가능한 채널(소켓 + `SCM_RIGHTS` C 스텁)로
  교체하거나 병행 채널을 추가.
- `deny_sockets()`가 `deny_net` 플래그가 "관찰 모드"로 켜졌을 때만
  `SECCOMP_RET_USER_NOTIF`로 소켓 분기를 바꾸도록 옵션화(기존 `Run_boxed`의
  `deny_net`과는 별도 축 — 관찰 여부는 정책이 아니라 증거 수집 여부).
- supervisor 루프에 notify fd 드레인 추가: `SECCOMP_IOCTL_NOTIF_RECV`로
  읽은 시도를 `Exec_ssh_protocol` trailer에 구조화된 필드로 실어 보내고,
  `SECCOMP_IOCTL_NOTIF_SEND`로 EPERM 응답(외부 동작 불변).
- `Keeper_gate`에 "시도 관찰됨" 증거를 담을 새 타입(예:
  `Observed_refused`에 `attempt : attempt_evidence option` 필드 추가)과,
  그 증거(`attempt`)가 소켓 시도를 기록했을 때만 `Network_none`과 묶는 좁은 단축을
  재검토하는 분기. **이 문서의 범위 밖** — review 5192723206의 조건("관찰
  근거가 있을 때만")이 실제로 충족된 뒤에 별도로 제안·리뷰받는다.

## RFC-0422와의 정합성

RFC-0422 §3.3–3.4의 안전 불변("설정 실패는 시도 차단이 아니다",
"Observed_in_box는 소켓 차단 AND scratch 밖 파일쓰기 차단을 함께
요구한다")을 이 문서는 전혀 완화하지 않는다 — user_notif는 *더 많은 증거를
모으는* 수단이지 *판정을 건너뛰는* 수단이 아니다. Phase 2가 실제로 단축을
제안할 때도 Docker profile이 network_mode와 무관하게 항상 host 디렉토리를
bind-mount한다는 사실(ask42331fd44abcec6e에서 이미 확인된 이유로 task-635의
"network_mode만으로 안전 판정" 전제가 무너졌던 것과 같은 함정)을 다시
확인해야 한다 — user_notif가 소켓 시도를 봤다는 것과 파일쓰기가 안전하다는
것은 별개의 사실이다.
