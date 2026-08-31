# Health event-queue cache Linux R1

## 결과

Keeper event queue의 snapshot/WAL commit은 `keeper_event_queue`와
`keeper_reaction_ledger` health facts를 바꾸지만 full-health cache를 무효화하지 않았다.
official orphan-cancel route가 applied를 반환한 뒤에도 이전 pending count의 ready snapshot이
유지됐다.

변경은 `Keeper_event_queue_persistence`에 process-wide non-yielding state-change observer를
추가한다. snapshot save와 transition WAL fsync가 성공한 경계에서 observer를 호출하고 server
bootstrap이 이를 full-health invalidation/wake에 연결한다. no-op/replay/rejection은 알리지 않으며
observer 예외는 이미 commit된 queue 결과를 바꾸지 않는다. transition outbox retirement도
별도 snapshot commit이므로 최신 ledger/outbox facts를 다시 깨운다.

## exact identity

- issue: `#31982`
- stacked base: `be2d3ded761e842445f5871ada369e1a36b46de2` (`#31981` head)
- product change: `eb96a8b9f3091dd9716e4d510b9a08240085ef3c`
- measurement composition: `326fec1e097ea66ea4f60c4faceae8f0a3ae5a46`
- Linux/arm64 image: `sha256:bfbbc811b29c712fc2fd47f7b67c282c434708364229d0dc5af9300adeec81f3`
- binary SHA-256: `298f5ab7ad1531d1f07be18284963f892c0e6d34d5841dff8d3af845733637c1`
- runtime instance: `01a05351-cd0a-7000-b952-8414d800fc3f`

measurement composition은 product change에 old-stack Docker source-build input 보완만 포함한다.
source identity는 BuildKit remote commit checkout, image digest, in-process binary SHA로 고정했다.

## setup

격리 볼륨의 stopped `frontend` queue에 pending 3개를 두고 meta/config를 SHA-pinned backup한 뒤
제거해 official orphan-cancel contract를 만들었다. deployed 8935와
`/Users/dancer/me/.masc`는 건드리지 않았다.

- `frontend.json` backup/restored SHA:
  `34723bdeaed89b71c786a4c6e436c644f83697aabe3ccf7d0fb6bc30ab5c8f91`
- `frontend.toml` backup/restored SHA:
  `4a6962d435d7d16ec08cb1aa8bad8991e821b283766747ee9c70d35a71b7d737`

post-fix 종료 뒤 두 파일을 같은 SHA로 볼륨에 복구했다.

## pre-fix r49

1. fresh control: queue/ledger pending 3.
2. `2026-08-30T15:27:49.392837172Z`: operator cancel 시작.
3. `2026-08-30T15:27:49.406397838Z`: HTTP 200, applied,
   `pending-cancel:r49-cancel-wmsg-0f747` commit.
4. `2026-08-30T15:27:49.416883713Z`: immediate health는 26,037ms old ready,
   `refresh_requested=false`, queue/ledger pending 3을 반환했다.
5. fresh snapshot computed `1788103677.835396`은 pending 2와 transition outbox 1을 반환했다.

raw checkpoint file은 transition WAL을 replay하기 전 상태일 수 있으므로 authority 증거로 쓰지
않았다. official applied response와 WAL-aware full-health fresh projection을 대조했다.

## post-fix r50

startup recovery가 이전 outbox를 projection한 fresh control은 queue/ledger pending 2,
outbox 0, reaction count 1이었다.

1. `2026-08-30T15:39:08.551889375Z`: 다음 exact source cancel 시작.
2. `2026-08-30T15:39:08.569269833Z`: HTTP 200, applied,
   `pending-cancel:r50-cancel-wmsg-2a218` commit.
3. `2026-08-30T15:39:08.577625167Z`: 8ms-later health는 old ready를 버리고
   `warming`, computed/age null, `refresh_requested=true`, `refresh_in_flight=true`를 반환했다.
4. event-driven refresh computed `1788104358.440285`; ready projection은 queue/ledger pending 1,
   outbox 0, reaction count 2였다.

immediate `refresh_in_flight=true`는 mutation observer가 periodic interval과 무관하게 refresh를
깨웠다는 직접 증거다.

## 검증과 경계

- focused build: `test_keeper_event_queue_state_v2.exe`,
  `test_server_runtime_bootstrap.exe` pass
- snapshot commit/no-op/observer failure isolation: persistence 7, 1/1 pass
- transition WAL commit/replay exactly-once: persistence 8, 1/1 pass
- stacked full-health invalidation response: bootstrap 51, 1/1 pass
- `ocamlformat --check`, `git diff --check`: pass
- r49 pre-fix app exit 0; r50 post-fix app exit 0
- full suite와 CI는 실행/주장하지 않는다.

## 근거

- [근거] remote exact-commit BuildKit checkout, image/binary identity, official applied
  operator responses, pre-fix stale-ready, post-fix warming/current-ready snapshots,
  2026-08-31T00:39:51+09:00 확인, 신뢰도 High.

