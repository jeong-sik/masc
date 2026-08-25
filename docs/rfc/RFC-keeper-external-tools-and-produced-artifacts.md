---
rfc: "keeper-external-tools-and-produced-artifacts"
title: "Keeper 외부 도구와 생성 이미지 증거를 선언형 계약으로 연결한다"
status: Draft
created: 2026-08-25
updated: 2026-08-25
author: codex
related: ["prompts-and-tool-definitions-outside-ocaml", "0389", "0390"]
implementation_prs: []
---

# RFC: Keeper 외부 도구와 생성 이미지 증거

## 0. 요약

Keeper가 외부 세계에 전혀 접근하지 못하는 것은 아니다. `Execute`와 official-client
native tool은 이미 프로세스와 네트워크 접근 경로를 제공한다. 지금 빠진 것은 접근
자체가 아니라 다음 두 계약이다.

1. Keeper가 로컬에서 만든 이미지를 `analyze_image`가 읽는 content-addressed handle로
   등록하는 계약
2. JIRA 같은 외부 서비스의 허용 operation, effect, Keeper tool group을 저장소가
   소유하는 선언형 계약

두 문제는 독립적으로 구현한다. Phase 1에서 이미지 증거 경로를 먼저 닫고, Phase 2에서
외부 서비스 adapter를 추가한다. 임의의 MCP server/tool 문자열을 받아 중계하는 범용
`Tool_mcp_call`은 도입하지 않는다.

## 1. 현재 경계

2026-08-25 `main`에서 다음을 다시 확인했다.

- `config/tools/<name>.toml`은 모델에 보이는 description과 input schema를 소유한다.
  `Tool_definition_toml`은 모르는 키를 부팅 오류로 거부한다.
- `Keeper_tool_descriptor.runtime_handler`와 `Keeper_tool_group.t`는 닫힌 합타입이고,
  handler에서 group으로 가는 match는 exhaustive하다.
- `Keeper_vision_ingest`는 대화로 들어온 이미지를
  `Keeper_vision_tool.store_artifact`로 저장한다. vision store는 살아 있는 경로다.
- `analyze_image`는 raw path가 아니라 그 store의 handle만 받는다. Keeper가 `Execute`로
  만든 파일을 같은 store에 넣는 공개 도구는 없다.
- 일반 검증 증거는 이미 `artifact:<producer-root-relative-path>`를 받는다. 따라서
  Phase 1은 모든 파일을 새 blob store에 복제하는 일이 아니라, 생성 이미지를 vision
  handle로 바꾸는 끊어진 한 구간만 다룬다.

## 2. Phase 1 — 생성 이미지 등록

새 atomic tool `keeper_image_register`를 추가한다.

```toml
name = "keeper_image_register"
description = "Register a locally produced image for analyze_image."
additional_properties = false

[[params]]
name = "path"
type = "string"
required = true

[[params]]
name = "cwd"
type = "string"

[[params]]
name = "media_type"
type = "string"
enum = ["image/png", "image/jpeg", "image/gif", "image/webp"]
```

성공 결과는 다음처럼 최소한의 영수증만 돌려준다.

```json
{"artifact":"<64-char-lowercase-sha256>","media_type":"image/png","bytes":178204}
```

### 2.1 실행 경로

구현은 기존 경계를 재사용한다.

1. `Keeper_tool_filesystem_runtime.resolve_read_file_target`으로 `cwd`와 `path`를
   해석하고 allowed-path 및 sandbox containment를 검사한다.
2. 현재 Read가 사용하는 backend-aware byte reader를 공용 내부 함수로 추출해 같은
   방식으로 파일을 읽는다. host path를 새 코드에서 직접 `open_in`하지 않는다.
3. `Keeper_vision_tool.validate_image_size`와 `media_type_for_request`로 크기와 형식을
   확인한다. `media_type`이 없으면 bytes에서 sniff한다.
4. `Keeper_vision_tool.store_artifact`를 keeper별 `vision_store_dir`에 호출하고 handle을
   반환한다.

이 도구는 source file을 바꾸지 않고 동일 bytes에 동일 handle을 돌려주는 idempotent
read-side operation이다. descriptor는 `Core_group`, `readonly = true`, `Atomic_tool`로
선언해 companion인 `analyze_image`와 같은 표면에 둔다. 내부 CAS write는 외부 세계를
바꾸는 effect로 분류하지 않는다.

### 2.2 명시적으로 하지 않는 것

- 일반 파일을 tool blob store로 복제하지 않는다. 검증용 파일 증거는 기존
  `artifact:` 계약을 사용한다.
- path를 곧바로 `analyze_image`에 넘기지 않는다. vision provider 경계는 계속 opaque
  handle만 받는다.
- vision store와 tool blob store를 합치지 않는다.

## 3. Phase 2 — 외부 서비스 도구 선언

외부 도구도 `config/tools/<name>.toml`이 description과 schema를 소유한다. 여기에
consumer가 생기는 구현 PR에서만 다음 닫힌 declaration을 연다.

```toml
name = "jira_issue_get"
description = "Read one JIRA issue by exact key."
group = "connector"

[external]
adapter = "atlassian"
operation = "get_issue"
effect = "network_read"
```

각 문자열은 그대로 dispatch key가 되지 않는다.

- `adapter`와 `operation`의 유효한 조합은 OCaml의 닫힌
  `external_operation` 합타입으로 decode한다. 예를 들어
  `Atlassian_get_issue | Atlassian_search_issues`처럼 operation마다 생성자가 있다.
- runtime descriptor는 `Tool_external_dispatch of external_operation`을 갖는다. 실행부는
  생성자를 exhaustive match하여 adapter 함수를 부른다. upstream MCP의 server/tool
  이름과 버전 차이는 adapter 모듈이 소유하고 모델 입력이나 범용 문자열 route로
  노출하지 않는다.
- `effect`는 `Network_read | Connector_post`의 닫힌 값으로 decode한다.
  `network_read`는 read gate를, `connector_post`는 exact approved payload와 one-shot
  소비 계약을 사용한다. 선언과 실제 gate가 다르면 부팅 또는 테스트에서 실패한다.
- `group = "connector"`는 `Keeper_tool_group.Connector_group`으로 decode한다. RFC-0389의
  `[keeper.tools].groups`가 이 그룹의 노출 여부를 결정한다. 모르는 group은 기존처럼
  profile load를 실패시킨다.

처음 허용할 operation은 read-only 두 개(`get_issue`, `search_issues`)로 제한한다.
issue 생성·수정은 `Connector_post` replay 계약과 payload 보존 테스트가 준비된 다음
별도 PR에서 연다.

### 3.1 official-client native posture와의 관계

외부 adapter tool은 MASC descriptor와 approval gate를 거치는 MASC tool이다.
RFC-0390의 `native = none | read | full`은 official client 자체 도구의 자세일 뿐,
connector group을 자동으로 켜거나 끄지 않는다.

- `native = read/full`이어도 `[keeper.tools].groups`에 `connector`가 없으면 adapter는
  모델 표면에 없다.
- native CLI나 브라우저로 실행한 외부 작업은 adapter 호출로 위장하지 않고 기존
  native provenance로 남는다.
- `native = none`이어도 connector group이 선언돼 있으면 MASC gate를 통해 adapter를
  사용할 수 있다.

## 4. 기각한 설계

### 4.1 임의 MCP relay

`Tool_mcp_call of { server : string; tool : string }`은 새 operation을 코드 변경 없이
붙이기 쉽다. 대신 compiler가 operation별 exhaustiveness를 보장하지 못하고, group과
effect가 runtime 문자열에 매달리며, upstream tool rename이 곧 Keeper contract drift가
된다. 현재의 닫힌 descriptor 및 TOML fail-closed 방향과 맞지 않아 기각한다.

### 4.2 MCP 서버 전체 자동 수입

서버 discovery 결과를 전부 모델 표면에 올리지 않는다. tool group, effect, 승인 정책을
저장소가 검토한 operation만 선언한다. 외부 서버의 도구 추가가 MASC 표면을 조용히
늘려서는 안 된다.

### 4.3 Execute 호출을 사후 분류

`Execute`는 argv를 실행하는 범용 경계다. command 문자열을 보고 JIRA read/write를
추론하지 않는다. typed connector가 필요한 operation은 descriptor로 제공하고, 그렇지
않은 CLI 사용은 Execute provenance로 남긴다.

## 5. 구현 순서와 검증

### Phase 1

1. `keeper_image_register.toml`과 descriptor/runtime wiring
2. backend-aware raw byte read helper 추출
3. 등록 → `analyze_image` 왕복 테스트

필수 테스트:

- allowed path 안 PNG 등록과 handle load 성공
- allowed path 밖, sandbox 밖, directory path 거부
- oversized image와 unsupported bytes의 typed 거부
- 동일 bytes 재등록 시 동일 handle
- source file 불변

### Phase 2

1. TOML loader에 `group`과 `[external]`을 consumer와 함께 추가
2. closed `external_operation` 및 `external_effect` decode
3. `Connector_group` surface/approval wiring
4. read-only Atlassian adapter 두 operation

필수 테스트:

- unknown adapter/operation/effect/group 부팅 거부
- declaration의 operation, effect, group과 descriptor가 1:1 일치
- read operation이 `network_read` gate만 통과하고 post gate를 타지 않음
- connector group 미선언 Keeper의 표면에서 제외
- native posture 변경이 connector 가시성을 바꾸지 않음
- 전체 및 축소 tool-surface byte ratchet 유지

Phase 1은 Phase 2에 의존하지 않는다. 생성 이미지 증거 경로가 검증되면 먼저 머지하고,
외부 adapter 설계가 지연돼도 그 가치를 보존한다.
