# 관측 유실 클래스 — 외부 리뷰 원문 (2026-10-28~29)

RFC-0478(처음에는 RFC-0477)의 근거 원문. 동일 브리핑(`brief.md`)에 대한 응답 5건을 보존한다.
원문과 출력 노이즈(실행 헤더·token 집계)도 남긴다. 아래 호출 경로는 최초 README의
기록이며, 이 묶음에 실제 완료 응답의 provider/model 영수증은 없다.

| 파일 | 기록된 요청·경로 | 원문에 보이는 한계 |
|---|---|---|
| brief.md | — | 질문 원문. 최초 판정(단일 ⊇ 불변식 + round-trip 의무) 포함 |
| review-1-codex-gpt.md | codex-cli 0.165.0으로 기록 | 저장소 조회 출력과 응답이 있다. 실제 응답 provider/model은 이 묶음에서 확인하지 못했다 |
| review-2-claude-slot-glm-routed.md | `claude -p --model opus`로 기록 | `unrecognized_model` 경고에 `glm-5.3[1m]`가 표시됐다. 실제 응답 provider/model은 미확인 |
| review-3-claude-slot-glm-routed.md | `claude -p --model fable`로 기록 | 같은 모델명 경고가 표시됐다. 실제 응답 provider/model은 미확인 |
| review-4-anthropic-opus.md | 환경 정리 후 `claude -p --model opus`로 기록 | 경고가 없는 것만으로 실제 응답 provider/model을 확인할 수 없다 |
| review-5-anthropic-fable.md | 환경 정리 후 `claude -p --model fable`로 기록 | 실제 응답 provider/model은 미확인. #46595·#46589·#46599는 2026-10-29 조회 당시 OPEN으로 기록됨 |

응답 5건은 모두 최초 안의 보완이 필요하다고 지적했지만, review-3은 재유도 계열의
`⊇` 검사를 유지하면서 별도 불변식을 추가하자고 했다. 5건이 `⊇` 자체를 모두
기각했다거나 서로 다른 모델 5개의 의견이라고 셀 수 없다. RFC-0478 §7에 요약하고,
이 디렉터리에 원문을 둔다.

## 2026-10-30 재현 가능한 후보 탐색

기준은 PR 최초 base `3fd6e38bd224f55f7901095c563637d4cf8b01fa`의 도달 가능한
최신 500 커밋이다. 작성 당시 29/202 집계의 기준 커밋·정규식·목록은 확인하지 못했으므로
아래는 그 수를 재현한 결과가 아니다. commit subject만으로 fix 표본과 키워드 후보를
정하고, 생성된 [후보 48건](candidates-3fd6e38.tsv)을 보존한다. `#46065`의 내비게이션
배치처럼 이 RFC의 보존 클래스가 아닌 후보도 들어가고, 키워드가 다른 사례는 빠진다.
수작업 분류·기능 분석·발생률 추정은 하지 않았다.

```bash
git log -500 --format='%H%x09%s' 3fd6e38bd224f55f7901095c563637d4cf8b01fa | python3 -c '
import re, sys
rows = [line.rstrip("\n").split("\t", 1) for line in sys.stdin]
fixes = [row for row in rows if re.search(r"\bfix(?:\([^)]*\))?!?:", row[1], re.I)]
candidates = [row for row in fixes if re.search(r"\b(retain|retains|retained|preserve|preserves|preserved|keep|keeps|kept)\b", row[1], re.I)]
print(f"commits={len(rows)} fix_subjects={len(fixes)} keyword_candidates={len(candidates)}")
for sha, subject in candidates:
    print(f"{sha}\t{subject}")
'
```

관측값은 `commits=500 fix_subjects=177 keyword_candidates=48`이다. 목록의 순서는
위 `git log` 순서다. 원래 집계의 모집단과 분류 기준이 확인되기 전까지 두 값을 비교해
추세로 해석하지 않는다.
