# Health reaction-ledger cache Linux R1

## 결과

scheduled Keeper wake는 durable event queue를 먼저 commit하고 reaction-ledger stimulus row를 나중에
append한다. #31984의 queue observer는 첫 commit에서 full-health refresh를 깨우지만, refresh가 두
commit 사이를 읽으면 새 queue와 옛 ledger를 함께 ready로 만들 수 있다. direct stimulus/turn-start
append 자체에는 post-append observer가 없었다.

변경은 `Keeper_reaction_ledger`의 두 direct append가 성공한 뒤 process-wide non-yielding observer를
호출하고 server bootstrap이 이를 full-health invalidation/wake에 연결한다. append 실패는 알리지
않고 observer 예외는 이미 persisted된 row를 바꾸지 않는다. transition-outbox reaction은 ledger
append 뒤 #31984의 outbox-retirement snapshot observer가 이미 순서를 보장하므로 중복 알림을
추가하지 않았다.

## exact identity

- issue: `#31988`
- stacked base: `c781affae07d8727c38f78d3a868e3dd9b49a972` (`#31987` head)
- product change: `eb00eeb5cf44091da0a7a1665f24f6bb58bc6f29`
- measurement composition: `9f7b469370ba898698486c0243dabacb8052d327`
- Linux/arm64 image: `sha256:6ed0517136217a8a214319256aedd092ef92faee38d6f9a310ae66fd17edcb76`
- binary SHA-256: `5e9403c6cd854526b54d99bda3afc21eb5a5d77a1b17178ad6cc149b1114c268`
- runtime instance: `01a05378-58b0-7000-83a1-c0113358e55e`

measurement composition은 product change와 앞선 health observer stack, old-stack Docker source-build
input 보완만 포함한다. committed clean tree, image digest, in-process binary SHA를 함께 고정했다.

## setup

격리 volume에서 declarative autoboot가 꺼진 `qa`를 one-shot `masc_schedule_create` target으로
사용했다. schedule consumer는 durable stimulus를 보존하지만 Keeper를 실행하지 않으므로 뒤따르는
Owner operation/turn mutation이 ledger health 증거를 덮지 않는다. deployed 8935와
`/Users/dancer/me/.masc`는 건드리지 않았다.

## pre-fix r55: stale은 발현되지 않음

fresh control은 computed `1788106345.401732`, qa ledger stimulus/pending `0/0`이었다.

1. schedule `r55-ledger-direct`, occurrence
   `482bc6c093b482af85c4fc51a7e0c6522b73afa971a7690f43f6594a7ab6f896`을 생성했다.
2. ledger row는 `1788106387.0556`에 기록됐다.
3. queue-triggered snapshot은 `1788106387.064955`에 계산됐다.
4. `2026-08-30T16:13:07.073317722Z` probe는 ready age 6ms, qa stimulus/pending `1/1`을
   반환했다.

이 실행에서는 refresh가 ledger append 뒤를 읽어 stale이 발현되지 않았다. 따라서 r55를 stale
runtime 증거로 사용하지 않는다. source ordering에 post-append 보장이 없다는 gap과, 이 exact
실행에서 race를 관측하지 못했다는 사실을 함께 유지한다.

## post-fix r56

fresh control은 computed `1788106853.244586`, qa stimulus/pending `1/1`이었다.

1. schedule `r56-ledger-direct`, occurrence
   `7471f45eece0a2aaac92f5502476d15672d77aa65f9fe3eb4cb4fcd9c0bf6bd7`을 생성했다.
2. 새 ledger row는 `1788106896.706663`에 기록됐다.
3. `2026-08-30T16:21:36.716200971Z` immediate probe가 본 ready snapshot은
   `1788106896.714582`에 계산됐고 age 0ms, qa stimulus/pending `2/2`였다.
4. 같은 응답에서 `refresh_in_flight=true`, 후속 refresh start
   `1788106896.714668`을 관측했다.
5. 후속 refresh는 `1788106896.722788`에 끝나 idle-ready 상태로 qa `2/2`를 유지했다.

첫 queue-triggered 계산이 끝난 직후 ledger observer가 후속 refresh를 연쇄 실행했다. 첫 계산이
우연히 row를 포함했더라도 post-append refresh가 별도로 보장되는 실행 흔적이다.

## 검증과 경계

- focused build: `test_keeper_reaction_ledger.exe`, `test_server_runtime_bootstrap.exe` pass
- ledger 0-3: 4/4 pass
- direct stimulus/turn-start append success notification 확인
- append failure notification 0회, observer failure 뒤 durable rows 2개 보존 확인
- full-health cache bootstrap 51: 1/1 pass
- `ocamlformat --check`, `git diff --check`: pass
- r55 pre-fix와 r56 post-fix app exit 0
- full suite와 CI는 실행/주장하지 않는다.

## 근거

- [근거] exact committed source, Linux image/binary identity, authenticated schedule responses,
  ledger row와 연쇄 refresh timestamps, 2026-08-31T01:22:15+09:00 확인, 신뢰도 High.
- [근거] r55에서는 stale race가 발현되지 않았다는 음성 결과, 같은 시각 확인, 신뢰도 High.

