---
rfc: "0497"
title: "자원을 돌려준 Lane instance 는 같은 owner 의 새 instance 가 생기면 기록을 남기지 않는다"
status: Draft
created: 2026-11-06
updated: 2026-11-06
author: claude
supersedes: []
superseded_by: null
related: ["lane-addon-observation-commits-at-the-binding", "dated-stores-take-retention-from-one-list"]
---

# RFC-0497: 자원을 돌려준 Lane instance 는 같은 owner 의 새 instance 가 생기면 기록을 남기지 않는다

- 상태: 초안
- 이슈: #48946
- 근거: §2 의 수치는 2026-11-06 04시(KST) 운영 workspace 에서 쟀다. binding 은 lifecycle·configuration·package 필드의 모양만 읽었고, 관측 기록은 파일 크기만 셌다. 내용은 읽지 않았다. §3 의 코드는 `origin/main` `f2d98655513` 이다.
- 다루지 않는 것: settled 보관본(`tool-request-owners-settled`, 18GB)은 따로 RFC 를 쓴다. 독자와 실패 비용이 다르다(§5).

## 0. 요약

서버를 다시 켜면 Lane Add-on 마다 새 instance 가 생긴다. 이전 instance 는 자원을 돌려주고 `detached` 가 된다. 그런데 binding 파일과 관측 기록은 그대로 남는다. 지우는 코드가 없다.

- binding 은 3,540개다. 그중 3,527개가 자원을 돌려준 `detached` 다.
- 그 instance 들의 관측 기록이 3.4GB 다. 붙어 있는 instance 10개의 관측 기록은 72MB 다.
- maintenance pulse 는 60초마다 binding 3,540개(17MB)를 두 번 읽고 파싱한다.

이 RFC 는 이미 있는 규칙 하나를 넓힌다. 지금도 자원을 돌려준 instance 가 관측을 하나도 커밋하지 않았으면 binding 을 지운다(`leaves_no_record`). 이 RFC 는 관측을 커밋한 instance 도 지운다. 단, 같은 owner 묶음에 같은 값을 가진 대표 binding 이 남아 있어야 한다. 그래서 과거 binding 을 읽는 코드는 지운 뒤에도 같은 답을 얻는다(§4.1).

이 규칙이면 binding 3,540개 중 3,522개(binding·관측·action 3,397MB)를 지우고 18개(85MB)를 남긴다. 남는 수는 서버를 다시 켠 횟수가 아니라 선언과 revision 의 수를 따른다.

## 1. 결정

- D1. 자원을 돌려준 instance 는 같은 owner 의 다른 binding 이 그 대신 같은 답을 줄 수 있으면 지운다. lifecycle 이 `Detached (Never_created | Released | Native_released)` 인 instance 가 대상이다. binding, 관측 기록 폴더, action 폴더를 같이 지운다.
- D2. 아래 instance 는 남긴다(§4.2).
  - 이 프로세스가 쥐고 있거나(`m.entries`) 정리하고 있는(`m.recovering`) instance
  - `Native_retained`, `Detaching`, `Failed`, `Attached`, `Observing` instance
  - owner 가 없는 instance
  - 같은 `(owner id, source_path, revision)` 묶음의 대표 binding
  - 같은 `(owner id, package id)` 의 persistent 묶음의 대표 binding
  - 대표와 visibility 나 runtime 이 다른 binding
- D3. 대표는 묶음에서 instance id 가 가장 큰 binding 이다. instance id 는 UUIDv7 이다(`Random_id.uuid_v7`, 지금 3,540개 모두). 대표가 꼭 가장 새 것일 필요는 없다. 지우는 binding 은 대표와 visibility·runtime 이 같아야 해서, 어느 것이 대표여도 §3.2 의 독자가 같은 답을 얻는다(§4.1). UUIDv7 시각을 읽을 수 없거나 pass 시각보다 미래인 binding 은 대표가 되지 않고 지우지도 않는다.
- D4. 지우기는 `reconcile_configuration` 이 configuration 잠금 안에서 한다. 그 pass 가 이미 읽은 binding 과 그 순간의 liveness 로 정한다.
- D5. 먼저 지울 대상만 세는 층을 내고, 지우는 층은 그 수치를 운영자가 확인한 뒤 낸다(§6).
- D6. content-addressed blob(`evidence/`, `sequences/`)은 이 RFC 에서 지우지 않는다. blob 을 쓰는 곳이 다섯 모듈에 흩어져 있다. 그래서 어떤 blob 을 아무도 가리키지 않는지 알려면 가리키는 쪽을 모두 모은 목록이 먼저 있어야 한다(§5).
- D7. 이전 instance 의 관측은 §4.1 대로 다음 pass(최대 60초)에 사라진다. 같은 revision 묶음의 대표 하나만 남는다. 대시보드 Add-on 화면의 과거 목록도 비고, `masc_lane_slice`·`masc_lane_evidence` 로 이전 run 을 읽을 수 없다. 이전 run 의 관측이 필요하면 그 instance 가 살아 있을 때 `masc_lane_evidence` 로 고정한다. 고정한 묶음은 binding 과 관측을 복사해 들고 있어서 남는다. 운영자가 2026-11-06 에 정했다. 근거: 약 8일 동안 과거 관측을 읽은 직접 호출은 0번이다(§2.3).

## 2. 무슨 일이 났나

### 2.1 binding 상태

| lifecycle | 개수 |
|---|---|
| `detached` / `native_released` | 2,458 |
| `detached` / `released` | 1,069 |
| `detached` / `native_retained` | 3 |
| `attached` | 10 |

- owner(configuration) 가 있는 binding 이 3,539개다. owner 가 없는 것은 1개(`failed`)다.
- owner 는 14개다. owner 하나에 binding 이 가장 많은 경우는 1,313개다.
- 서버 시작 로그는 10-24~11-05 사이에 118개다. Add-on 마다 detached binding 이 약 120개씩 있다. 서버를 다시 켤 때마다 Add-on 마다 하나씩 남는다.

### 2.2 instance 별 폴더

instance id 의 SHA-256 을 이름으로 쓰는 폴더를 binding 상태별로 묶었다.

| 폴더 | 자원을 돌려준 detached | attached | binding 없음 |
|---|---|---|---|
| `observations` | 1,240개, 3,400.7MB | 10개, 71.7MB | 2개, 0MB |
| `actions` | 11개, 0MB | 0 | 5개, 0MB |

`native-claims`, `host-results`, `exact-requests` 는 instance id 로 묶이지 않는다. `exact-requests` 는 일부러 declaration id 로 묶는다. 새 instance 가 이전 instance 의 요청을 찾아야 하기 때문이다(`lane_addon_store.ml` `exact_request_path` 주석). 이 셋은 이 RFC 가 건드리지 않는다.

### 2.3 과거 기록을 누가 읽나

2026-10-29~11-05 도구 호출 원장(`tool_calls`, 조각 파일 62개 전부)에서 Lane 도구의 직접 호출을 셌다. `Execute` 안에서 부른 호출이 이 원장에 따로 남는지는 확인하지 않았다.

- `masc_lane_inspect` 4번
- `masc_lane_slice`, `masc_lane_evidence` 0번

과거 instance 의 관측을 읽는 길은 `masc_lane_slice` 와 `masc_lane_evidence` 뿐이다(§3.2). 약 8일 동안 직접 호출은 0번이다.

## 3. 지금 코드

### 3.1 이미 있는 규칙

`persist` 는 binding 을 쓸 때 `leaves_no_record` 를 묻는다. instance 가 자원을 돌려줬고(`Never_created | Released | Native_released`), 관측을 하나도 커밋하지 않았고(`seq = 0`), 쥔 resource 가 없으면 binding 을 쓰지 않고 지운다(`lane_addon_runtime.ml` 553, 739). 정리 경로도 terminal 기록이 없으면 `remove_binding` 을 부른다(`default_cleanup_writer`).

관측을 커밋한 instance 는 이 규칙에 걸리지 않는다. 그래서 남는다. `check_retained_binding` 주석은 이렇게 적는다. "a record that names its declaration and is detached holds nothing anyone waits on, so it is kept as evidence and refuses nothing." 증거로 남긴다는 뜻이다. 다만 언제까지 남기는지는 정한 곳이 없다.

### 3.2 과거 binding 을 읽는 곳

| 읽는 곳 | 무엇을 읽나 | 남겨야 하는 것 |
|---|---|---|
| `reconcile_configuration` `retained_visibility` | 같은 `(id, source_path, revision)` 의 과거 binding 의 visibility. 서로 다르면 "ambiguous retained ownership" 으로 거절한다 | 묶음의 visibility 값마다 하나. 대표와 같은 값만 지우면 값의 집합이 그대로다 |
| `attach_entry`, `reconcile_configuration` → `preserve_state_runtime` | 같은 owner·package 의 persistent binding 이 적은 container runtime. 다르면 거절한다 | 묶음의 runtime 값마다 하나. 대표와 같은 runtime 만 지우면 같은 거절이 나온다 |
| `reconcile_configuration` `runtimes_in_use` | 과거 binding 이 적은 runtime. 죽은 서버가 남긴 container 를 label 로 찾아 훑을 engine 목록에 넣는다 | 없음. 죽은 서버가 남긴 instance 의 기록은 `Attached`·`Detaching` 등이라 남고, 그 runtime 도 목록에 남는다 |
| `gecko_sweepable` | 자원을 돌려준 instance 는 profile 을 지워도 된다고 본다. binding 이 없는 instance 도 지워도 된다고 본다 | 없음. binding 을 지워도 결과가 같다 |
| `snapshot` (대시보드 Add-on 화면), `slice`, `freeze`(`masc_lane_evidence`) | 과거 instance 의 binding 과 관측 | 없음(D7). 이전 run 이 필요하면 살아 있을 때 `freeze` 로 고정한다 |
| `persisted_binding` (Observe·Detach·Retain·Act·Action_status 의 visibility 확인, `retain_unconfirmed`) | instance 하나의 binding | 없음. 지워진 instance 에는 "Lane instance is unavailable to this caller" 로 답한다. 지금도 binding 이 없는 instance 에 같은 답을 한다 |

Broadcast 재시도는 binding 을 찾지 않는다. `prepare_broadcast` 는 `broadcasts/` 의 이전 기록에서 visibility 와 고정한 증거를 읽는다. 그래서 이 RFC 는 `broadcasts/` 를 지우지 않는다. freeze 묶음은 `write_blob` 으로 `evidence/` 에 쓰이고, 이 RFC 는 blob 을 지우지 않는다(D6). action 기록은 `action_status` 가 요청 하나씩 읽을 뿐이고, 다시 켤 때 훑어서 이어 하지 않는다(`load_action` 의 호출처는 `lane_addon_runtime.ml` 3572 한 곳이다).

## 4. 설계

### 4.1 대상

pass 하나가 읽은 binding 전체를 `R`, 그 순간 이 프로세스가 쥐거나 정리하는 instance 를 `L` 이라고 하자. instance `b` 는 아래를 모두 만족하면 지운다.

1. `b` 의 lifecycle 이 `Detached (Never_created | Released | Native_released)` 다.
2. `b` 가 `L` 에 없다.
3. `b` 에 owner `o` 가 있다.
4. `R` 에서 같은 `(o.id, o.source_path, o.revision)` 묶음의 대표 `k` 가 `b` 가 아니다. 그리고 `b` 의 visibility 가 `k` 의 visibility 와 같다.
5. `b` 가 persistent 면, `R` 에서 같은 `(o.id, package id)` persistent 묶음의 대표 `k'` 가 `b` 가 아니다. 그리고 `b` 의 runtime 이 `k'` 의 runtime 과 같다.
6. `b` 의 UUIDv7 시각을 읽을 수 있고, pass 시각보다 미래가 아니다.
7. `R` 에 이 owner 의 읽지 못한 기록(fault)이 없다. 읽지 못한 기록이 그 owner 의 가장 새 기록일 수 있기 때문이다. 지금 `blocking_faults` 가 declaration 을 막는 조건과 같다.

§3.2 의 독자는 묶음마다 값의 집합을 본다. `retained_visibility` 는 visibility 집합이 하나로 모이는지 보고, `preserve_state_runtime` 은 runtime 이 지금 package 와 같은지 본다. 조건 4·5 는 대표와 같은 값을 가진 binding 만 지운다. 그래서 지운 뒤에도 묶음마다 값의 집합이 그대로다. 집합이 둘 이상이라 지금 "ambiguous retained ownership" 으로 거절되는 묶음은 지운 뒤에도 같은 이유로 거절된다.

2026-11-06 에는 revision 묶음 18개 중 visibility 가 둘 이상인 묶음이 0개다. L1 은 이런 묶음의 수를 따로 센다(§6).

### 4.2 남는 것

2026-11-06 binding 에 §4.1 을 적용하면 이렇다.

- 지울 대상: 3,522개. binding, 관측, action 을 합쳐 3,397.4MB
- 남는 것: 18개, 85.4MB. revision 묶음 18개, persistent 묶음 6개, 붙어 있는 10개, `native_retained` 3개가 겹친다.

남는 수는 선언의 revision 수와 persistent 묶음 수를 따른다. 서버를 다시 켜도 늘지 않는다.

### 4.3 지우는 순서

instance 하나는 binding → 관측 폴더 → action 폴더 순서로 지운다.

- binding 이 그 instance 를 읽을 수 있게 하는 기록이다. binding 을 먼저 지우면, 지우는 중에 멈춰도 읽는 쪽은 "없는 instance" 로 본다. 반쯤 지운 관측을 읽는 일이 없다.
- 관측·action 폴더 이름(instance id 의 SHA-256)이 `R` 의 어떤 binding 과도, `L` 의 어떤 instance 와도 맞지 않으면 그 pass 에서 지운다. 폴더 목록은 잠금 안에서, binding 을 읽기 전에 만든다. 목록을 만든 뒤 생긴 폴더는 목록에 없다. 목록에 있는 폴더의 binding 은 그 폴더보다 먼저 써졌으므로(다음 항목의 전제) `R` 에 들어 있다. 그래서 막 생긴 instance 의 폴더가 orphan 으로 보이지 않는다. 직접 Attach 가 configuration 잠금을 잡지 않아도 이 순서는 맞다.
- 읽지 못한 binding(fault)이 있으면 폴더 규칙도 `gecko_sweepable` 과 같이 막는다. fault 가 이름을 댄 instance 의 폴더는 지우지 않는다. 어느 instance 인지 모르는 fault 가 하나라도 있으면 그 pass 는 binding 없는 폴더를 하나도 지우지 않는다. 읽지 못한 binding 의 instance 는 `R` 에 없어서, 이 규칙이 없으면 그 폴더가 orphan 으로 보인다. binding 을 지우고 멈춘 instance 는 다음 pass 에서 마저 지워진다. 지금 binding 없이 남은 관측 폴더 2개와 action 폴더 5개도 이 규칙으로 지워진다.
- 관측 기록은 binding 이 커밋을 정한다(RFC "lane-addon-observation-commits-at-the-binding"). 이 RFC 는 새 instance 의 binding 이 그 instance 의 관측보다 먼저 써진다고 전제한다. 그러면 binding 없는 관측 폴더는 진행 중인 instance 의 것이 아니다. 이 전제는 아직 코드로 확인하지 않았다. 구현 층이 L1 에서 확인한다(§7). 전제가 틀리면 binding 없는 폴더는 지우지 않는다.

### 4.4 어디서 도나

`reconcile_configuration` 의 configuration 잠금 안에서 정한다. 잠금 안에서 관측·action 폴더 목록을 먼저 만들고, 그다음 이 pass 가 이미 하는 `historical` 읽기를 쓴다. 대상은 그 reading 과 계획을 만드는 순간의 `m.entries`·`m.recovering` 으로 정한다. 파일 지우기는 잠금을 놓은 뒤 `offload` 에서 한다. gecko sweep 이 같은 방식으로 돈다. instance id 는 다시 쓰지 않으므로, 잠금을 놓은 뒤에도 계획이 맞다.

지우기는 이 pass 가 자기 계획대로만 한다. 횟수 제한이나 대기 시간은 두지 않는다. 첫 pass 는 3,522개를 지운다. 그 뒤로는 서버를 다시 켤 때마다 Add-on 마다 하나씩 지운다.

### 4.5 60초마다 두 번 읽는 문제

pass 하나가 binding 전체를 두 번 읽는다(`historical`, gecko sweep). 키퍼 리뷰는 이것을 캐시로 먼저 고치자고 했다. 이 RFC 는 캐시를 두지 않는다.

- gecko sweep 주석은 "the bindings and liveness read now" 로 정한다고 적는다. 그 pass 안에서 instance 가 붙거나 떨어질 수 있다. 앞선 reading 을 다시 쓰면 이 전제가 깨진다.
- §4.1 이 적용되면 읽는 binding 이 3,540개에서 약 18개로 준다. 두 번 읽어도 비용이 작다. 캐시는 무효화 규칙만 더한다.

## 5. 이 RFC 가 하지 않는 것

- content-addressed blob: `evidence/`(7,195개, 6.2GB), `sequences/`(6,963개). 관측 기록과 freeze 묶음이 hash 로 가리킨다. blob 을 쓰는 곳은 `lane_addon_host_delivery`, `lane_addon_packet`, `lane_addon_records`, `lane_addon_sources`, `server_lane_addon_sampling` 이다. 아무도 안 가리키는 blob 을 고르려면 이 다섯 곳이 가리키는 목록을 한 타입으로 모아야 한다. 이 RFC 가 관측을 지우면 가리키는 쪽이 줄 뿐, blob 은 그대로다. 다음 RFC 에서 다룬다.
- settled 보관본(`tool-request-owners-settled`, 18GB): 잘못 지우면 요청이 다시 실행된다. 독자는 Librarian durable 실행, floor 정리, workspace memory Add-on 이다. 독자마다 어디까지 읽었는지 확인하는 조건이 필요하다. 따로 RFC 를 쓴다.
- `host-results`(2.7GB), `exact-requests`(2.1GB): instance 가 아니라 declaration·요청에 묶인다. 무엇이 가리키는지 따로 확인해야 한다.
- owner 가 없는 instance: 지금 1개다. 묶음이 없어서 이 규칙을 쓸 수 없다.
- `Failed`·`Detaching`·`Native_retained` instance: D2 대로 계속 남는다. 이들이 언제 끝나는지는 다음 RFC 에서 다룬다.

## 6. 구현 순서

1. L1 계획: §4.1 의 대상을 계산한다. 아무것도 지우지 않는다. 두 조각으로 나눈다.
   - L1a: `reconcile_configuration` 이 pass 마다 대상 수와 남는 수를 inventory(`GET /api/v1/lane-addons` 의 configuration 부분, 운영자에게만)에 싣는다. visibility 나 runtime 이 대표와 달라 남는 binding 수, 그런 묶음 수도 같이 싣는다. 수는 그 pass 가 이미 읽은 binding 으로 센다.
   - L1b: 바이트는 시작 정비(worker domain)에서 한 번 센다. 대상의 바이트, 남는 것의 바이트, `observations` 전체 바이트를 로그 한 줄에 남긴다. pass 마다 세지 않는 까닭: 2026-11-06 관측 파일이 27만 개라 60초마다 그만큼 lstat 해야 한다. 대상 바이트는 서버를 다시 켤 때만 늘어서, 시작마다 세면 충분하다. 시작 시점의 liveness 는 pass 의 liveness 와 다를 수 있으므로 이 바이트는 근사다. Keeper 리뷰가 이 방식을 골랐다(2026-11-06).
   - 확인: 배포 뒤 inventory 의 대상 수가 §4.2 의 수치(그 사이 늘어난 만큼 더한 값)와 맞는다.
   - L1 만 배포된 동안에는 pass 마다 binding 3,540개(그 사이 늘어난 만큼 더)를 계속 두 번 읽는다. §4.5 의 비용 감소는 L2 부터다.
   - §2.3 의 0번에는 `Execute` 안의 호출과 대시보드·TUI 화면 조회가 빠져 있다. L1 배포 전후로 서버 요청 로그에서 `GET /api/v1/lane-addons` 수를 세어 운영자에게 같이 보인다.
2. 운영자 확인: 운영자가 L1 의 수치를 보고 L2 를 병합한다. 설정 스위치는 두지 않는다.
3. L2 지우기: §4.3 순서로 지운다. 지운 수와 바이트를 pass 마다 한 줄 info 로그에 남긴다.
   - 확인: 첫 pass 뒤 `bindings` 가 약 18개, `observations` 가 약 85MB 다. 서버를 다시 켠 뒤에도 binding 수가 Add-on 수만큼만 늘었다가 다음 pass 에 돌아온다.

## 7. 구현 층이 코드로 닫을 것

- 새 instance 의 binding 이 그 instance 의 관측보다 먼저 디스크에 써지는지 확인한다(§4.3 의 세 번째 항목).
- `lane_addon_store_preflight.ml` 은 부팅 때 `actions` 폴더를 검사한다. binding 없이 남은 action 폴더를 거부하는지 확인한다. 거부하면 §4.3 순서가 부팅을 막지 않는지 본다.
- `Lane_addon_store` 에 instance 하나의 관측·action 폴더를 지우는 함수가 아직 없다. `remove_binding_with` 처럼 부모 디렉터리를 sync 한다.

## 8. 리뷰

- 키퍼 리뷰어와 먼저 설계를 맞췄다.
  - 받아들인 것: binding 보존 규칙과 settled 보관본 규칙을 RFC 둘로 나눈다. 쌓인 것은 지우고 새로 설치하지 않고, 새 규칙으로 정리한다. 세기만 하는 층 → 운영자 확인 → 지우기 순서로 낸다. 새로 쌓이는 쪽부터 막는다(§4.2: 다시 켤 때마다 남던 것이 다음 pass 에 지워진다).
  - 리뷰어가 확인하라고 한 것: 진행 중이거나 재개할 수 있는 요청이 binding 으로 owner 를 찾는지. §3.2 의 마지막 두 단락에 답했다.
  - 받아들이지 않은 것: 두 번 읽기를 캐시로 먼저 고치기. 이유는 §4.5 에 있다. 한 pass 안에서 "표시 → 다음 주기 재확인 → 삭제" 두 단계로 지우기. 이 RFC 의 대상은 자원을 돌려준 instance 라서, 잘못 지워도 요청이 다시 실행되지 않는다. 같은 잠금 안에서 liveness 와 함께 판단하면 한 단계로 충분하다.
- 첫 head(`ba9009bc81e`) 리뷰(COMMENT 5791033248)를 이렇게 반영했다.
  - P2-A: 가장 새 것만 남기면 지금의 "ambiguous retained ownership" 거절이 사라져 접근 제한이 풀릴 수 있다. → 조건 4 에 "대표와 visibility 가 같을 때만"을 더했다. 다른 값을 가진 binding 은 남기고, L1 이 그 수를 센다.
  - P2-B: 시계가 뒤로 가면 UUIDv7 순서가 틀린다. → 대표가 가장 새 것일 필요가 없게 바꿨다(D3). 시각을 읽을 수 없거나 미래인 binding 은 지우지 않는다(조건 6).
  - P2-C: 폴더 목록을 잠금 밖에서 만들면 막 생긴 instance 의 폴더를 지울 수 있다. → 목록을 잠금 안에서 binding 을 읽기 전에 만든다(§4.3, §4.4).
  - 조건 5 의 근거에서 "runtime 이 모두 같다"를 뺐다. 대표의 runtime 과 같아야 한다고 바로 적었다.
  - L1 만 배포된 동안 두 번 읽기 비용이 그대로라는 점을 §6 에, `Failed` 등이 계속 남는 점을 §5 에 적었다. 대시보드 사용 수를 L1 전후로 세기로 했다(§6).
  - 한 단계 삭제는 P2-A 가 닫히면 받아들인다고 했다. 위 반영으로 닫았다고 본다.
- 둘째 head(`b853045f91e`) 리뷰(5791182567): P2-A·B·C 는 닫혔다고 봤다. 새 P2-D 는 읽지 못한 binding 의 instance 폴더가 orphan 으로 지워질 수 있다는 것이다. → §4.3 에 `gecko_sweepable` 과 같은 fault 규칙을 더했다.
