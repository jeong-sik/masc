# 관측 유실 클래스 — 외부 리뷰 원문 (2026-10-28~29)

RFC-0477의 근거 원문. 동일 브리핑(`brief.md`)을 5회 별도로 실행해 모은 답변이다.
원문 그대로 보존하며, 출력 노이즈(실행 헤더·token 집계)도 남긴다.

| 파일 | 실행 경로 | 실제 모델 |
|---|---|---|
| brief.md | — | 질문 원문. 최초 판정(단일 ⊇ 불변식 + round-trip 의무) 포함 |
| review-1-codex-gpt.md | codex-cli 0.165.0 | GPT 계열 Codex. 저장소 파일 직독(131k tokens) |
| review-2-claude-slot-glm-routed.md | `claude -p --model opus` | 세션 환경 상속으로 GLM 라우팅. 헤더의 `unrecognized_model: glm-5.3[1m]` 경로 근거 |
| review-3-claude-slot-glm-routed.md | `claude -p --model fable` | 위와 같음. 두 실행은 사실상 같은 기저 모델 |
| review-4-anthropic-opus.md | env 정리 후 `claude -p --model opus` | Anthropic Opus. 헤더 경고 없음 |
| review-5-anthropic-fable.md | env 정리 후 `claude -p --model fable` | Anthropic Fable. #46595·#46589·#46599 인용은 gh PR 확인으로 검증(2026-10-29, 전부 OPEN) |

집계: 별도 실행 5건 모두 최초 판정의 ⊇ 불변식을 기각. 두 실행은 같은 GLM 기저 모델이므로 5개 서로 다른 모델의 의견은 아니다. RFC-0477 §7에 기각 사유 요약,
본 디렉터리에 원문.


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
