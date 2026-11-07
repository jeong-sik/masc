---
rfc: "lane-addon-shutdown-detaches-native-instances"
title: "서버가 멈출 때 자기 native Lane instance 를 Detach 하고 나간다"
status: Draft
created: 2026-11-06
updated: 2026-11-06
author: claude
supersedes: []
superseded_by: null
related: ["browser-backends-end-alone", "0497"]
---

# RFC — 서버가 멈출 때 자기 native Lane instance 를 Detach 하고 나간다

## 1. 문제

2026-11-06 17:52 KST 배포 뒤 약 20분 동안 브라우저 Add-on 이 붙지 않았어요.
`kidsnote-slack-reader` 의 브라우저 호출 5건이 08:58:37~09:01:44Z 에 `no browser Add-on is attached` 로 실패했어요.
2026-10-22 에도 같은 일이 있었어요(#45106).

두 번 모두 같은 순서로 막혔어요.

1. 옛 서버가 SIGTERM 으로 멈출 때 native instance(browser-ego, browser-external)를 정리하지 않고 나가요. binding 은 `attached` 로 남아요.
2. 새 서버가 그 binding 을 정리하려면 옛 바이너리가 claim 슬롯에 쓴 정리 정보(cleanup descriptor)를 읽어야 해요.
3. 그 사이에 정리 정보의 모양이 바뀌었어요. 10-22 에는 키가 늘었어요. 11-06 에는 `models` 키가 빠졌고, 배포 안내(#49077 Fresh state)를 따라 슬롯을 지웠어요.
4. 정리가 `Failed{cleanup_unconfirmed}` 에 멈춰요. 켜진 선언은 지난 기록이 `Detached` 가 아니면 새 instance 를 띄우지 않아요.
5. 운영자가 서버를 멈추고 binding 파일을 지운 뒤에야 풀렸어요.

## 2. 확인한 사실

좌표는 main `eb8e41e0d9a` 기준이에요.

**종료 순서**
- `bin/main_eio.ml` 의 종료는 4단계예요. NOTIFY → HOOKS(`Shutdown_hooks.run_all`, 3초, 951행) → BOARD(2초, 972행) → CANCEL(997행).
- 전체는 `force_timeout_s`(10초) watchdog 이 끝내요. 넘기면 exit 124 로 나가요.
- Lane Add-on 은 어느 단계에도 없어요. CANCEL 에서 서버 switch 가 취소될 때 worker 가 같이 끝나요. binding 은 `attached` 로 남아요.
- 11-06 종료 4번 중 3번은 HOOKS 에서 Keeper 정지가 2.0~6.6초 걸렸어요. 세 번 모두 CANCEL 에 닿을 때 전체 시간이 2.2~6.8초였어요(system_log `[Shutdown]` 줄). 09:10:57Z 종료는 HOOKS 시작 뒤 로그가 없어요.
- 11-05 종료 7번은 CANCEL 에서 `Shutdown complete` 까지 3~6초 걸렸어요. 두 값은 날이 달라 같은 종료의 값은 아니에요. 더하면 5.2~12.8초예요. BOARD 뒤에는 10초 안에 기다림을 더할 자리가 없어요.

**선언이 지난 기록을 다루는 방식**
- `reconcile_configuration`(`lib/lane_addon/lane_addon_runtime.ml:4035`)은 켜진 선언에 살아 있는 entry 가 없을 때 지난 기록을 봐요.
- `Detached` 가 아닌 기록이 있으면 `retire_past`(4103행, `historical_detach`)만 해요. 모두 `Detached` 면 `attach_entry`(4356행)로 새 instance 를 붙여요.

**native 정리**
- `historical_detach`(2754행)는 native 기록에 `native_recover`(1514행)를 써요. 슬롯의 lease 를 다시 열고 정리 정보를 해독해 할당을 치워요.
- 정리 정보는 정확한 키 집합만 받아요(`lib/browser_addon_socket.ml:66` `cleanup_descriptor_keys`).
- `Native_addon_lease` 계약(`lib/native_addon_lease/native_addon_lease.mli`)은 세 가지를 정해요.
  - lease inode 는 지우거나 바꾸지 않아요(4행).
  - `Settled` 는 lease holder 가 없고 원래 프로세스와 foreground group 이 끝났을 때만이에요(60행).
  - 숫자 pid 로 대신 판정하지 않아요(65행).
- 운영자 탈출구 `Retain`(`retain_unconfirmed` 2855행)도 같은 슬롯을 다시 열어요(`native_retain` 1524행). 슬롯이 없으면 거절돼요.

**살아 있는 entry 의 Detach**
- API `Detach` 는 `detach_entry`(3236행) 뒤 `await_settled`(782행)로 끝을 기다려요(3998행). 정리 정보는 그 entry 를 띄운 바이너리가 읽어요.
- 정리가 끝나면 `release_detached`(794행)가 `m.configuration_nudge ()` 로 reconcile 을 깨워요.
- ego 연결은 transport 를 내릴 때 task space 를 `finish` 하지 않아요.
  - `lib/browser_ego_peer.mli:284`: "Never call on transport retirement".
  - `lib/browser_addon_live_ego.ml:78`: owner 를 잃으면 Node 세션만 끝내요.
  - 그래서 Detach 해도 Keeper 가 연 ego 탭은 남아요.

**지금 붙어 있는 것**
- 11-06 20:5x KST 에 붙어 있는 instance 는 8개예요. native(`Host_process`)는 browser-ego 하나예요.
- 나머지 7개는 container 예요. container 는 다음 서버가 label 로 찾아 치워요(4107행 주석). 정리 정보를 읽지 않아요.

## 3. 결정

서버가 SIGTERM·SIGINT 로 멈출 때 HOOKS 단계에서 LANE 을 같이 돌려요. `Shutdown_hooks.run_all` 과 LANE 은 서로 다른 fiber 에서 돌아요. 둘 다 같은 `cleanup_timeout_s`(3초) 안에서 끝나요.

1. 이 서버의 Lane Add-on 설정 서비스를 멈춰요. 그 뒤로는 reconcile 이 돌지 않아요. `release_detached` 의 nudge 도 아무것도 띄우지 않아요.
2. 설정 잠금을 잡고 entry 를 골라요. 고르는 기준은 `package.execution = Host_process _` 이고 `Detached` 가 아닌 것이에요. 고른 entry 마다 `detach_entry` 를 불러요.
3. 고른 entry 의 `await_settled` 를 병렬로 기다려요. 잠금은 모두 끝날 때까지 쥐어요. API `Detach` 도 그렇게 해요. 기다리는 사이에 Attach 가 끼면 이번에 Detach 하지 않는 instance 가 생겨요.
4. instance 마다 정리 결과(`Detached`, 또는 `Failed` 와 그 원인)와 걸린 시간을 로그에 남겨요. `Detaching` 기록을 못 쓴 것은 따로 남겨요.

새 상한은 두지 않고 HOOKS 의 상한을 같이 써요. BOARD 다음에 두지 않는 이유는 2절의 시간이에요. CANCEL 뒤에도 3~6초가 더 걸려요. BOARD 뒤에서 기다리면 10초 watchdog 이 exit 124 로 끝낼 수 있고, 그러면 마지막 종료 줄이 남지 않아요. HOOKS 와 같이 돌리면 전체 종료 시간이 늘지 않아요.

상한에 걸린 instance 는 `Detaching` 이나 `attached` 로 남아요. 다음 서버가 지금처럼 lease 로 정리해요. 지금보다 나빠지지 않아요.

선언 파일은 지우지 않아요. 원하는 상태는 선언의 `enabled` 가 정해요. `Detached` 는 그 instance 가 자원을 돌려줬다는 사실만 뜻해요. 다음 서버는 지난 기록이 모두 `Detached` 라서 바로 새 instance 를 붙여요.

그러면 정상 종료 뒤의 배포에서 binding 은 다른 바이너리가 쓴 정리 정보를 기다리지 않아요. claim 슬롯은 그대로 남아요. lease inode 를 지우지 않는 계약 때문이에요. 새 instance 를 붙일 때 `prepare_native`(1540행)가 남은 슬롯을 다시 열고 그 정리 정보를 읽어요.

그래서 정리 정보 모양을 바꾸는 hard cut 의 Fresh state 는 "서버를 멈추고, claim 슬롯을 지우고, 설치한다" 예요. 이 RFC 전에는 슬롯을 지우면 그 슬롯을 가리키는 `attached` binding 이 정리에 멈췄어요(11-06). 이제는 그런 binding 이 없어서 슬롯을 지워도 돼요. 모양이 그대로면 아무것도 지우지 않아요.

이 동작은 이 RFC 를 넣은 바이너리가 멈출 때부터예요. 그 바이너리를 처음 배포할 때의 종료는 옛 바이너리가 하므로 지금과 같아요.

container 는 고르지 않아요. 정리 권한이 engine label 이라 바이너리가 바뀌어도 읽을 수 있어요. 7개를 멈추는 시간이 3초 상한 안에 들어간다는 측정도 없어요.

## 4. 버린 방법

| 방법 | 버린 이유 |
|---|---|
| 새 바이너리가 옛 정리 정보를 읽는 호환 reader | `legacy_residue` 금지. 모양이 바뀔 때마다 reader 가 늘어요 |
| lease 대신 pid·시작 시각으로 끝났다고 판정 | lease 계약이 막아요. group 을 떠난 자식이 lease fd 를 쥐고 있으면 놓쳐요 |
| 슬롯이 없을 때 `Retain` 이 그냥 넘겨받기 | 보지 못한 것은 추정하지 않는다는 `Retain` 규칙을 어겨요. 옛 프로세스가 살아 있으면 새 instance 와 겹쳐요 |
| hard cut 절차만 문서로 고정 | 10-22·11-06 두 번 빠뜨렸어요 |
| container 까지 모두 Detach | 정리 정보 문제와 관계없어요. 종료 시간이 10초를 넘길 수 있어요 |
| BOARD 다음, CANCEL 전에 LANE 단계를 따로 두기 | CANCEL 뒤에도 3~6초가 남아야 해요. 기다림이 길면 watchdog 이 exit 124 로 끝내요(2절) |

## 5. 비슷한 제품

- **Crash-only software**(Candea·Fox, HotOS IX 2003)는 "stop=crash, start=recover" 로 정의해요.
  - 지금 masc 의 native instance 처리가 이 방식이에요.
  - 장점: 복구 코드가 시작할 때마다 돌아서 늘 검증돼요.
  - masc 에서 드러난 한계: 배포 때는 복구하는 바이너리와 기록을 쓴 바이너리가 달라요. 11-06 사고가 그 틈에서 났어요.
  - https://www.usenix.org/legacy/events/hotos03/tech/full_papers/candea/candea_html/
- **Kubernetes Pod 종료**는 kubelet 이 `preStop` hook 을 돌린 뒤 TERM 을 보내요.
  - 기본 `terminationGracePeriodSeconds` 는 30초예요. 지나면 남은 프로세스에 SIGKILL 을 보내요.
  - 정상 종료에서 자기 정리를 먼저 하고, 시간이 다하면 강제로 끝내요.
  - 단점: 정리가 grace 를 넘기면 정리하지 못한 채 끝나요. 그 경우는 따로 복구해야 해요.
  - https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-termination

이 RFC 는 둘을 섞어요. 정상 종료에서는 자기 정리를 해요(Kubernetes 방식). 크래시나 watchdog 종료 뒤에는 지금의 복구를 그대로 써요(crash-only 방식).

## 6. 구현 순서

- **L1** 이 RFC.
- **L2** 종료 단계와 시험.
  - `Lane_addon_runtime.detach_native_for_shutdown ~config` 와 mli: 3절 1~4.
  - `Shutdown_hooks` 에 Lane 자리(`register_lane_addon_shutdown`, `run_lane_addon_shutdown`).
  - `lib/server/server_bootstrap_maintenance.ml` 에서 설정 서비스를 띄운 뒤 등록해요.
  - `bin/main_eio.ml` 2단계에서 `run_all` 과 LANE 을 `Eio.Fiber.both` 로 같이 돌려요. 단계 번호(1/4~4/4)는 그대로예요.
  - stdio 서버(`bin/main_stdio_eio.ml`)에는 연결하지 않아요(8절).
  - 시험(`test/test_lane_addon_native_runtime.ml`)은 11-06 순서를 그대로 밟아요.
    1. 선언으로 native fixture 를 붙여요.
    2. 종료 단계를 불러요.
    3. 슬롯을 지워요.
    4. `For_testing.reset` 뒤 reconcile 해요.
    5. 새 instance 가 붙어요.
  - changelog.

## 7. 확인 방법

- 시험은 6절 L2 예요.
- 배포 뒤에는 이 바이너리가 도는 서버를 한 번 더 재시작해서 세 가지를 봐요.
  - `[Shutdown]` LANE 줄에 browser-ego 의 `Detached` 와 걸린 시간이 나와요.
  - 새 서버 로그에 그 instance 의 `cleanup was not confirmed` 가 없어요.
  - 새 browser-ego 가 붙어요.
- LANE 시간을 재요. `[Shutdown] Phase 2/4 LANE: done (x.xxs)` 와 instance 마다의 `detached (x.xxs)` 를 봐요. 3초 상한에 걸리면 `LANE: timeout` 줄이 나와요. 그때는 오래 걸린 instance 와 원인을 보고 다음 RFC 로 올려요.

## 8. 범위 밖

- 크래시나 watchdog 종료 뒤에 판이 바뀌는 배포는 지금 복구를 그대로 써요. 그때의 Fresh state 는 `browser-backends-end-alone` §7 처럼 binding 까지 적어야 해요.
- container instance 의 종료 처리.
- Keeper 정지가 HOOKS 3초를 넘기는 문제(11-06 08:52Z 6.61초).
- stdio 서버(`bin/main_stdio_eio.ml`)의 종료. 이 서버에는 프로세스 watchdog 이 없어요. 기다림에 끝이 없어서 연결하지 않아요.
- API `Detach` 의 경쟁 조건(#49359). 정리 fiber 가 `Failed` 를 쓰고 끝나기 전에 `detach_entry` 가 `Detaching` 으로 덮을 수 있어요. 그러면 `stop_entry`(832행)는 아무것도 하지 않고 `await_settled` 는 끝나지 않아요. 원래 있던 문제예요. 종료에서는 3초 상한이 끊어요.
