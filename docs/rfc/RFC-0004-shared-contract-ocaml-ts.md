# RFC-0004: OCaml ↔ TypeScript shared contract — SSE + gRPC-web

**Status**: Draft
**Date**: 2026-04-17
**Scope**: masc-mcp OCaml server ↔ dashboard TypeScript contract boundary; SSE event stream, gRPC surface
**One sentence**: masc-mcp 의 두 contract 표면(SSE, gRPC) 중 SSE 에는 atd 기반 OCaml→JSON Schema→Zod AST 파이프라인으로 SSOT 를 도입하고, gRPC 는 dashboard 소비 경로(Connect-RPC 또는 gRPC-web)를 여는 thin slice 로 시작한다.

## Related Documents

- `../../proto/masc.proto` — gRPC 표면 기존 SSOT
- `../../scripts/gen-grpc-descriptors.sh` — drift 검증 선례
- PR #7955 — Zod SSE parse boundary (런타임 validation 진입)
- PR #7952 — `Lockfree_atomic` helper module (이 RFC 와 독립, 참고용)
- `../KEEPER-USER-MANUAL.md` — OAS pin 히스토리

## Status Note

이 문서는 구현 승인 전 합의용 RFC다.

- 이 RFC 가 승인되기 전에는 코드 변경을 진행하지 않는다 (한 가지 예외: PR #7955 로 이미 착지한 수동 Zod schema 는 유지)
- Track A 와 Track B 는 독립 PR 로 진행
- Track B 의 Phase B0 는 **인프라 결정 사전 RFC** 로 별도 투표

## Design Anchors

이 RFC 는 아래 앵커를 "직접 구현 명령"이 아니라 설계 방향을 정하는 참고 축으로 사용한다.

- "Parse, don't validate" (Alexis King) — Zod/atdgen 이 강제하는 boundary pattern
- **"빡센 타입"** (사용자 피드백) — `as SSEEvent` 캐스트 제거, discriminated union, closed enum 우선
- "No invented abstractions" (auto-memory) — `.atd` 및 Buf 토olchain 은 검증된 업계 표준만 채택. custom ppx 는 atdgen 실패 시 fallback
- Alan Dipert / Rich Hickey — complexity ≠ capability. contract SSOT 도입으로 "drift 없는 코드" 라는 capability 를 얻되, 새 DSL(atd) 이 complexity 를 더하는 trade-off 를 인지
- CloudEvents v1.0 (CNCF) — 장기적 envelope 표준 후보. 본 RFC 는 **미채택**, 별도 migration RFC 로 분리

## Context

masc-mcp contract 표면은 두 갈래:

1. **gRPC 표면 (proto SSOT)** — `proto/masc.proto` (249 lines) 정의, `ocaml-protoc-plugin` 으로 OCaml AST 변환. `lib/grpc/masc_grpc_server.ml` 이 port **8936 h2c** (HTTP/2 cleartext, `grpc-direct` Eio-native) 로 listen 중. gRPC Reflection v1/v1alpha 지원. `scripts/gen-grpc-descriptors.sh` 가 drift 검증. **서버는 실제로 돌고 있다**. 하지만 dashboard 는 이 표면을 **아직 소비하지 않는다** — 브라우저는 h2c 를 쓸 수 없고 (TLS + HTTP/2 native 필수, 안정 API 없음), Connect-RPC / gRPC-web 어느 쪽도 서버에 추가되지 않았기 때문.
2. **SSE/Dashboard 표면 (hand-rolled)** — OCaml emitter 가 `Yojson` ad-hoc 생성, dashboard `dashboard/src/types/sse.ts` 가 60+ `SSEEventType` 리터럴 union 수동 유지. PR #7955 로 Zod runtime parse 게이트 확보했지만 정의의 SSOT 부재.

이 RFC 는 두 표면 모두 cover 한다 — **Track A** 는 SSE 표면에 AST SSOT 도입, **Track B** 는 dashboard 에 gRPC 소비 경로 열기. 두 트랙은 상호 독립이므로 PR 단위 분리해서 진행.

**핵심 realization**: `ppx_deriving_yojson` 생태계 + `ocaml-protoc-plugin` + Reflection 이 이미 있으므로, 필요한 건 "추가 인프라"가 아니라 **기존 OCaml AST pipeline 을 브라우저까지 연장**하는 일이다.

## Track A — SSE 표면 (atd SSOT → OCaml types + JSON Schema + atdts)

### Phase A0 — SSE 이벤트 타입화 (선행)

현재 `lib/sse.ml` 은 `Yojson.Safe.t` 를 ad-hoc 조립한다. 정형 타입이 없으므로 codegen 을 붙일 수 없다.

**범위 실측** — dashboard 가 소비하는 60+ `SSEEventType` 리터럴 중:
- masc-mcp 자체 emit: 약 **40개** (`agent_*`, `keeper_*`, `board_*`, `approval_*`, `room_*`, `transport_*`, `execution_*` 등)
- **OAS bridge relay**: **21개** (`oas:*` 접두어) — `agent_sdk` 라이브러리의 `Event_bus.payload` variant 를 `lib/oas_sse_bridge.ml` 이 릴레이

**OAS 21 이벤트 처리 — Opaque passthrough 채택**:

`Sse_event` variant 에 `| Oas of { envelope : oas_envelope; data : Yojson.Safe.t }` 하나로 입목. JSON Schema 에서 data 는 `{"type":"object"}` 로 열어둠.

이점:
- cross-repo 협업 없이 masc-mcp 단독 진행 가능
- agent_sdk 쪽에 ppx 추가는 장기 옵션 (별도 upstream PR)
- OAS 이벤트 타입 자체는 dashboard 에서 여전히 검증 (envelope 포함)

**Envelope 구조 (CloudEvents 미채택, 현 shape 유지 기반)**:

```atd
type oas_envelope = {
  correlation_id : string;
  run_id : string;
  ts : float;
}

type sse_event = [
  | Agent_joined of agent_joined_payload
  | Keeper_heartbeat of keeper_heartbeat_payload
  | Oas of oas_event_wrapper  (* ~ opaque *)
  | ...
] <json adapter.ocaml="Sse_event_adapter">
```

`<json adapter>` 가 variant tag 를 `{"type":"agent_joined", ...fields}` 형태로 flatten. `masc/board_post`, `oas:turn_completed` 등 특수 문자는 adapter 내부에서 OCaml constructor (`Masc_board_post`) ↔ wire string (`"masc/board_post"`) 매핑.

**emit 경로 교체 전략**:
- Phase A0 은 도메인별 sub-PR (agent_*, keeper_*, oas_*, board_*) 분할 가능 — 각 sub-PR 은 **byte-equal golden test** 로 기존 emit 동일성 보장
- 기존 `lib/sse.ml` 의 ad-hoc ``Yojson.Safe.t`` 조립 사이트는 `grep -c "` + `\`Assoc"` `lib/sse.ml` 로 추적. 각 site 별 `Sse_event.to_yojson` 호출로 교체
- **실질 작업량의 70% 차지**. 결과적으로 OCaml 쪽도 타입 안전 (오타 event name, 필드 누락이 컴파일 타임에 잡힘)

### Phase A1 — atd SSOT 도입 + schema gen

**Primary 도구**: **atdgen** (Mjambon, 10년+ 유지, 성숙).

이유:
- `.atd` 파일 하나로 **OCaml types + JSON Schema + atdts (TS types)** 한 번에 생성
- `<json adapter.ocaml="...">` 로 variant wire format 완전 통제 (discriminator 형태 `{"type":"...","...":"..."}` 지원)
- **ppx_deriving_jsonschema** (ahrefs v0.0.5, 2026-03) 는 variant 를 기본적으로 `["Constructor", args]` 배열 렌더 → SSE wire format 에 어댑터 필요하므로 **부적합**. ahrefs 자체 프로덕션 사용처도 OpenAI tool calling (record 중심) 에 국한
- `proto/masc.proto` 가 이미 별도 IR SSOT 도입 전례라서 `.atd` 추가 일관성 유지

**Fallback**: atdgen 의 `<json adapter>` 로 SSE 60+ variant adapter 매핑이 예상보다 무거우면 custom ppx (~100 LOC) 로 pivot.

작업:
- `schemas/sse_event.atd` (신규 SSOT)
- `dune` 규칙으로 atdgen 호출 → `lib/sse_event_t.ml` (types), `lib/sse_event_j.ml` (JSON codec) 자동 생성
- `docs/schemas/sse.schema.json` (atdgen `-t` 출력, 커밋)
- Phase A0 의 `lib/sse_event.ml(i)` 는 이제 **atdgen 생성물을 re-export** 하는 얇은 모듈 + wire adapter 정의

### Phase A2 — TS types + Zod

두 산출물 동시 생성:

- **atdts 로 TS types**: atdgen 이 `.atd` 에서 TypeScript types 직접 생성 (`atdts` 모드). 출력: `dashboard/src/schemas/sse_event_t.ts`.
- **JSON Schema → Zod**: `docs/schemas/sse.schema.json` 을 `json-schema-to-zod` 로 변환. 출력: `dashboard/src/schemas/sse.generated.ts`.
- PR #7955 의 `dashboard/src/schemas/sse.ts` 는 유지 — generated import 로 교체하고 **수동 레이어** 만 남긴다 (`SSEEnvelope` wrapper, `parseSSEMessage`, `SSESchemaDriftError`).
- `dashboard/scripts/gen-sse-schema.mjs`: JSON Schema → Zod 변환 실행.
- dev dep: `json-schema-to-zod`.

### Phase A3 — CI drift check

- `scripts/verify-sse-contract.sh`: 재생성 후 diff 없어야 pass.
- 실패 시 메시지: `Run scripts/regenerate-sse-contract.sh and commit`.

## Track B — gRPC 소비 경로 dashboard 에 열기

### Phase B0 — 서버측 프로토콜 결정 (R&D, no code)

현재 OCaml 서버는 pure gRPC over h2c (binary proto on HTTP/2). 브라우저 client 가 쓰려면:

| 선택지 | 서버 필요 작업 | 브라우저 필요 작업 | 평가 |
|-------|-------------|-------------------|------|
| **gRPC-web** | Envoy proxy (서버 앞 인프라) 추가 | `@bufbuild/protoc-gen-es` + grpc-web client | 프록시 운영 부담, 표준 |
| **Connect-RPC** | OCaml 서버에 Connect protocol dispatcher (JSON over HTTP/1.1 POST) 추가 — OCaml Connect 라이브러리 없음, 핸드롤 필요 | `@connectrpc/connect-web` | 서버 핸드롤 부담, 브라우저 인프라 없음 |
| **BFF via HTTP** | 기존 HTTP 엔드포인트가 내부적으로 gRPC 호출 | 기존 fetch 그대로 | gRPC 의미 희석 |

**Phase B0 결정 사항 (별도 RFC 로 분리 가능)**: OCaml 서버에 **Connect-RPC dispatcher 핸드롤** vs **Envoy proxy 도입** 중 하나. POC 결과에 따라 결정. 구현 전에 이 결정 필수.

### Phase B1 — TS gRPC codegen 파이프라인

- 대상 toolchain: **`@bufbuild/protoc-gen-es` + `@bufbuild/protoc-gen-connect-es`** (Buf 생태계, 모던, tree-shake 친화)
- `buf.gen.yaml` 추가 (레포 루트 또는 dashboard/)
- 출력: `dashboard/src/grpc/masc_pb.ts` (messages), `dashboard/src/grpc/masc_connect.ts` (client stubs)
- `proto/masc.proto` 수정될 때마다 양쪽(OCaml + TS) 재생성 필수 — 기존 `scripts/gen-grpc-descriptors.sh` 에 TS codegen 단계 추가

### Phase B2 — 대표 RPC 1개를 dashboard 에서 소비 (thin slice)

- 후보: `GetStatus` (부작용 없음, 인증 불필요, 가장 가벼움)
- `dashboard/src/api/grpc-status.ts`: Connect client 로 `GetStatus` 호출
- 기존 HTTP `/api/v1/...` 와 **병행** — 전면 교체 아님

**⚠️ 서버 측 실질 규모 (honest 표기)**

B0 결정에 따라 둘 중 하나:

(a) **Connect-RPC dispatcher 핸드롤** — `lib/grpc/connect_dispatcher.ml` 신규 모듈. HTTP/1.1 POST + JSON(또는 proto binary) 파싱, proto ↔ OCaml record 변환, error protocol, streaming (SSE-style) 지원. **실질 신규 서버 모듈 1개, 500-1500 LOC 추정**. 기존 `grpc-direct` (HTTP/2 binary) 와 병행 운영. OCaml Connect 라이브러리 없어서 수제. 정치적 무게: *중*, 유지보수 부담: *중상*.

(b) **Envoy proxy** — 서버 앞에 Envoy 컨테이너 1대. 설정 YAML. **코드 작성 없음, 운영 인프라 추가**. 배포 환경에 Envoy 삽입. 정치적 무게: *중* (인프라 합의 필요), 유지보수 부담: *저* (Envoy 자체는 성숙).

둘 다 "단순 한 줄 추가" 가 아니라 **새 서버 컴포넌트 혹은 인프라 리라이트급 결정**. RFC 에서 이 사실을 숨기지 않는다.

### Phase B3 — drift CI

- `buf breaking` 로 proto API 호환성 체크 (`buf.yaml` 필요)
- `proto/masc.proto` 변경 시 양쪽 generated 파일 diff 없어야 함을 CI 검증

## Sequencing

두 트랙은 독립. Track A 가 먼저 머지되는 게 덜 정치적 (SSE 는 이미 PR #7955 로 진입 기반 있음, gRPC-web 은 인프라 결정 필요).

**Track A 흐름**
1. PR A0 — `schemas/sse_event.atd` 초안 + Phase A0 도메인별 점진 emit 교체 (가장 큰 PR)
2. PR A1 — atdgen dune wiring + `docs/schemas/sse.schema.json` 최초 생성
3. PR A2 — TS codegen + `sse.generated.ts`
4. PR A3 — CI drift gate

**Track B 흐름**
1. PR B0 — protocol decision RFC 문서 (코드 없음)
2. PR B1 — buf toolchain + TS codegen (dashboard 에 generated 파일만, 소비 없음)
3. PR B2 — Connect dispatcher OR Envoy infra + `GetStatus` thin slice
4. PR B3 — proto drift CI

## Verification

### Track A Phase A1
```bash
dune exec scripts/gen_sse_schema.exe > /tmp/sse.schema.json
diff /tmp/sse.schema.json docs/schemas/sse.schema.json   # empty expected
jq '.definitions | keys | length' docs/schemas/sse.schema.json  # ≥ 60
```

### Track A Phase A2
```bash
cd dashboard
pnpm run gen:sse-schema
git diff --exit-code src/schemas/sse.generated.ts
pnpm typecheck
pnpm test src/schemas/sse.test.ts
```

### Track A Phase A3 — drift 실험
1. `schemas/sse_event.atd` 에 필드 추가 → `verify-sse-contract.sh` exit 1
2. `regenerate-sse-contract.sh` 실행 → 양쪽 파일 업데이트
3. 재실행 → exit 0

### Track B Phase B1
```bash
buf generate
git diff --exit-code dashboard/src/grpc/
cd dashboard && pnpm typecheck
```

### Track B Phase B2
```bash
# 서버 기동 후
cd dashboard && pnpm dev
# 브라우저 DevTools: GetStatus 호출이 200 + proto parsed
```

## Risks

| 리스크 | 완화 |
|-------|------|
| `atdgen` 의 `<json adapter>` 가 variant wire format 을 예상대로 커스터마이즈 못하면 | POC 단계에서 SSE 3-5 variant 샘플 먼저 검증. 실패 시 custom ppx 로 pivot (fallback 확보됨) |
| OCaml variant → JSON Schema discriminated union 매핑 | JSON Schema `oneOf` + `const` 필드. `AttributionOutcome` (PR #7955) 이 참조 구현 |
| Connect-RPC OCaml 서버 핸드롤 코스트 큼 | Phase B0 결정 사항. Envoy proxy 대안 허용 — 인프라 편입 부담 vs 핸드롤 부담 비교 후 선택 |
| gRPC-web / Connect 번들 사이즈 증가 | tree-shake 확인 (`@bufbuild/protoc-gen-es` 는 작음). Track B 는 Track A 와 독립이므로 크기 문제 있으면 보류 가능 |
| generated 파일 커밋 noise | `linguist-generated=true` 로 PR review 에서 접힘. **부작용**: 리뷰어가 generated diff 을 안 봐서 실제 SSOT 변경이 묻힐 수 있음. 완화: PR 설명에 "SSOT diff 는 `.atd` 만 읽으면 됨" 명시 + golden test 자동 회귀 방지 |
| Track B 범위가 결국 infrastructure 변경 (Envoy) 로 확장되면 정치적 리스크 | B0 에서 명시적으로 결정 멈춤 — 코드 작성 전 결정 문서부터 |
| CI drift check 이 Phase A3/B3 에서야 도입되어 그 전 PR 들이 drift 에 무방비 | PR A0 에서 **임시 check**: `atdgen` 재생성 결과 repo 와 동일해야 한다는 bash one-liner 스크립트 하나 추가. A3 에서 정식 CI job 으로 대체 |
| `.atd` 로 새 DSL 도입 = 팀 러닝 커브 | atd 문법 매우 작음 (레코드 / variant / list / option). `docs/atd-primer.md` 에 짧은 튜토리얼 첨부 가능 |

## 기대 효용 & 수치

### Track A (SSE SSOT) — 측정 가능 수치

| 항목 | 현재 값 | Track A 완료 후 (기대) | 측정 방법 |
|-----|---------|---------------------|----------|
| `dashboard/src/types/sse.ts` 수동 LOC | 318 | ~100 (envelope + adapter 만 수동) | `wc -l` |
| OCaml SSE emit 타입 안전도 | 0% (ad-hoc `Yojson.Safe.t`) | 100% (compile-time field check) | `rg "` + `\`Assoc"` `lib/sse.ml` = 0 |
| OCaml emit site 수 | ~40 (추정, Phase A0 `grep -c` 실측) | 0 | 같은 grep |
| Dashboard per-variant 필드 검증 | 0 필드 strict (envelope level 만) | 60+ variant × 평균 3-5 필드 = **~200 필드 runtime checked** | Zod discriminatedUnion 크기 |
| CI drift gate | **없음** | 100% | `verify-sse-contract.sh` exit 0 |
| 런타임 성능 영향 | — | **0 추가** (`safeParse` 는 #7955 에서 이미 부담, strict 화는 동일 O(fields)) | bench 불요 |
| 번들 사이즈 영향 | — | **~5-10KB gzipped** (60+ variant schemas) | `pnpm build` 후 `stat` |
| 빌드 시간 영향 | — | atdgen 1-3s (proto 5s 와 비슷한 order) | `time dune build` |

**측정 불가한 효용 (honest)**:
- "drift 버그 감소 건수" — 과거 incident 로그 없음. 예방적 가치만 주장 가능
- "개발 속도 개선" — RFC 로 인한 속도 변화 수치화 불가. 단 "새 event type 추가 시 수동 동기화 공수" 가 `.atd` 한 곳으로 축소되는 건 명확
- "dashboard 사용자 영향" — 내부 툴이라 지표 없음

### Track B (gRPC thin slice) — 측정 가능 수치

| 항목 | 현재 HTTP+Valibot | Track B thin slice (GetStatus) | 측정 방법 |
|-----|-----------------|-----------------------------|----------|
| GetStatus payload 크기 | ~2-3KB JSON | ~0.5-1KB proto binary | DevTools Network |
| GetStatus 응답 시간 (local) | 20-50ms | 5-15ms (기대) | 위 동일 |
| GetStatus 응답 시간 (cross-zone) | ~50-150ms | ~30-80ms (Envoy 선택 시 +proxy hop) | prod 측정 |
| 번들 사이즈 영향 | — | +~40-60KB gzipped | `pnpm build` |
| Dashboard 엔드포인트 관련 수동 LOC | ~50 LOC × 20 endpoints = **1000 LOC** (fetch + Valibot schema) | thin slice 만: ~10 LOC | 전면 전환 시 ~80% 감소 가능성 (이 RFC 범위 아님) |

**주의 (honest)**:
- Track B 의 latency 이점은 대시보드 UX 에 거의 안 보임. SSE 스트림이 실시간이고 RPC 는 병목 아님. Latency 개선은 side effect, **contract enforcement + 타입 안전** 이 주된 이점
- Envoy 선택 시 local 환경 GetStatus 가 **오히려 느려질 수도** (+0.5-2ms proxy hop). cross-zone 에선 proto binary 가 이김
- 번들 사이즈 40-60KB = 현재 dashboard 1MB+ 의 4-6% 증가
- **Track B "해야 할 이유"는 미래 가치**: contract 단일화, 새 RPC 추가 시 수동 schema 작성 제거, proto breaking CI. 단기 수치 이점 작음

### 이 RFC 를 **안 하면** 벌어질 일 (reactive cost)

| 사건 | 현재 환경에서의 대응 비용 |
|-----|----------------------|
| 서버가 SSE event 에 필드 추가, dashboard 는 수동 업데이트 누락 | UI 에 값 안 보임. 리뷰어가 코드만 보고 놓침. 사용자 제보 → 디버그 → PR (1-4h) |
| 서버가 event name 변경 | 런타임 event drop. #7955 로 인해 warn 찍히지만 조용히 유실 |
| 새 OAS 이벤트 추가 시 dashboard subscribe 누락 | 동일 — silent drop |
| proto 수정했는데 OCaml generated 만 갱신, TS side 수동 업데이트 누락 | 컴파일 에러 없이 런타임 mismatch |

수치화: 위 사건 **1회당 1-4 개발자시간**. 이 RFC 는 그 cost 를 0 에 가깝게 만든다.

## Out of scope

- Valibot → Zod 전면 이전 (`api/schemas/` 수동 유지)
- SSE 외 wire format (stdout journal, webhook 등)
- gRPC 서버측 프로토콜 전환 (h2c → Connect 네이티브 등 — Phase B0 결정에 따라 일부 다룰 수 있음)
- `lib/attribution.mli` 이외 기존 mli SSOT 문서의 코드젠화
- proto 에 SSE event 60+ 를 추가하는 것 (도메인 misfit — 이미 제외)
- CloudEvents v1.0 envelope 전환 (별도 migration RFC)
- agent_sdk 라이브러리에 `[@@deriving jsonschema]` 추가 요청 (cross-repo PR 별도 트래킹)

## References

### OCaml ecosystem
- [atdgen — OCaml support docs](https://atd.readthedocs.io/en/latest/atdgen.html) — atd DSL 및 JSON Schema 출력 모드
- [atdgen-runtime 2.15.0 CHANGES](https://ocaml.org/p/atdgen-runtime/latest/CHANGES.md.html) — 최신 릴리즈 활동
- [ppx_deriving_jsonschema (ahrefs)](https://github.com/ahrefs/ppx_deriving_jsonschema) — v0.0.5 (2026-03-10), variant 기본 배열 렌더
- [opam: ppx_deriving_jsonschema](https://opam.ocaml.org/packages/ppx_deriving_jsonschema/)
- [ocaml-openai-demo (ahrefs)](https://github.com/ahrefs/ocaml-openai-demo) — production 사용 사례 (record 중심, variant 없음)
- [ppx_deriving_yojson](https://github.com/ocaml-ppx/ppx_deriving_yojson) — 기존 프로젝트 의존성

### TypeScript / dashboard toolchain
- `@bufbuild/protoc-gen-es`, `@connectrpc/connect-web` — Buf 생태계 gRPC-web / Connect-RPC 도구 (미도입)
- `json-schema-to-zod` — npm 변환 도구

### Industry patterns
- CloudEvents v1.0 (CNCF) — envelope 표준, 미채택
- Connect-RPC (Buf) — HTTP/1.1 기반 gRPC 대안 프로토콜

### Internal prior art
- `proto/masc.proto` — 기존 gRPC SSOT
- `scripts/gen-grpc-descriptors.sh` — drift 검증 스크립트 선례
- PR #7955 — dashboard Zod SSE boundary
- `lib/attribution.mli` — OCaml SSOT + TS mirror 수동 패턴
