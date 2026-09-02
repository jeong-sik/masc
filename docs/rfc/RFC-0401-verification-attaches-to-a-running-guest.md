---
rfc: "0401"
status: Draft
---

# RFC-0401 — 검증자는 떠 있는 게스트에 붙는다

- Status: Draft
- Decision driver: 검증 조회가 microvm keeper 의 작업 트리를 하나도 못 읽는다.
  거절문은 "게스트를 아는 건 그 턴의 sandbox factory 뿐" 이라고 말하는데, 사실이
  아니다. 게스트 이름은 `(keeper 이름, base_path)` 만으로 나오는 값이고, 게스트는
  턴이 아니라 keeper 수명이라 서버 재기동도 넘겨 산다. 지금 fleet 의 keeper 9개가
  전부 microvm 이라, RFC-0361 이 검증자에게 준 조회 도구가 producer 0명에게
  닿는다.
- Area: `lib/keeper/keeper_sandbox_read_backend.ml`,
  `lib/keeper/keeper_sandbox_remote_lane.ml`,
  `lib/keeper/keeper_turn_sandbox_runtime.ml`,
  `lib/verification_authority_tools.ml`
- Related: RFC-0361(검증 권한의 조회), RFC-0400(게스트가 자기 트리를 소유),
  #31340(턴을 넘겨 게스트를 물려받기)

## 문제

`keeper_sandbox_read_backend.ml:219` 이 microvm keeper 의 읽기를 거절한다.

```ocaml
| No_factory ->
  (match meta.sandbox_profile with
   | Micro_vm ->
     Error
       "microvm_read_requires_turn_sandbox_factory: the guest is known only \
        to the turn's sandbox factory, and this call has none"
```

이 문장이 사실이 아니다. 네 가지가 반대를 말한다.

| 근거 | 자리 |
|---|---|
| 게스트 이름은 `(keeper 이름, base_path)` 의 순수 함수 | `keeper_turn_sandbox_runtime.ml:1317` `microvm_container_name` |
| 게스트는 keeper 수명 — 턴과 서버 재기동을 넘겨 산다 | 같은 파일 `let microvm_container_name` 위 주석, `keeper_sandbox_runtime_setup.ml:204` |
| 게스트를 endpoint 로 바꾸는 함수는 .mli 가 `Pure` 라고 못박음 | `keeper_turn_sandbox_runtime.mli:39` `microvm_remote_endpoint_of_running` |
| 그 함수가 받는 `t` 를 만드는 `create` 도 순수 — 경로 계산과 `getuid` 뿐 | `keeper_turn_sandbox_runtime.ml:159` |

지금 이 자리에서 확인할 수 있다.

```
$ python3 -c "import hashlib;print(hashlib.md5(b'/Users/dancer/me').hexdigest()[:8])"
faea17a4

$ container list --format json | ...
running  masc-keeper-vm-polisher-faea17a4
running  masc-keeper-vm-pr-updater-faea17a4
running  masc-keeper-vm-edgar.a.poe-faea17a4
```

떠 있는 게스트 이름이 `masc-keeper-vm-<keeper>-<md5(base_path) 앞 8자>` 그대로다.
검증자가 가진 것만으로 이름이 나온다. 못 닿는 게 아니라 닿는 길을 안 쓰고 있다.

factory 가 진짜 하는 일은 부팅, `(in_playground, network_mode)` 별 메모, 턴 동안
프로필 계약 고정, 그리고 정리다. 넷 다 쓰기와 실행의 일이다. 읽기는 하나도 안
쓴다.

## 측정 (2026-09-02, `~/me/.masc/verification-runs.jsonl`)

프로필 이전 전 기록이 섞여 있어 오늘 것만 센다. 어제까지의 `docker_*` ·
`remote_ssh_read_failed` 는 그때 프로필의 실패고 지금은 안 난다.

| | |
|---|---|
| 끝난 검증 run | 16 |
| 도구 호출 | 117 — 실패 85 (73%) |
| 그중 이 거절 | 59 — 실패의 69%, 전체 호출의 50% |
| 걸린 도구 | `tool_read_file` 39 · `tool_search_files` 20 |
| 이 거절을 만난 run | 16 중 11 — 거절 9 · 승인 2 · 취소 1 |
| 도구 절반 이상이 실패한 채 끝난 run | 16 중 13 |

`~/me/.masc/config/keepers/*.toml` 9개 전부 `sandbox_profile = "microvm"`.
producer 로 설 수 있는 keeper 중 트리를 열어볼 수 있는 대상이 없다.

승인 2건이 특히 문제다. 검증 프롬프트
(`config/prompts/verification.lookup.producer_tree.md`)는 이렇게 적어놨다.

> 확인 가능한 주장을 확인하지 않고 승인하면 그것은 제출자가 아니라 당신의
> 누락입니다.

지시는 옳은데 그 확인을 할 방법이 없다. RFC-0361 이 고친 것과 같은 모양이 한 층
아래에서 다시 났다. 그때는 도구가 없었고, 지금은 도구가 트리에 못 닿는다.

## 설계

읽기 전용 **붙기(attach)** 경로를 만든다. 떠 있는 게스트에 붙고, 게스트를 띄우지는
않는다.

### D1. 붙되 띄우지 않는다

`Keeper_turn_sandbox_runtime` 에 함수 하나를 낸다.

```ocaml
val microvm_attached_endpoint :
  ?timeout_sec:float ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  unit ->
  (Keeper_sandbox_remote.t, string) result
(** 떠 있는 게스트를 endpoint 로 준다. 턴이 필요 없다: 이름은 keeper 와
    base_path 의 함수이고, 게스트는 keeper 수명이다. 게스트가 안 떠 있으면
    거절한다 — 이 경로는 게스트를 띄우지 않으며, 그래서 keeper 를 소유하지
    않은 호출자에게 열어도 된다. Micro_vm 전용. *)
```

구현은 이미 있는 조각을 잇는 것뿐이다.

```ocaml
let microvm_attached_endpoint ?timeout_sec ~config ~meta () =
  let t = create ~config ~meta () in
  if not (is_microvm t)
  then Error (non_microvm_message meta)
  else
    let container_name = microvm_container_name ~config ~keeper_name:meta.name in
    match inspect_container_running ?timeout_sec ~microvm:true container_name with
    | Error detail -> Error (guest_not_running_message ~meta ~container_name ~detail)
    | Ok () -> microvm_remote_endpoint_of_running t ~container_name
```

`ensure_started` 를 안 부르는 것이 이 설계의 전부다. 부팅은 460MB 짜리 VM 을
올리고, 신원 스냅샷을 쓰고, 작업 루트를 만들고, gitconfig 를 새로 넣는다. 판정자가
할 일이 아니다.

같은 이유로 `microvm_remote_endpoint` 가 하는 작업 루트 보정
(`ensure_microvm_keeper_work_root`)도 안 한다. 루트가 없으면 읽기가 경로 오류로
실패하는데, 그게 맞다. 없는 것을 만드는 건 쓰기다.

### D2. 거절문은 쓰기에서 그대로 남는다

`Keeper_sandbox_remote_lane.endpoint` 는 안 건드린다. Write 와 Edit 은
`keeper_tool_filesystem_remote_write.ml:226` 에서 그 함수를 계속 부르고, 턴 없이는
계속 거절된다. 이 거절은 맞다 — 꺼진 게스트에 쓰려면 띄워야 하고, 띄우는 건 턴의
권한이다.

읽기는 붙고 쓰기는 못 붙는 비대칭이 두 함수의 이름으로 갈린다. 플래그로 가르지
않는다.

### D3. `No_factory` 를 넓히는 게 아니라 거짓 음성을 고치는 것

바뀌는 arm 은 하나다.

```
Endpoint_owned · No_factory · Micro_vm · 읽기
  전 : Error "guest is known only to the turn's factory"   ← 거짓
  후 : Ok Attached_guest
```

`No_factory` 는 "나는 게스트 수명 권한이 없다" 는 뜻이고, 붙기는 그 권한을 하나도
안 쓴다. 그래서 이건 정책을 넓히는 게 아니라 닿는 것을 못 닿는다고 말하던 답을
고치는 것이다. `Remote_ssh` 는 이미 `No_factory` 에서 `Ok Remote_dispatch` 로
간다 — microvm 만 예외였다.

`read_dispatch` 에 `Attached_guest` 를 더하고, runner 는 endpoint 를 얻는 방법만
바꿔 끼운다. 경로 변환과 종료 상태 처리는 지금 것을 그대로 쓴다.

```ocaml
type read_dispatch =
  | Turn_runtime of Keeper_sandbox_factory.runtime_binding
  | Remote_dispatch
  | Attached_guest   (* 새로 *)
  | Docker_fallback
```

### D4. 남는 거절은 참인 것

게스트가 안 떠 있을 때:

```
microvm_guest_not_running: keeper <name> 의 게스트 <container> 가 떠 있지 않다.
읽기는 떠 있는 게스트에 붙을 뿐 띄우지 않는다.
```

지금 거절문처럼 원인을 다른 축으로 보내지 않는다.
(`remote_github_identity_missing` 이 자격증명 문제로 읽히는 것과 같은 함정.)

### 동시성

`Keeper_sandbox_remote` 의 세션 반환은 `(base_path, container_name,
max_concurrent_sessions)` 로 잡히는 프로세스 전역 표다
(`keeper_sandbox_remote.ml:70`). 검증자가 만든 endpoint 는 producer 턴이 쓰는
것과 **같은** semaphore 를 쓴다. 상한은 8. 별도 조정이 필요 없다.

producer 가 쓰는 중인 트리를 검증자가 읽는 일관성 문제는 남는다. 다만 지금은
아예 못 읽으므로 나빠지는 게 아니다. 살아 있는 producer 를 검증한다는 것의 성질로
적어둔다.

## 왜 검증 레인에 factory 를 주지 않는가

가장 먼저 떠오르는 답은 "검증 레인도 factory 를 하나 만들어 갖게 하자" 다. 셋 다
틀린다.

1. 읽기 한 번이 VM 부팅(1.3~2.4초, 460MB)을 부작용으로 산다.
2. 부팅은 쓴다 — 신원 스냅샷, 작업 루트 `mkdir`, gitconfig 갱신. 판정자가
   producer 의 세상을 바꾸면 그 판정은 자기가 만든 것을 보는 게 된다.
3. factory 는 정리 권한과 network mode 선택권을 같이 들고 있다. 판정자가 가질
   권한이 아니다.

붙기는 이걸 뒤집는다. **검증자는 있는 게스트를 볼 수 있고, 게스트를 있게 만들 수는
없다.** 판정자가 가져야 할 권한이 정확히 이 모양이다.

## 검증

| 확인할 것 | 방법 |
|---|---|
| 떠 있는 게스트에 붙어 읽힌다 | 새 테스트: microvm meta + 떠 있는 게스트 → `tool_read_file` 성공 |
| 꺼진 게스트는 거절, 그리고 **안 띄운다** | 게스트 down 상태에서 읽기 → `microvm_guest_not_running`, 이후 `container list` 에 새 게스트 없음 |
| 조용한 host 대체가 없다 | `test_keeper_sandbox_read_backend.ml:402` 의 뜻을 유지 — 게스트가 없을 때 host/docker 로 새지 않는지 |
| 쓰기는 여전히 거절 | 턴 없이 `handle_write` → `microvm_remote_requires_turn_sandbox_factory` |
| 라이브 | 배포 후 하루치 `verification-runs.jsonl` 에서 이 거절 0건, 도구 실패율 73% → ? |

세 번째가 중요하다. 지금 테스트 이름은 `refuses_microvm_without_a_turn_factory`
지만, 실제로 지키는 건 "조용히 대체하지 않는다" 다. 붙기는 대체가 아니라 진짜
게스트에 닿는 것이므로 그 뜻은 살아 있다. 테스트는 새 문구에 맞춰 고치되, 대체
금지 주장은 그대로 둔다.

## 범위 밖

- **`?turn_sandbox_factory : t option` 의 모호함.** `None` 이 "턴이 없다" 와
  "여기까지 배선을 안 했다" 두 가지를 뜻한다. 279곳이 이 이름을 쓴다. 지금
  비-테스트 호출자 중 `None` 을 넘기는 건 `verification_authority_tools.ml`
  하나뿐이라 당장 위험하지는 않다. 합타입으로 가르는 건 따로 낸다.
- **검증자가 조회 불능일 때의 판정.** 붙기가 들어가면 오늘 승인 2건의 눈가림은
  사라진다. 그래도 "조회가 전부 죽었을 때 무엇을 할지" 는 프롬프트에 아직 없다.
  별건.
- `verification_authority_tools.ml:279` 주석이 Docker 를 못 읽는다고 적어놨는데
  Docker 는 `Docker_fallback` 으로 읽힌다. 같은 PR 에서 문장만 고친다.
