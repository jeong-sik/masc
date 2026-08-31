# Full-health mutation burst coalescing Linux R1

## 결과

앞선 observer stack은 health-visible mutation을 즉시 full-health refresh로 전파하지만, 순차적으로
도착하는 짧은 burst를 거의 매 mutation마다 다시 계산했다. 같은 1–2초 구간의 122 invalidation이
pre-fix r57에서 full-health fleet scan 104회로 증폭됐다.

변경은 generic `Proactive_refresh`에 기본값 0인 fixed leading-edge wake window를 추가하고,
full-health에만 100ms를 적용한다. 첫 wake는 60초 interval을 즉시 끊고, 최대 100ms 동안 sibling
signal을 모아 한 번 계산한다. compute 중 도착한 mutation은 다음 bounded window를 예약하므로
trailing-edge debounce처럼 계속 미뤄지지 않는다. wire metadata는
`refresh_wakeup_coalesce_ms=100`을 노출한다.

## 외부 근거와 적용

- [Lemmalog 원문](https://pwning.systems/posts/llm-memory-program-analysis/)은 과거 기록 검색과
  현재 사실 유지를 분리하고, 입력 변경이 의존 결론을 철회해야 한다고 설명한다.
- [STALE](https://arxiv.org/abs/2605.06527)은 updated evidence를 검색하는 것과 downstream 행동에
  적용하는 것 사이의 gap을 측정한다.
- [Supersede](https://arxiv.org/abs/2606.27472)는 더 큰 memory보다 current value 유지와 superseded
  value 폐기가 별도 문제임을 보인다.
- [CUP query coalescing](https://www.usenix.org/legacy/publications/library/proceedings/usenix03/tech/full_papers/roussopoulos/roussopoulos_html/node7.html)은
  fresh response를 기다리는 동안 sibling query를 suppress하고, 지연에는 timer를 둔다.

MASC 적용은 “mutation을 잊지 않되 모든 중간 상태를 다시 계산하지 않는다”이다. 100ms fixed
window가 timer 역할을 하고, queued follow-up이 최신 상태 수렴을 보장한다.

## exact identity

- issue: `#31990`
- stacked base: `a0fe4f7c3058ddd042a13f4d0dd295823c00dac1` (`#31989` head)
- product change: `934ffd3de617504481ca407b6ec7a7b8588e1b78`
- measurement composition: `6bac700f790de98e4d8add13d15a91b7002c63f7`
- Linux/arm64 image: `sha256:6a0ae2ea602d283a4627c0a6f131ff9eb529d5e469111b8f5ba3f087ce01f819`
- binary SHA-256: `266cf2a286eef15181afcbec946c837283a97ab77bbf6b5d2bf28d613ef89b6d`
- runtime instance: `01a0538a-1223-7000-89d7-1cdaab3476e3`

measurement composition은 product change와 앞선 health observer stack, old-stack Docker source-build
input 보완만 포함한다. committed clean tree, image digest, in-process binary SHA를 함께 고정했다.

## setup

격리 volume에서 declarative autoboot가 꺼진 `qa`를 같은 due time의 one-shot schedules target으로
사용했다. 각 accepted schedule은 queue snapshot commit과 direct reaction-ledger append를 하나씩
만들어 full-health invalidation 2회를 생성한다. Keeper는 실행되지 않아 Owner turn mutation이
섞이지 않는다. `MASC_LOG_LEVEL=debug`로 모든 sub-second refresh와 coalesced sibling count를
기록했다. deployed 8935와 `/Users/dancer/me/.masc`는 건드리지 않았다.

## pre-fix r57

64개 create를 시도했다. 61개가 accepted됐고 마지막 3개는 existing per-agent rate limit의 HTTP
429로 거부됐다. 거부된 세 건은 mutation 수에서 제외했다.

- 61 queue commits + 61 ledger appends = 122 invalidations
- ledger row 시간 범위: `1788107446.629912..1788107447.882162` (1.252s)
- burst 구간 full-health refresh: 104회
  - `16:30:46`: 31회
  - `16:30:47`: 73회
- final ready computed: `1788107447.900161`
- final queue pending: 64
- final `latest_stimulus_id`: newest persisted row와 일치
- timeout/stale/error: 없음

즉 stale이나 starvation은 없었지만 122 invalidation의 85%에 해당하는 104번의 complete refresh가
실행됐다.

## post-fix r58

rate-limit 안쪽의 정확히 61개 schedule만 생성했고 모두 accepted됐다.

- 61 queue commits + 61 ledger appends = 122 invalidations
- ledger row 시간 범위: `1788108073.510883..1788108075.538533` (2.028s)
- burst 구간 full-health refresh: 17회
- 17개 window가 sibling 105개를 합쳤다. initial wake 17 + siblings 105 = invalidations 122로
  모든 신호가 accounting됐다.
- r57 대비 refresh 감소: 104 → 17, 83.7%
- final ready computed: `1788108075.588317`
- final queue pending: 125
- final `latest_stimulus_id`: newest persisted row와 일치
- timeout/stale/error: 없음

별도 single schedule에서 queue와 ledger 두 wake는 하나로 합쳐졌다. ledger row
`1788108150.663238`을 포함한 ready snapshot은 `1788108150.775443`에 계산돼
ledger-to-ready 112.205ms였다. 이는 100ms fixed bound + 약 12ms compute다.

## 검증과 경계

- focused build: `test_server_runtime_bootstrap.exe` pass
- bootstrap 51–52: 2/2 pass
- `ocamlformat --check`, `git diff --check`: pass
- r57/r58 app exit 0
- full suite와 CI는 실행/주장하지 않는다.
- 61-schedule burst 한 쌍의 결과이며 장시간 연속 부하는 아직 측정하지 않았다.

초기 `create-responses.txt` 합본은 각 SSE 파일의 마지막 빈 줄만 보존해 receipt 증거로 사용할 수
없으므로 폐기했다. 중지된 컨테이너의 원본 `response-*.txt`를 다시 추출하고 SSE JSON-RPC와 HTTP
429 JSON을 request별 canonical JSONL로 파싱했다. r57 manifest는 64행(accepted 61, HTTP 429 3),
r58은 61행(accepted 61)이며 accepted row의 필수 ID 누락과 `isError=true`는 모두 0이다. 새 manifest
hash는 결과 summary에 기록했다.

## 근거

- [근거] exact committed source, Linux image/binary identity, authenticated schedule responses,
  complete debug refresh logs, durable row timestamps, 2026-08-31T01:43:22+09:00 확인,
  신뢰도 High.
- [근거] Hada 원문 및 위 논문/USENIX 1차 출처, 같은 시각 확인, 신뢰도 High.
