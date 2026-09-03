---
rfc: "tool-results-age-out-of-context"
title: "도구 결과는 만든 턴에서만 원문이다 — 컴팩션을 걷어낸 뒤 남은 누적을 닫는다"
status: Draft
created: 2026-09-03
updated: 2026-09-03
author: claude
supersedes: []
superseded_by: null
related: []
implementation_prs: []
---

# RFC: 도구 결과는 만든 턴에서만 원문이다

## 배경

컴팩션은 2026-08 에 숙청됐다(#31666 계열, #31698·#31791·#31809). 실행기·관측·
SSE 봉투·Grafana 패널·문서까지 0건이다. 컨텍스트를 사후에 줄이는 장치가 없다는
뜻이고, 그 자체는 결정이다.

문제는 그 결정 이전에 정해진 값들이 아직 "누적은 나중에 정리된다"를 전제한다는
것이다. `max_agent_core_inline_result_bytes = 65_536` 의 주석이 그 전제를 그대로
말한다 — "This bounds context growth rather than avoiding a spill". 한 결과당
상한이지 누적 상한이 아니다.

## 측정 (sangsu, trace-1788310783624-00004, 2026-09-03)

체크포인트 7,488,862 B / 3,834 메시지.

| 역할 | 바이트 | 비중 | 개수 |
|---|---|---|---|
| tool | 3,031,526 | 59.4% | 1,750 |
| assistant | 2,006,993 | 39.3% | 1,779 |
| user | 63,465 | 1.2% | 305 |

도구 결과가 지배항이고, 그 안에서 분포가 극단적이다.

```
p50 = 204 B      p90 = 2,685 B      max = 71,785 B
16KB 초과: 50개 (2.9%) 가 tool 전체의 54.9%
16–64KB 구간: 45개, 1,315,928 B, 중앙값 26,323 B
```

**1,750개 중 45개가 도구 결과의 43%를 차지한다.** 그 45개는 CLI 레인 상한
(16KB)은 넘고 agent-core 상한(64KB)은 안 넘어 인라인으로 남은 것들이다. 종류는
`artifact_read` 페이지가 아닌 것 39개, 웹 검색 11개.

## 무엇이 틀렸나

64KB 상한 자체가 아니다. 그 값의 근거는 측정에 서 있다 — 16KB 로 낮추면 3일에
491개 결과가 blob 이 되고, 그건 "같은 턴이 만든 결과를 그 턴이 다시 가져오는"
왕복이다.

틀린 것은 **원문을 언제까지 들고 있느냐에 대한 답이 없다**는 것이다. 지금은
"영원히"다. 만든 턴에서 왕복이 아까운 것과, 200턴 뒤에도 26KB 를 지고 가는 것은
다른 질문인데 값 하나가 둘 다 답하고 있다.

## 제안

도구 결과에 수명을 준다. 만든 턴에서는 인라인 원문, 그 턴이 끝나면 blob 참조.

- 생성 턴: 지금과 동일. 모델이 바로 읽고 왕복이 없다.
- 이후 턴: `Tool_output.Stored` 마커. 필요하면 artifact 라우트로 읽는다.
- 임계값은 그대로 64KB. 바뀌는 것은 상한이 아니라 보존 기간이다.

blob 저장과 마커 인코딩은 이미 있다(`Tool_blob_store`, `Tool_bridge`,
`Tool_output.encode_for_agent_core`). 새로 만드는 것은 "턴 경계에서 지난 결과를
마커로 교체" 하나다.

## 이것이 컴팩션이 아닌 이유

컴팩션은 무엇을 버릴지 고르는 판단이었고, 그래서 걷어냈다. 이 제안은 판단하지
않는다 — 원문은 사라지지 않고 blob 에 그대로 있으며, 컨텍스트에는 같은 내용을
가리키는 참조가 남는다. 대상은 "오래된 것"이 아니라 "이 턴이 만들지 않은 것"이고,
그 경계는 시간이 아니라 턴이다.

## 열린 질문

1. 마커로 바꾼 결과를 모델이 실제로 되읽는 빈도. 높으면 왕복을 뒤로 미룬 것뿐이다.
2. 16KB 미만 결과(1,700개, 1.37MB)는 그대로 둘 것인가. 개별로는 작지만 합은 크다.
3. assistant 메시지 2MB(39.3%)는 이 RFC 범위 밖이다. 그중 일부는 accept 가 거부한
   응답이었고 #32817 이 닫았다. 나머지의 성격은 따로 측정해야 한다.

## 측정 재현

```
python3 - <<'PY'
import json, pathlib, statistics
msgs = json.loads(pathlib.Path("<checkpoint>.json").read_text())["messages"]
tool = sorted((len(json.dumps(m, ensure_ascii=False))
               for m in msgs if m.get("role") == "tool"), reverse=True)
print(sum(tool), len(tool), statistics.median(tool))
print(sum(t for t in tool if t > 16384))
PY
```
