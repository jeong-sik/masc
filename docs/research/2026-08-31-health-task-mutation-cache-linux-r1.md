# Health task-mutation cache Linux R1

## 결과

`/health?full=1`은 task backlog에서 active owner safety facts를 계산하지만, 성공한 task
mutation은 execution/light-dashboard cache만 무효화했다. 따라서 60초 TTL 안에서는 task를
실행 불가능한 Keeper가 claim한 뒤에도 이전 `owner_block=false` ready snapshot이 반환됐다.

변경 뒤 server bootstrap은 기존 execution cache invalidator와 full-health invalidator를 하나의
`Workspace_hooks.on_task_mutation_fn` callback으로 설치한다. authoritative task commit은 기존
execution cache settlement를 그대로 수행하고, full-health ready fields를 폐기한 뒤 background
refresh를 깨운다. full-health callback 예외는 이미 commit된 task mutation을 실패시키지 않는다.

## exact identity

- issue: `#31978`
- stacked base: `9ee05174f60c49c57766b9fa0e1de330fd089243` (`#31977` head)
- product change: `09b87cec7f0777e6db70783a084e1c074dd6b4c1`
- measurement composition: `4d17c84156291b6efc094c1e5e78d6bd1e71fd0c`
- Linux/arm64 image: `sha256:1149472f25561419f50952a18f1bbe7e34310d16b4bf4276db4de13d079c63a1`
- binary SHA-256: `9a9ffa115053206db98f127b62e85545baf8b3fc48fed3c7349f8f46def5aad1`
- runtime instance: `01a05331-b0fd-7000-8dc5-f93dc9c5ffaf`

measurement composition은 product change에 old-stack Docker source-build input 보완만 포함한다.
BuildKit log는 remote Git context에서 measurement commit을 checkout하고 해당 binary를 image에
복사한 경계를 기록한다. 이 old-stack health payload는 commit field를 노출하지 않으므로 source
identity는 BuildKit checkout, image digest, in-process binary SHA의 결합으로 고정했다.

## pre-fix r45

격리 볼륨에서 `frontend`를 fleet binding 대상으로 유지하되 executable fiber는 정지하고,
`task-001`을 todo로 만들었다.

1. control snapshot: computed `1788101474.206373`, owner blocker false/count 0.
2. `2026-08-30T14:51:52.619505548Z`: `frontend` claim 시작.
3. `2026-08-30T14:51:52.635764757Z`: `task-001 todo -> claimed` 성공.
4. `2026-08-30T14:51:52.640833590Z`: immediate full-health는 같은 computed time,
   age 38,432ms, `refresh_requested=false`, owner blocker false/count 0을 반환했다.
5. periodic refresh 뒤 computed `1788101565.897302`에서 owner blocker true/count 1,
   `frontend/task-001/claimed/executable=false`가 처음 나타났다.

같은 task 상태의 다음 snapshot이 blocker를 true로 계산했으므로, immediate false는 정책 차이가
아니라 task mutation 뒤 이전 ready snapshot을 재사용한 결과다.

## post-fix r46

r45 app을 exit 0으로 종료하고 같은 격리 볼륨을 exact-source r46 image로 재기동했다. provider는
정지된 상태였고 deployed 8935 및 `/Users/dancer/me/.masc`는 건드리지 않았다.

1. `2026-08-30T15:03:42.903372Z` control: ready, computed
   `1788102222.835015`, owner blocker false/count 0.
2. `2026-08-30T15:04:07.645360083Z`: 동일 `frontend` claim 시작.
3. `2026-08-30T15:04:07.659380750Z`: claim 성공.
4. task hook이 snapshot을 invalidate하고 wake했다.
5. refresh가 probe보다 먼저 완료되어 snapshot computed time은
   `1788102247.659097`, claim 완료와 같은 millisecond였다.
6. `2026-08-30T15:04:07.663397Z` immediate probe는 age 3ms current-ready와
   owner blocker true/count 1을 반환했다.

런타임에서는 warming window가 4ms보다 짧아 첫 probe가 이미 current-ready였다. focused cache
test는 invalidation 직후 warming/refresh-requested contract를 결정적으로 고정하고, Linux proof는
periodic wait 없이 claim과 같은 millisecond에 refresh가 끝나는 경로를 증명한다.

## 검증과 경계

- focused build: `test_dashboard_cache.exe`, `test_server_runtime_bootstrap.exe` pass
- task hook composition: correctness 8, 1/1 pass
- full-health invalidation response: bootstrap 51, 1/1 pass
- `ocamlformat --check`, `git diff --check`: pass
- r45 pre-fix app exit 0; r46 post-fix app exit 0
- full suite와 CI는 이 기록에서 실행/주장하지 않는다.
- health policy, task lifecycle, refresh TTL은 바꾸지 않는다.

## 근거

- [근거] remote exact-commit BuildKit checkout, image/binary identity, pre-fix stale-ready
  control, post-fix same-millisecond current-ready control, 2026-08-31T00:05:02+09:00 확인,
  신뢰도 High.

