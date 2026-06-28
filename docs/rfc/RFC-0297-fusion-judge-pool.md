# RFC-0297: fusion judge pool — judge 모델을 preset에서 분리

| | |
|---|---|
| Status | Draft |
| Author | Claude (설계), Vincent |
| Related | RFC-0252 (panel+judge), RFC-0280 (validated preset), RFC-0283 (judge-of-judges), RFC-0273 (dashboard config) |
| Created | 2026-06-29 |

## 1. 배경 / 문제

현재 `[fusion.presets.NAME]`이 judge 구성을 **정적으로 carry**:
`[[fusion.presets.NAME.judges]]` sub-table이 `model` + `system_prompt`를 박는다 (RFC-0283).

- 모델을 바꾸려면 `runtime.toml`을 직접 편집 — 사실상 **하드코딩**.
- ollama_cloud catalog가 변동(모델 추가/삭제)해도 preset이 **stale**.
- 대시보드 settings UI에서 preset 편집 불가 (RFC-0273 foundation은 있으나 폼 미배선).

RFC-0283의 topology(judge_of_judges / staged_judge_of_judges)는 코드에 구현됐으나, preset이 정적이라 실사용이 제한된다.

## 2. 목표

- **G1**: judge 모델을 preset에서 분리 → `[fusion.judge_pools.*]`.
- **G2**: pool은 (a) **capability 자동 추림** 또는 (b) **명시 list** — 둘 다.
- **G3**: keeper가 fusion tool에 `judge_pool` / `judge_count` param으로 **runtime 배치**.
- **G4**: 대시보드 settings에서 pool/preset 편집 (RFC-0273 확장).
- **G5**: staged depth cap — 설계는 열되 노출 ≤ 3.

## 3. 설계

### 3.1 judge_pool config

```toml
[fusion.judge_pools.cloud_json]
# (a) capability filter (동적): catalog 변동 자동 반영
provider   = "ollama_cloud"
require    = ["supports-response-format-json", "supports-reasoning-budget"]
exclude    = ["ministral-*", "gemma3:*"]   # glob; 너무 가벼운 모델 제외
limit      = 6

# (b) 명시 list (점진적 옵트인): 위 filter를 override
# models = ["ollama_cloud.X", "ollama_cloud.Y", ...]
```

- `models`가 있으면 **list mode**(고정), 없으면 **capability mode**(동적).
- capability mode는 `provider` 필수. list mode는 `models` 필수.

### 3.2 pool resolve 알고리즘

입력: pool spec + runtime config.

1. provider의 routed runtime_ids: `[ollama_cloud.<key>]` keys → `ollama_cloud.<key>`.
2. 각 runtime_id의 capabilities:
   - routing(`[ollama_cloud.<key>]`) → `api-name` → `[models.<api-name>.capabilities]`.
   - `supports-*` flag.
3. `require` **모두** 만족 + `exclude` glob에 안 걸림.
4. deterministic 정렬(정의 순서) 후 `limit`까지.
5. 결과: judge 후보 runtime_ids.

**경계**:
- 빈 결과 → **fail-fast** (preset 사용 시 명시 에러. silent fallback 금지).
- capability source가 없는 모델 → require 미충족으로 간주(제외).

### 3.3 preset 연동

```toml
[fusion.presets.staged_joj]
panel            = [...]
judge            = "deepseek.deepseek-v4-pro"   # meta-judge (reducer)
judge_pool       = "cloud_json"                 # ← pool 참조 (model list 아님)
topology         = "staged_judge_of_judges"
staged_max_depth = 3
# judge_system_prompt: preset 기본 하나 (judge마다 박지 않음)
```

- `judge_pool`과 기존 `[[...judges]]`는 **상호 배타**. 둘 다 있으면 에러.
- judge_spec의 `system_prompt`는 preset의 `judge_system_prompt` 상속. `label`은 model에서 derive.

### 3.4 keeper runtime 배치 (fusion tool param)

`masc_fusion_schema`에 추가:
- `judge_pool` — pool override (없으면 preset의 pool).
- `judge_count` — 이번 run judge 수 (pool에서 N개 샘플).

keeper가 상황에 맞게 배치. (기존 `preset`/`topology` param은 유지.)

### 3.5 stage cap

`staged_max_depth` (preset, default 3). topology=staged 시 depth ≤ cap. 초과 시 fail-fast. 설계는 더 깊이 허용하되 노출 상한 3.

### 3.6 UI (RFC-0273 확장)

settings editor에 pool/preset 편집 폼:
- pool: `provider`/`require`/`exclude`/`limit` 또는 `models`.
- preset: `panel`/`judge`/`judge_pool`/`topology`.

config ↔ UI 양방향. runtime.toml이 SSOT.

## 4. capability 매핑 (구현 핵심)

```
ollama_cloud.<key>            (runtime_id = fusion model id)
  → [ollama_cloud.<key>]      (routing)
  → api-name
  → [models.<api-name>.capabilities]
  → supports-response-format-json / supports-reasoning-budget / ...
```

- `Runtime_schema`/`Runtime_toml`이 이미 routing + capabilities를 carry.
- fusion pool resolve는 **이를 소비**만 한다 (새 capability source 발명 안 함, SSOT).

## 5. 호환 / 마이그레이션

- 기존 `[[...judges]]` (RFC-0283) **backward compat**: `judge_pool`이 없으면 list를 그대로 사용.
- trio(단일 judge)는 영향 없음.
- `staged_max_depth` 미설정 시 legacy(무제한) 또는 default 3 — 본문 결정.

## 6. 검증

- pool resolve 단위 test (capability filter / exclude glob / limit / 빈 결과 fail-fast).
- list mode test.
- preset `judge_pool` vs `[[...judges]]` 상호배타 test.
- keeper param(`judge_pool`/`judge_count`) test.
- 카나리(RFC-0252 §11): keeper-driven staged run으로 종합 품질 사후 판단.

## 7. 단계 (PR 분리)

1. `[fusion.judge_pools.*]` config 스키마 + `fusion_policy` pool type + resolve(catalog↔capability).
2. preset `judge_pool` 참조 + topology만 carry(model list 제거) + 기존 `judges` compat.
3. fusion tool `judge_pool`/`judge_count` param + keeper 배치.
4. settings editor pool/preset 폼(UI).

## 8. 비판 / 리스크

- **capability 매핑 복잡**: routing ↔ capabilities. 구현이 Runtime_schema에 강결합.
- **pool 빈 결과**: fail-fast가 맞지만, 운영자가 require를 너무 빡빽히 두면 항상 빈 pool → preset 사용 불가. require 기본값 신중.
- **keeper param 남용**: `judge_count`가 너무 크면 비용 폭증. 상한(cap) 필요.
- **설계-코드 갭**: 이 RFC는 설계. 실제 topology dispatch(orchestrator)와 pool resolve의 결합점을 구현 시 검증.
