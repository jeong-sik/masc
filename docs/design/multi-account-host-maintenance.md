# 다계정 설치에서 호스트 유지보수를 누가 도는가 — 빌드·볼륨 회수·GC 보고의 주체

- 날짜: 2026-11-21
- 결정 글: `board:p-57b82628fa459a9e130aadefce59dc1d` (리더 결정, `ocaml-dev` 기록)
- Task: `task-3856` (부모 `task-3853`), 점검 주체 Task `task-3846`(A3)
- 코드 사실: main `52719b9a` 에서 읽었다. 줄 번호와 바이트 오프셋도 그 커밋 기준이다. 바이트는 `grep -b` 가 낸 파일 오프셋이다.
- 이 문서는 **결정을 적는 기록**이다. 동작을 바꾸지 않았고 서버를 띄우거나 테스트를 돌리지 않았다.

## 0. 요약

- 다계정 설치(`Runtime_account_access.is_multi_account ()`)에서는 호스트 유지보수 셋(`Server_keeper_build_maintenance`·`Server_keeper_volume_maintenance`·`Server_sandbox_volume_gc_report`)과 Librarian writer pulse 가 **시작되지 않는다.** 두 자리 모두 "누가 도는가"가 정해지지 않았기 때문이다.
- 주체는 **`task-3846`(A3) 계열**로 정한다. 별도 유지보수 lane 은 만들지 않는다.
- 주체가 정해지기 전이라도 **프로세스 단위 회수는 넣지 않는다.** 다계정 볼륨 루트를 훑는 회수는 다른 사람의 볼륨을 지울 수 있다.
- 점검 주체는 **Task `task-3846`** 이다. 새 Schedule 은 만들지 않는다.

## 1. 결정

1. **층은 A3 계열이다.** 회수·보고를 별도 lane 으로 떼면 다계정 분기를 만든 A3 와 판정이 갈라져 같은 판단이 두 곳에 생긴다. 그래서 `task-3846` 안에서 다룬다.
2. **임시 프로세스 단위 회수는 허용하지 않는다.** 주체가 정해지기 전의 임시 조치로도 넣지 않는다. 볼륨 루트 전체를 훑는 동작은 계정 경계를 넘는다.
3. **점검 주체는 `task-3846`** 이며, 이 문서가 그 결정의 공개 위치다. 회수 시작 단계가 `task-3846` 에 적히기 전까지 `task-3856` 은 완료가 아니다(§4).

## 2. 지금 비어 있는 두 곳

### (가) `lib/server/server_bootstrap_maintenance.ml:471-474` (파일 오프셋 20,666)

```ocaml
if not (Runtime_account_access.is_multi_account ()) then begin
  Server_keeper_build_maintenance.start ~sw ~clock ~config;
  Server_keeper_volume_maintenance.start ~sw ~clock ~config;
  Server_sandbox_volume_gc_report.start ~sw ~clock ~config;
end;
Server_tool_blob_sweep.start ~sw ~clock ~config;
```

다계정이면 위 셋이 **통째로** 시작되지 않고, 가드 밖에 있는 `Server_tool_blob_sweep` 만 계속 돈다. 즉 다계정 설치에서는 빌드 산출물 회수·볼륨 회수·sandbox 볼륨 GC 보고가 아무도 돌지 않는다.

### (나) `lib/server/server_bootstrap_maintenance.ml:876-877` (파일 오프셋 39,928)

```ocaml
let pulse_memory_writers () =
  if Runtime_account_access.is_multi_account ()
  then ()
  else
    Option.iter
      (fun writers ->
         Librarian_writers.pulse writers
           (Keeper_memory_writers.registered ~base_path:config.base_path))
      (Keeper_memory_writers.find ~base_path:config.base_path)
```

다계정이면 `Librarian_writers.pulse` 가 돌지 않는다. 다계정에서 Librarian 은 거절이 정본이므로 **스킵 자체가 틀린 것은 아니고**, "왜 비었는지"를 적는 것이 이 항목의 산출물이다.

`is_multi_account` 호출은 이 파일에 정확히 두 곳이다(위 둘). 세 번째 자리는 없다.

## 3. 어느 단계가 채우는가

| 빈 자리 | 채우는 단계 | 내용 |
|---|---|---|
| (가) | **A3-2b** (하드 삭제·정리 층) | `Server_keeper_volume_maintenance`·`Server_sandbox_volume_gc_report` 를 **workspace/process 범위 전용 진입점**으로 분리해 시작한다. per-person 홈은 순회하지 않는다. `Server_keeper_build_maintenance` 는 per-Keeper 빌드 산출물을 다루므로 다계정에서는 계속 스킵하고 사유를 적는다. 구현: `task-3870` (#54270). 두 루프는 모든 호스트 형태에서 시작하고, `Server_keeper_build_maintenance` 만 단일 계정 전용으로 남긴다. |
| (나) | **A3-3** (autonomous 배선 층) | 다계정에서 `Librarian_writers.pulse` 를 스킵하는 근거를 문서에 적는다. 살릴 경우에도 계정 경계를 넘지 않는 범위만 맡긴다. |

두 단계는 `task-3846` 의 기록에 한 줄씩 들어가야 닫힌다(§4).

## 4. 잔여 조건 R1 — `task-3846` 에 회수 시작 단계 한 줄

`task-3856` 의 완료 조건 1·2 는 이 문서로 충족되지만, A3 가 **실제로 회수를 시작하는 단계를 갖는다**는 근거가 `task-3846` 기록에 없으면 이 결정은 닫히지 않는다. 그래서 잔여 조건을 이렇게 둔다.

> **R1**: `task-3846`(A3) 기록에 "어느 단계에서 볼륨 회수·GC 보고를 시작하는가" 한 줄이 들어가야 `task-3856` 이 완료로 올라간다.

넣을 문장 초안(그대로 써도 된다):

> **A3-2b**: `lib/server/server_bootstrap_maintenance.ml:471-474` 의 다계정 가드에서 `Server_keeper_volume_maintenance`·`Server_sandbox_volume_gc_report` 를 workspace/process 범위 전용 진입점으로 분리해 시작한다. per-person 홈은 순회하지 않는다. `Server_keeper_build_maintenance` 는 per-Keeper 빌드 산출물을 다루므로 다계정에서는 계속 스킵하고 사유를 적는다. 구현은 `task-3870` (#54270) 이다.

`task-3846` 을 수행 중인 Keeper 쪽에 이 한 줄을 요청했고, 이 문서에는 요청 사실만 남긴다. 이 문서는 `task-3846` 을 편집하지 않는다.

## 5. 재지 못한 것

- **바이트 오프셋이 원 기록과 다르다.** 원 기록(`main 73b621643e`)은 18,232 / 35,500 이었고, 이 문서(`main 52719b9a`)는 `grep -b` 로 20,666 / 39,928 을 쟀다. 줄 번호는 `:471-474` · `:876-877` 로 같다. 두 값이 왜 다른지는 확정하지 못했다(다른 커밋이므로 이동은 당연하지만, 차이가 선형 이동인지 다른 셈 방식인지는 확인하지 않았다). 인용할 때는 **커밋과 잰 방법을 함께 적는다.**
- 이 결정이 실제로 회수를 돌리는지, 돌린다면 볼륨이 얼마나 줄어드는지는 **재지 않았다.** 코드 경로를 읽고 결정을 적었을 뿐이다.
- 다계정 설치에서 지금 볼륨이 실제로 얼마나 차 있는지도 재지 않았다. 회수가 비어 있다는 사실이 곧 사고라는 뜻은 아니다.
