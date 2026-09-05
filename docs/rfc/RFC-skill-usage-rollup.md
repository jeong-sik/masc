---
rfc: "skill-usage-rollup"
title: "Skill 사용 롤업 — 세션횡단 활성화 집계를 CLI·TUI·대시보드에 표면화"
status: Draft
created: 2026-09-05
updated: 2026-09-05
author: claude
supersedes: []
superseded_by: null
related: ["skills-as-tools", "RFC-0411-skill-surface-costs-its-reference"]
---

# RFC: Skill 사용 롤업 (skill-usage-rollup)

## 0. Summary

masc 는 Skill 활성화 증거를 세션마다 durable 하게 남긴다
(`<base>/.masc/traces/<trace>/skill-activations.json`, 스키마
`masc.skill-activations/v5`, `Keeper_skill_activation_ledger`). 그런데 이 증거를
**세션을 가로질러 집계하는 경로가 없다.** 대시보드와 TUI 는
`Keeper_skill_activation_projection.resolve ~keeper_name` 으로 **그 keeper 의 현재
trace 하나**만 본다. 그 결과 운영자에게는 "어떤 Skill 이 얼마나 쓰이는가"가 보이지
않고, 실제로 517회(39세션) 활성화가 있음에도 "아무것도 안 쓰이는" 것처럼 보인다.

이 RFC 는 세션횡단 per-Skill 롤업을 정의하고, 그것을 CLI·TUI·대시보드 세 표면에서
같은 집계로 재사용한다.

## 1. 현재 상태 (실측)

- `Keeper_skill_activation_ledger.summarize : t -> summary` 는 **delivery 역학**
  (`skill_bodies_served`, `instruction_provider_deliveries`,
  `composition_invocations` …)을 **세션 단위**로 센다. **per-Skill 분해가 없다.**
- `activations : t -> activation list` 각 activation 은 `identity`
  (`source_id`/`package_id`/`name`), `invocation.kind`
  (`instruction`|`composition`), `delivery.runtime_id`, `activated_at` 를 갖는다.
  집계에 필요한 원자료는 여기 다 있다.
- 로딩은 trace 단위(`load_existing_read_only_from_root ~trace_id`)뿐이고,
  **retained trace 를 열거하는 함수가 없다.** 이것이 유일한 신규 배관이다.

## 2. 설계

### 2.1 롤업 자료구조

```
type skill_usage =
  { identity : Skill_reference.identity
  ; total : int
  ; instruction : int
  ; composition : int
  ; sessions : int          (* distinct trace 수 *)
  ; runtimes : string list  (* 정렬됨, distinct *)
  ; last_used : string      (* 최대 activated_at *)
  }

type usage_rollup =
  { total_activations : int
  ; sessions : int
  ; skills : skill_usage list      (* total 내림차순 *)
  ; installed_unused : string list (* 설치됐으나 활성화 0 *)
  }
```

### 2.2 집계 함수

`rollup : ownership_root:string -> (usage_rollup, store_error) result`

1. `ownership_root/.masc/traces/*` 를 열거해 trace_id 목록을 얻는다. (신규 —
   directory walk. producer(ledger writer)가 이 경로에 쓰므로 consumer 도 같은
   경로 해석을 공유한다.)
2. 각 trace 에 `load_existing_read_only_from_root` → `activations` →
   `identity` 로 grouping. 손상/미지 스키마 trace 는 건너뛴다(fail-open read,
   `strict_parse_no_default` 는 write 경계에서 이미 강제됨).
3. 설치 Skill 이름은 선언된 `[[skills.sources]]` 경로의 `SKILL.md` frontmatter
   `name` 에서 얻어 `installed_unused` 를 계산한다.

집계는 `stopgap` 스크립트(`scripts/skill-usage-stats.py`)와 **동일한 shape** 다.
스크립트는 이 OCaml 을 굽기 전의 검증된 레퍼런스이자, 저부하 운영 도구로 남는다.

### 2.3 세 표면

| 표면 | 소비 방식 |
|------|-----------|
| CLI | `masc skill-stats [--json]` — `rollup` 을 표/JSON 으로 출력 |
| TUI | Runtime 화면에 per-Skill 집계 패널(기존 `scoped_summary` 렌더 옆) |
| 대시보드 | `GET /api/v1/skills/usage` + 패널. 기존 keeper-chat inline 활성화는 유지 |

세 표면 모두 `rollup` **하나**를 부른다. 표면별 재집계 금지(SSOT).

## 3. 트레이드오프 / 미해결

- **retention**: trace 는 무한히 쌓인다. rollup 이 전부를 읽으면 O(traces).
  39개는 무료지만 수천이면? → 옵션: `--since`, 또는 스냅샷 캐시. 초판은 전량 읽고,
  느려지면 캐시를 별도 RFC 로.
- **trace 열거의 소유**: directory walk 를 rollup 모듈에 둘지, 공용 trace-store
  헬퍼로 뺄지. fleet discovery 가 이미 retained-trace root 를 pin 하므로, 그
  해석을 재사용한다(중복 경로 로직 금지).
- **`installed_unused` 의 신뢰도**: SKILL.md frontmatter 파싱은 카탈로그
  스냅샷(`Skill_catalog_snapshot`)을 재사용해야지, 별도 파서를 만들면 안 된다.

## 4. 단계

1. **(이 PR)** `scripts/skill-usage-stats.py` + 테스트 — 검증된 집계 레퍼런스.
2. `Keeper_skill_usage_rollup` 모듈 + fixture 테스트 + `masc skill-stats` CLI.
3. TUI Runtime 패널.
4. 대시보드 엔드포인트 + 패널.

각 단계는 이전 것의 `rollup` 을 재사용하고, 새 집계를 만들지 않는다.
