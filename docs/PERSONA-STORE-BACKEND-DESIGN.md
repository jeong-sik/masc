# Persona Store Backend Design

## Goal

filesystem 기반 `config/personas/<name>/profile.json` 의존성을 줄이고, 웹/원격 배포에서도 일관되게 쓸 수 있는 DB/API 기반 persona store를 도입한다.

## Current State

- persona blueprint는 서버 로컬 파일시스템에서 읽는다.
- keeper 생성 시 persona는 resolved args로 복사되고, 이후 live state는 `.masc/perpetual-keepers/<name>.json`에 쌓인다.
- 웹 대시보드는 persona 파일을 직접 읽지 않고 서버가 해석한 결과만 사용한다.

이 구조는 로컬 개발에는 단순하지만, 멀티 인스턴스 배포와 웹 기반 운영에는 약점이 있다.

## Problems

1. persona 변경이 배포 단위와 결합된다.
2. 여러 서버 인스턴스가 같은 persona 집합을 공유하기 어렵다.
3. persona audit, versioning, publish/review workflow가 git checkout 상태에 과하게 의존한다.
4. 원격 웹 운영자가 persona를 바꿔도 서버 파일시스템 접근이 필요하다.

## Proposed Model

persona store를 3계층으로 나눈다.

1. `Persona_source`
   - `Filesystem`
   - `HTTP API`
   - `Database`

2. `Persona_registry`
   - `get(name)`
   - `list()`
   - `get_version(name)`
   - `resolve_defaults(name)` for keeper bootstrap

3. `Persona_cache`
   - TTL 기반 read-through cache
   - etag/version 기반 revalidation
   - last-known-good fallback

서버의 keeper 생성 경로는 더 이상 직접 파일을 읽지 않고 `Persona_registry`만 호출한다.

## Data Model

단일 persona record는 최소 아래 필드를 가진다.

```json
{
  "name": "sangsu",
  "display_name": "상수",
  "profile": { "role": "...", "trait": "...", "tone": [] },
  "keeper": {
    "goal": "...",
    "short_goal": "...",
    "mid_goal": "...",
    "long_goal": "...",
    "instructions": "...",
    "soul_profile": "relationship",
    "mention_targets": ["sangsu", "상수"]
  },
  "version": "2026-03-27T00:00:00Z",
  "updated_at": "2026-03-27T00:00:00Z",
  "source": "api"
}
```

## API Shape

읽기 전용 최소 API:

```text
GET /api/v1/personas
GET /api/v1/personas/{name}
GET /api/v1/personas/{name}/version
```

운영 API:

```text
POST /api/v1/personas
PUT /api/v1/personas/{name}
POST /api/v1/personas/{name}/publish
```

서버 내부 contract:

```ocaml
module type Persona_store = sig
  val get : string -> (persona_summary option, string) result
  val get_defaults : string -> (keeper_profile_defaults option, string) result
  val list : unit -> (persona_summary list, string) result
  val version : string -> (string option, string) result
end
```

## Resolution Order

전환 초기에는 read path를 단계적으로 바꾼다.

```text
explicit override
> HTTP/API persona store
> DB replica/cache
> filesystem fallback
```

이렇게 하면 기존 `profile.json` 자산을 바로 버리지 않고 migration 기간 동안 fallback으로 유지할 수 있다.

## Keeper Compatibility

- `masc_keeper_create_from_persona`는 유지한다.
- 입력은 동일하게 `persona_name`을 받되, 내부 lookup만 `Persona_registry`로 교체한다.
- 생성된 keeper meta에는 `persona_name`, `persona_version`, `persona_source`를 기록한다.
- `keeper_up(name)` 재생성 시에도 같은 registry를 통해 최신 blueprint를 다시 resolve한다.

## Runtime Guarantees

1. persona lookup 실패 시 기존 live keeper는 계속 동작해야 한다.
2. 새 keeper 생성만 실패시키고, 에러에 source/version 정보를 포함한다.
3. network/API 장애 시 last-known-good cache를 사용할 수 있어야 한다.
4. dashboard는 resolved source (`filesystem`, `api`, `db-cache`)를 표시해야 한다.

## Rollout Plan

1. `Persona_registry` abstraction 추가
2. filesystem loader를 registry backend로 감싸기
3. dashboard/config-resolution에 persona source/version 노출
4. API-backed backend 추가
5. keeper meta에 `persona_version`, `persona_source` 저장
6. 운영 플래그로 filesystem-only 모드 제거

## Open Questions

1. persona 편집 권한을 누구에게 줄지
2. publish 전 draft/review 상태를 별도 둘지
3. GraphQL 기존 agent identity와 persona store를 통합할지 분리할지
4. voice config 같은 민감/벤더 종속 필드를 같은 store에 둘지

## Recommendation

단기적으로는 `MASC_CONFIG_DIR` / `MASC_PERSONAS_DIR` 외부화를 유지하고, 중기적으로 `Persona_registry + API backend`를 도입하는 게 가장 안전하다. filesystem fallback을 남겨두면 기존 keeper bootstrap 흐름을 깨지 않고 웹/원격 운영 요구를 흡수할 수 있다.
