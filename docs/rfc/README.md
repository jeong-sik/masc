# RFCs — masc

이 디렉터리는 MASC의 설계 제안과 결정 기록을 보관한다. 현재 개발 규칙은 [헌장](../constitution.xml)과 [기여 가이드](../guides/CONTRIBUTOR-WORKFLOW.ko.md)에서 확인한다.

## 정책

- **파일명**: 신규 RFC 는 `RFC-<slug>.md` (예: `RFC-keeper-background-wait-tool.md`). slug 는 소문자/숫자/하이픈이다.
- **수명**: RFC는 진행 중인 제안만 둔다. 구현이 끝났거나, 다른 RFC로 대체됐거나, 하지 않기로 한 RFC는 지운다. 결정은 코드와 헌장에, 경위는 git 기록에 남는다.
- **삭제 정합성**: RFC 파일을 삭제할 때는 frontmatter 관계, 본문 cross-reference를 같은 변경에서 함께 정리한다.
- **Multi-phase RFC**: 한 설계를 여러 문서로 나눌 때는 같은 slug prefix를 사용하고 본문에서 현재 main spec을 직접 참조한다.
- **인덱스 조회**: `python3 scripts/rfc-generate-index.py` 가 frontmatter 로부터 색인 표를 생성해 stdout 에 출력한다 (표는 커밋하지 않는다 — #35498). `--check` 로 파일명, RFC 식별자와 번호 중복을 확인한다.

## Frontmatter 표준 (신규 RFC 부터 강제)

새 RFC 는 본문 1번째 `#` 헤더 위에 다음 YAML frontmatter 를 둔다.

```yaml
---
rfc: "keeper-background-wait-tool" # 파일명의 slug와 일치
title: "Short Imperative Title"
status: Draft                      # 생성 인덱스에 표시할 현재 상태
created: 2026-05-12                # ISO date
updated: 2026-05-12                # 본문 의미 변경 시 갱신, typo 수정은 생략 가능
author: <github-handle 또는 vincent>
related: []                        # 직접 참조하는 현재 RFC slug. 없으면 빈 배열
---
```

### Status 정의

| 값 | 의미 |
|---|---|
| `Draft` | 작성 중. 본문/PR 변경 가능. 구현 시작 전 또는 spec 합의 미완. |
| `Active` | spec 머지 완료, 구현이 진행 중인 RFC. 일부 Phase 가 main 에 들어갔으나 전체 closeout 미완. |
| `Implemented` | 모든 Phase 가 main 에 머지 완료. 명시적 `docs(rfc): ... closeout` commit 또는 본문 *Implementation summary* 섹션이 있어야 한다. |
| `Superseded` | 다른 RFC 가 이 자리를 대신한다. `superseded_by` 에 그 slug 를 적는다 — 비워두면 읽는 사람이 대신할 것을 찾을 데가 없다. |
| `Dropped` | 하지 않기로 했다. 본문에 왜인지 적는다. 대신할 것이 없으므로 `superseded_by` 는 비운다. |

`Dropped` 가 있어야 하는 이유: 이 값이 없으면 포기한 RFC 가 `Draft` 로 남는다.
`Draft` 는 "아직 안 썼다" 이고 포기는 "안 쓴다" 인데, 인덱스에서 둘이 같은
글자로 보인다. 2026-08-25 에 그 혼동으로 계획 하나가 잘못 쓰였다 — 살아있는
RFC 를 죽은 것으로 읽었고, 되돌리는 데 한 라운드가 들었다.

## RFC 목록

색인 표는 커밋하지 않는다. 커밋돼 있을 때는 모든 RFC PR 이 표 맨 끝 같은
자리에 행을 붙여 동시에 열린 RFC 들이 쌍마다 충돌했다 (#35498 — 일곱 RFC
전 쌍 충돌, 해소에 순차 리베이스 6회). 표는 frontmatter 와 제목에서 결정적으로
생성되므로 읽는 시점에 만들고, 병합 방식에 따라 바뀌는 commit SHA 나 날짜는
싣지 않는다.

```
python3 scripts/rfc-generate-index.py
```

`--check` 는 파일명과 `rfc:`의 일치, 번호가 붙은 하위 문서의 부모 관계, 번호 중복을
확인한다. RFC를 지울 때는 본문 링크와 frontmatter의 관계 필드도 함께 확인한다.

### 신규 RFC

신규 RFC 는 번호를 발급받지 않는다 (번호 allocator 제거됨 — 전역 카운터 TOCTOU 회피). 의미 있는 slug 파일명 `RFC-<slug>.md` 로 작성한다. 생성되는 색인 표는 기존 번호 RFC 와 신규 slug RFC 를 함께 싣는다.

## 검색 / 발견

- 단일 RFC: `cat docs/rfc/RFC-NNNN-*.md`
- 키워드 검색: `rg <keyword> docs/rfc/`
- 색인 표: `python3 scripts/rfc-generate-index.py` (frontmatter 에서 생성, 커밋되지 않음). 최근 활동은 해당 RFC 파일의 `git log`로 확인
