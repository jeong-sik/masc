# Skills — SKILL.md 로 능력을 선언한다

masc 의 스킬은 파일 하나로 선언되는 능력이다. `runtime.toml`의 `[[skills.sources]]`가
가리키는 `<source>/<name>/SKILL.md` 한 장이 스킬 하나다. 기본 source는 프로젝트와 사용자
각각의 `.masc/skills`, `.agents/skills`다. Keeper 턴과 `/api/v1/skills`는 같은 발행
스냅샷을 새로 고쳐 읽으므로 source 우선순위·shadow·거부 결과가 서로 갈리지 않는다.

관련 이슈: `#30156` skills-declared-not-discovered (task 라우팅). 파서는
`packages/agent_core/lib/skill_document.ml` (frontmatter 계약) + `lib/keeper/keeper_skill_catalog.ml` (카탈로그)다.

런타임에서 **어떻게 도는가**(순서도 + 코드 경로)는 `docs/SKILLS-FLOW.md`.

### Memory에서 Skill을 만드는 경로의 현재 상태

Librarian이 남기는 `validated_approach`·`lesson`과 `absorbs`는 Memory OS의 Fact를
바꾼다. SKILL.md를 발행하지 않는다. 현재 Skill은 선언된 source의
파일을 읽어 발행하며, Dashboard의 생성·저장은 `CanAdmin` 편집기 API를 쓴다
(`Server_skill_editor`, `Server_routes_http_routes_skills`). Keeper는
`keeper_skill_publish`로 새 Skill을 직접 발행한다(아래).

Keeper는 새 `SKILL.md`를 `keeper_artifact_transfer`로 export한 뒤, 반환된
`artifact` sha256과 제안하는 package 디렉터리 이름 `package_id`를
`keeper_skill_validate`에 전달할 수 있다. 기존 문서 parser와
편집기의 크기 제한으로 원문 bytes를 읽기 전용 검증한다. 결과의 artifact와
package 이름은 검증한 입력을 가리키며, 발행된 Skill Reference가 아니다.
정적 검증은 실행 성공이나 안전성을 증명하지 않고 source·snapshot도 변경하지
않는다.

Keeper는 `keeper_skill_publish`로 새 package를 직접 발행한다.
`package_id`, `SKILL.md` 전체인 `source_text`, 비어 있지 않은 `evidence` 목록을 받는다.
쓰는 곳은 `project-agents` source 하나로 정해져 있고 Keeper가 고르지 못한다.
편집기 `create`와 같은 parser로 검증하고, `project-agents`에 이미 있는 package는
`package_already_exists`로 거절하며 덮어쓰지 않는다. 쓴 뒤 catalog snapshot을 다시
발행하므로 다음 턴이 돌려받은 Skill Reference로 찾는다. 단 meta 에 `skills` 목록을
선언한 Keeper 는 그 목록에 이름이 있을 때만 본다(`Keeper_skill_catalog.project_turn ~names`).
catalog 순서에서 앞선 package(보통 먼저 선언된 source 의 것)가 같은 이름을 선언하면
그 Skill 이 이기고 새 package 는 가려진다(shadow). 이때 결과는 `created_but_shadowed`
이고 `winner` 가 이긴 package 를 가리킨다. Keeper 턴은 이름으로 Skill 목록을 만들어서
`winner` 를 본다. 새 package 는 파일과 catalog 에 남고, Task 가 그 정확한 reference 를
지명할 때만 턴에 들어간다.
쓰기 완료 또는 결과 불명일 때 감사 원장에 Keeper 이름, 정확한 참조 또는 시도한
package, `evidence`를 담은 `skill_write` 행을 시도한다.
도구 결과의 `audit_status`가 `audit_call_returned`이면 감사 호출이 반환한 것이고,
`unconfirmed`이면 예외가 나서 행이 쓰였는지 알 수 없다. 전자는 행의 내구성을
보장하지 않는다. 두 값 모두 Skill 쓰기와 감사 기록의 원자성을 뜻하지 않으며,
예외·취소·프로세스 중단 뒤 감사 행이 없을 수 있다. 감사 상태와 별도로 반환된
발행 상태와 정확한 참조를 확인한다. `evidence`의 참 여부는 판정하지 않는다.
삭제는 운영자의 편집기 DELETE 경로로 한다.

실행 기록에서 후보를 찾고 검증해 발행하는
[Tool Librarian 제안](https://github.com/jeong-sik/masc/pull/36925)은 구현된 자동
생산 경로가 아니다. 발행된 Skill의 사용 기록은 그 Skill이 자동으로
생성됐거나 작업을 성공시켰다는 증거와 구분한다.

## 1. 파일 규칙

```markdown
---
name: release-checklist
description: Walk the release checklist before shipping.
---

# Release checklist

1. Read the diff.
2. Check CI.
```

- Agent Skills 표준상 `name`과 `description`은 필수이고 `name`은 디렉토리 이름과
  같아야 한다. 이름 누락·불일치·문법 오류, 필드 길이 초과, 알 수 없는 top-level field,
  잘못된 metadata 값은 그 Skill 하나를 거부한다. 클라이언트 확장은 공식 `metadata`
  string map 아래에 둔다.
- Agent Skills의 실험적 선택 필드 `allowed-tools`는 문법만 검증하고 즉시 버린다.
  MASC에서는 사전 승인이나 도구 제한이 아니며 AST, registry, prompt, Gate, Keeper
  effective surface, immutable snapshot entry 어디에도 값이 남지 않는다. 실행 권한의
  권위는 MASC 승인 정책이다. 이식 가능한 원본 `SKILL.md`와 편집기 source round-trip은
  원문을 그대로 보여 주지만 정책 상태로 해석하지 않는다.
- frontmatter가 잘못된 스킬은 snapshot에서 거부된다. Task가 해소할 수 없는 exact
  reference를 지명하면 admission이 typed 오류를 반환한다.
- 본문은 frozen snapshot bytes로 보존된다. Keeper는 `keeper_skill`에 canonical exact
  reference를 전달해 본문을 받는다.

## 2. Skill 로 둘 것과 Tool 로 둘 것

| 필요한 것 | 둘 곳 |
|---|---|
| 없는 능력 / 스키마·권한·typed 오류 계약 / 외부 호출 | Tool |
| 갈림길 판단·함정·절차 | Instruction skill |
| 런타임이 턴의 첫 요청에 이미 넣는 정보 (예: 현재 시각은 `[Temporal]` 로 들어간다. 도구 결과 뒤 요청에는 다시 넣지 않는다) | 두지 않는다 |
| 도구·하네스 결함을 피해 가는 절차 | 스킬로 만들지 않고 결함을 고친다 |

- 결함을 피해 가는 절차를 스킬로 적으면 그 결함이 일하는 방법으로 굳고, 다음 작성자가
  그대로 따라 쓴다. 도구를 고치면 절차가 필요 없어진다.

작성 절차 전체는 빌트인 `skill-authoring` 스킬에 있다.

## 3. Keeper별 Skill 표면과 지시 스킬

Keeper별 Skill 표면은 Keeper profile의 `[keeper.skills]`가 정한다.

```toml
[keeper.skills]
names = ["release-checklist", "memory-probe"]
```

- `[keeper.skills]`가 없으면 발행된 모든 Skill을 쓴다.
- `names = []`면 Skill을 하나도 싣지 않는다.
- 이름은 canonical Skill 이름과 정확히 같아야 한다. 부분 문자열, 대소문자 보정, 별칭은 없다.
- 같은 선택을 전역 Skill과 Task가 지명한 Skill에 모두 적용하므로 Task가 Keeper profile을
  우회하지 않는다.
- 설정에만 있고 발행된 turn catalog에는 없는 이름은 effective surface의
  `unavailable_skill_names`에 typed reason과 함께 남는다. 함께 지정한 알려진 이름은 계속
  동작한다.

`masc_keeper_up`의 `skills.names`도 같은 Keeper TOML 필드를 편집한다. `skills={}`는
선언을 지워서 all로 되돌리고 빈 배열은 none을 유지한다.

### 지시 스킬 (instruction)

task 가 스킬을 지정하면 current-task 블록에 이름 한 줄이 실리고, keeper 가
`keeper_skill` 도구로 본문을 연다. 지정이 없는 task 의 프롬프트는 바이트 하나 변하지 않는다.

keeper 가 task 를 둘 이상 들고 있으면(Claimed/InProgress) current task 는 reconcile 이
고른 하나이고, 두 번째 task 를 claim 해도 바뀌지 않는다. 그래서 나머지 보유 task 가
지명한 스킬은 `Skills Named by Tasks You Hold` 블록에 task 별로 한 줄씩 따로 실린다
(직접 메시지 턴도 같다). 턴 admission도 같은 집합의 이름이 카탈로그에 있는지 검사한다.
지시 본문은 전용 `keeper_skill`이 서빙하므로 파일시스템 `Read` 도구 유무와는 무관하다.

### 발견 → 읽기

이름을 모르면 `keeper_capability_search` 로 작업에 맞는 이름과 설명을 검색한다.
검색은 해당 턴의 고정된 카탈로그를 대상으로 하며, 도구를 로드하거나 실행하지 않는다.
`availability` 와 설명을 읽고, 실행 가능한 결과의 `invocation_name` 을 사용한다.
이름을 이미 알면 검색을 거치지 않아도 된다.

기본 검색은 입력 전체를 하나의 literal phrase로 찾는다. 하이픈이 있는 이름도
`{"query":"browser-live-follow-read"}`처럼 그대로 넘긴다. 따옴표나 `OR`도 검색할
텍스트로 취급하며, 단어 경계와 순위는 SQLite tokenizer가 정한다.

대안·접두어·컬럼 조건 같은 FTS5 검색식은 `syntax`를 명시한다. 예를 들어
`{"query":"browser OR screenshot","syntax":"fts5"}`는 두 단어 중 하나를 찾는다.
명시한 검색식이 잘못되면 오류로 반환하며 literal 검색으로 자동 재시도하지 않는다.
의미 검색이나 자동 번역은 하지 않으므로 결과가 없으면 작업에 맞는 다른 단어를 시도한다.

검색 결과의 `reference.identity` 를 `keeper_skill` 의 `identity` 인자로
넘겨 본문을 읽는다(Task/Goal 검증 에이전트도 `keeper_skill` 로 `evidence-review` 같은 지시
스킬을 읽는다). revision 을 고정할 때는 `reference.content_revision` 을 선택 인자
`content_revision` 으로 넘긴다. `reference` 라는 인자는 없다.

## 4. 오류는 그 스킬만 격리한다

Agent Skills frontmatter 계약을 어긴 문서와 중복 스킬은 그 source candidate를 typed
rejection으로 격리한다. 해당 Skill을 Task가 지명한 턴만 admission 오류를 받고, 올바른
형제 Skill은 계속 사용할 수 있다. `SKILL.md`가 없는 디렉토리는 스킬이 아니므로 그냥
건너뛴다.

## 5. 관측

- `GET /api/v1/skills` — 발행 스냅샷의 valid entry와 typed rejection을 돌려준다.
- document rejection은 안정적인 diagnostic `code`와 사람용 `message`를 함께 내보낸다.
  Monitor › Skills는 valid Skill이 하나도 없어도 source candidate별 code를 표시하며,
  message 문자열을 재파싱해 상태를 추측하지 않는다.
