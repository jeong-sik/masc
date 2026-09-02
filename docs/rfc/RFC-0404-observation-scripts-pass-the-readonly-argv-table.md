---
rfc: "0404"
title: 관측 script 는 readonly argv 테이블을 탄다 — 메타문자 없는 단일 명령 문자열은 argv 와 동치로 판별한다
status: Draft
created: 2026-09-03
updated: 2026-09-03
author: Claude Opus 5 (1M context)
supersedes: []
superseded_by: null
related: ["0335"]
---

## 0. 한 줄 요약

관측 전용 fast path(`Keeper_gate_readonly`)는 이미 넓은 명령 테이블을 갖고 있지만
argv 배열 형식만 판별한다. Keeper 들은 관측 조회를 셸 문자열(`script`)로 발행해서
전부 판정 모델을 통과한다. 셸 프리미티브가 없는 단일 명령 문자열은 argv와 동치이므로,
그 형태만 split 해 기존 테이블로 판별한다.

## 1. 문제 — 실측 (2026-09-02)

`audit-approvals/2026-09/02.jsonl` 전체 696건 승인의 pending→resolved 분해:

| 구간 | p50 | p90 |
|---|---|---|
| pending → 요약 완료 (큐 + 컨텍스트 수집) | 2초 | 54초 |
| 요약 → 판정 (judge 모델 호출) | **61초** | 136초 |

- 병목은 큐가 아니라 판정 모델 호출 자체다. judge 구간의 동시 진행 분포는
  1~8건으로 이미 병렬로 돈다. 하루 696건 × 61초 ≈ judge 모델 시간 11.8시간분.
- 도구별: `tool_execute` 602건(86%), `identity_call` 85건, 나머지 소수.
- deliveries 샘플 434건의 script 를 쓰기-명령 부재 기준으로 분류하면
  **읽기 398건(92%), 쓰기 36건(8%)**. 관측 성격의 실행이 심사 대상의 대부분이다.

읽기 예시(전부 `script` 문자열):

```
ls /home/keeper/playground/polisher/
uname -a && id && pwd && cat /proc/uptime
git -C repos/masc status
```

`Keeper_gate_readonly.observation_commands` 는 `ls`, `cat`, `grep`, `uname`,
`git status/diff/log/show` 등 이미 이 명령들을 포함한다. 못 잡는 이유는 형식
하나다 — `classify_argv` 는 argv 배열만 받고, 배열은 "exec shim 이 셸 없이
직접 exec" 이라는 안전 전제 위에 있다. 문자열로 오면 원리적으로 판별 대상이
아니어서 판정 모델로 간다.

### 사건 (2026-09-03 00:46, pr-updater)

사용자가 "도착 안했으면 다른 할일 없어?" 라고 물었을 때 keeper 는 올바르게
대답하고 행동했다 — 자기 메모리의 교훈("폴링 대신 다른 작업")을 인용하고 즉시
`gh pr list` 조회를 `script` 형식으로 발행했다. 그 관측 조회가 게이트에서
판정 대기 180초 타임아웃으로 죽었고, keeper 의 대안 행동까지 소멸했다.
"Keeper 가 아무것도 안 한다"로 보인 것은 이 타임아웃의 자국이다.
승인 1건(appr_01a062cc-0579)은 같은 창에 세 Keeper 의 승인이 몰려 판정에
202초 걸렸고 배달은 owner busy 로 60초 더 밀렸다.

## 2. 제안

`Keeper_gate_readonly` 에 문자열→argv 동치 판별을 추가한다. 조건을 전부 만족하는
`script` 문자열만 대상이다:

1. 개행이 없다 (정확히 한 줄).
2. 닫힌 메타 문자 집합에 속한 문자가 하나도 없다:
   `; | & > < $ ` \ ( ) { } * ? ~ # ' "`.
3. 공백으로 split 했을 때 argv[0]이 경로가 아닌 bare name이다 (기존 규칙과 동일 —
   `/bin/rm` 따위는 매치되지 않는다).

이 세 조건을 통과한 문자열의 split 결과는 셸이 개입할 여지가 없는 argv와
동치다. 인용부가 없으므로 공백 split이 곧 파싱이고, 전개·치환·리다이렉트·파이프를
만들 수 있는 문자가 하나도 없다. split 결과를 기존 `classify_argv` 에 그대로
태운다 — 명령 테이블의 단일 정의는 유지되고, 새 판별 계층은 "문자열이 이 동치
형식인가"의 닫힌 집합 검사 하나다.

동치 판별을 통과하지 못하는 script(인용부가 필요한 인자, 파이프, 조합 명령)는
지금처럼 판정 모델로 간다. 이 제안은 심사를 건너뛰는 게 아니라, 이미 안전하다고
합의된 명령 집합이 형식 때문에 못 들어오는 구멍을 닫는 것이다.

### gh 는 이 RFC 의 범위 밖이다

`gh pr list` 류는 네트워크를 나가고 GitHub 자격증명을 실은 채로 나간다. 그 성격은
`network_read`(web_fetch 계열)이지 로컬 관측이 아니다. `observation_commands` 에
`gh` 를 추가하는 논의는 별도 안으로 미룬다. 이 RFC 를 적용하면 pr-updater 사건의
조회도 여전히 심사를 통과한다 — 그 사건의 교훈은 별개로 판정 모델 latency(§4)가
진다.

## 3. 측정 계획

배포 24시간 뒤:

- `tool_execute` 승인 건수: 602건/일 기준, 읽기 성격 92% 중 동치 형식 통과가
  얼마인지 (인용부 없는 단일 명령 비중에 따라 50~90% 예상).
- 판정 모델 호출 시간 총량과 pending→resolved p50 (71초) 의 변화.
- 동치 판별 통과 목록 샘플 audit — 우회 시도(허위 bare name)가 등장하는지.
  등장해도 그냥 심사로 떨어질 뿐이다.

## 4. 별개 이슈로 남는 것 — 판정 모델 latency

judge 슬롯(`glm-coding.glm-5.3-flash` 1,820 / `deepseek-v4-flash` 760)의
호출 p50 61초가 이 RFC 적용 후에도 남는 심사의 지연을 결정한다. 동시성은 이미
있다(1~8 병렬). 대안은 판정 전용 슬롯의 모델 교체(실측 사례: 같은 기간
deepseek 계열이 유의하게 짧았다)이며, 이는 이 RFC 와 독립적인 운영 결정이다.

## 5. 위험과 반론

- **동치 판별의 우회**: 메타 문자 없이 bare name 관측 명령을 흉내 낸
  이상한 바이너리는 존재하지 않는다 — argv[0] bare name 은 PATH 조회 결과고,
  게스트 안 PATH 는 통제된다. 관측 테이블 밖 명령은 split 후 기존 판별에서
  그대로 떨어진다.
- **문자 분류기 아니냐**: 이 판별은 "셸 프리미티브 문자 집합의 부재"라는
  닫힌 검사이고, 통과한 문자열의 의미는 argv 와 수학적으로 동치다. 단어를
  걸어 맞추는 heuristic 이 아니다.
- **quote 없는 인자만 된다**: 공백 포함 인자(`-m "fix: ..."`)는 동치 밖이다.
  관측 조회는 quote 를 거의 안 쓰므로 커버율 손실은 감수한다. 심사로 가면
  지금과 같다 — 퇴행이 아니다.
