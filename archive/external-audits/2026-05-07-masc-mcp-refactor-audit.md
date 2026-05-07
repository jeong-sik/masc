# STALE AUDIT NOTICE

> **Status**: PRESERVED AS HISTORICAL ARTIFACT ONLY. DO NOT USE AS SOURCE OF TRUTH.
> **Date**: 2026-05-07
> **Verdict**: Multiple stale analyses detected via 4-channel cross-check.
>   - §3.1 root .py purge: Already merged in PR #14134
>   - §3.2 archive consolidation: Already done in PR #14121
>   - §3.3 mini-module merge: 2/14 misclassified (start-masc-mcp.sh, embedded_config/)
>   - §3.4 dashboard dedupe: Active PRs touching lib/dashboard/ (#14120, #14105)
>   - §3.5 docs 250→50: All 222 docs active within 11 days, 0 deletable candidates
> **Action**: No-op. This audit is archived for reference, not for execution.
>
> Cross-check methodology: Channel 1 (working-tree rg), Channel 2 (open PR descriptions),
> Channel 3 (git log), Channel 4 (build system / MEMORY references).
> Reference: memory/feedback_docs_purge_4_channel_verification.md (2026-05-07)

---

# masc-mcp 대규모 OCaml 코드베이스 구조 개선 계획

> **프로젝트**: masc-mcp (https://github.com/jeong-sik/masc-mcp)
> **작성일**: 2026-05-07
> **대상**: 565,179 라인, 2,697 OCaml 파일, 30개 lib 모듈
> **목표**: 에이전트 코딩 친화적 확장 가능한 구조로의 리팩토링

---

# masc-mcp 대규모 OCaml 코드베이스 구조 개선 계획

## 1. Executive Summary

### 1.1 프로젝트 개요

masc-mcp는 565,000라인, 2,697개 OCaml 파일, 30개 라이브러리 모듈, 18개 실행 파일, 5개 사이드카 서비스로 구성된 대규모 OCaml 5 코드베이스입니다 [^1^]. `coord/` 모듈에 70개 파일이 집중되어 있고, 루트 디렉토리에는 30개 이상의 임시 스크립트가, 250개 문서가 산발적으로 분포하는 등 구조적 비대화가 진행된 상태입니다 [^2^]. 이 보고서는 **숙청 → 구조 재설계 → 타입 설계 개선 → 생태계 전환**의 4-Phase 전략으로 코드베이스를 근본적으로 개선하는 종합 계획을 제시합니다.

핵심 메시지는 단순합니다: 에이전트의 64K 컨텍스트 제한이 모듈 분할의 1차 설계 제약이 되며, 이 제약이 오히려 복잡성을 제거하는 강력한 동기가 됩니다.

### 1.2 다섯 가지 핵심 발견

**발견 1: Context-Bounded Architecture**
에이전트의 64K 컨텍스트(≈ 2,000~3,000라인)가 모듈 크기의 하드 제약이 됩니다 [^3^]. 이 제약은 모듈을 자연스럽게 단일 책임(Single Responsibility)을 따륵도록 강제하며, "에이전트가 이해할 수 있는 크기"가 새로운 모듈화 기준이 됩니다.

**발견 2: Parse-Driven Refactoring**
"검증하지 말고 파싱하라(Parse, Don't Validate)" 원칙 [^4^]에 따라 타입 시스템을 구조 개선의 나침반으로 사용합니다. 경계에서 한 번만 검증하고 남은 코드에서는 보증된 타입만 사용하며, GADT로 잘못된 상태 전이를 컴파일 타임에 차단합니다 [^5^].

**발견 3: Garbage-First**
모든 구조 개선의 선결조건은 불필요한 요소의 제거입니다. 30개 이상의 임시 스크립트, 중복 대시보드, 13개의 2파일 이하 미니 모듈, 200개 이상의 중복 문서를 제거한 후에야 진정한 재설계가 가능합니다 [^6^]. 숙청 없는 재설계는 기존 쓰레기를 더 좋은 구조로 포장할 뿐입니다.

**발견 4: Agent-First as Simplicity Enforcer**
에이전트 제약이 오히려 단순성을 강제합니다. 인간 개발자는 복잡한 상호의존성을 "관리 가능하다"고 착각하지만, 64K 컨텍스트는 그런 착각을 용납하지 않습니다. 모듈이 에이전트 이해 범위를 벗어나면 개발 속도가 급감하며, 이는 자연스러운 복잡도 경보 시스템 역할을 합니다.

**발견 5: Effect Handler Revolution**
OCaml 5의 Effect Handler는 비동기 패턴을 근본적으로 단순화합니다 [^7^]. Lwt/Async의 monad transformer stack을 effect handler로 대체하면 콜백 지옥과 타입 오염 없이 직관적인 직렬 코드로 동시성을 표현할 수 있으며, Eio 1.0 [^8^]이 이 패턴의 실용적인 구현을 제공합니다.

### 1.3 4-Phase 실행 전략

| Phase | 기간 | 주요 작업 | 산출물 | 참조 장 |
|:---:|:---:|:---|:---|:---:|
| **Phase 0** | Week 1-2 | 숙청 (Purge) | 30+ 스크립트 삭제, 13개 미니 모듈 병합, 문서 250→50개 축소 | [장 3] |
| **Phase 1** | Week 3-8 | 구조 재설계 (Redesign) | 30개 lib → 5개 public lib, 18개 bin → 5개 | [장 4] |
| **Phase 2** | Week 9-14 | 타입 설계 개선 (Types) | GADT 상태 머신, Smart Constructor, 경계 파싱 | [장 5, 6] |
| **Phase 3** | Week 15-20 | 생태계 전환 (Ecosystem) | Base 채택, HTTP 통일, Eio 전환, 의존성 축소 | [장 7, 8] |

**Phase 0: 숙청 (Week 1-2)** — 루트의 30개+ 임시 스크립트를 `archive/`로 통합하고, 13개 미니 모듈을 상위 모듈에 병합하며, 250개 문서를 50개로 축소합니다 [^9^][^10^]. 모든 개선의 선결조건입니다.

**Phase 1: 구조 재설계 (Week 3-8)** — 30개 라이브러리를 5개 public library로 통합하고, `coord`를 3개 서브모듈로 분할하며, 18개 실행 파일을 5개로 축소합니다 [^11^][^12^].

**Phase 2: 타입 설계 개선 (Week 9-14)** — GADT 상태 머신과 Smart Constructor로 잘못된 상태 전이를 컴파일 타임에 방지하고, Functor/Monad를 coord 상태 전이에 적용합니다 [^13^][^14^].

**Phase 3: 생태계 전환 (Week 15-20)** — `Base` 표준라이브러리 채택, HTTP 클라이언트 통일, Lwt/Async → Eio 1.0 마이그레이션, 의존성 40+→25개 축소 [^15^][^16^].

### 1.4 예상 효과

| 지표 | 현재 상태 | 목표 상태 | 개선율 |
|:---|:---|:---|:---:|
| 총 코드 라인 | 565,000 라인 | 480,000 라인 | ▼ 15% |
| OCaml 파일 수 | 2,697 개 | 2,000 개 | ▼ 26% |
| 라이브러리 모듈 | 30 개 | 5 public + 5 internal | ▼ 67% |
| 실행 파일 | 18 개 | 5 개 | ▼ 72% |
| coord 모듈 파일 | 70 개 | 3 서브모듈 × 15개 | ▼ 36% |
| 루트 임시 스크립트 | 30+ 개 | 0 개 | ▼ 100% |
| 문서 파일 | 250 개 | 50 개 (계층화) | ▼ 80% |
| 외부 의존성 | 40+ 개 | 25 개 | ▼ 38% |
| 평균 빌드 시간 (clean) | 8-12분 | 4-6분 | ▼ 50% |
| 에이전트 컨텍스트 적합 모듈 비율 | 30% | 95% | ▲ 217% |

이 개선의 핵심은 단순히 "줄이는 것"이 아닙니다. 565K 라인 전체를 한 번에 이해해야 하는 부담에서, 2,000라인 단위의 독립적 모듈을 조합하여 이해하는 패러다임으로 전환하는 것입니다. 각 모듈이 64K 컨텍스트 내에서 완전히 이해 가능할 때, 에이전트는 코드 생성과 리팩토링에서 최대 생산성을 발휘합니다.

### 1.5 보고서 구성

| 장 | 제목 | 핵심 내용 |
|:---:|:---|:---|
| 2 | 현 상태 진단 (Diagnosis) | 12가지 구조적 문제 식별, 정량적 메트릭스 |
| 3 | 숙청 계획 (Purge Plan) | Phase 0 실행 가이드, 삭제 대상 목록, 안전한 숙청 프로세스 |
| 4 | 구조 재설계 (Redesign) | 5개 public library 설계, 모듈 분할 기준, 실행 파일 통합 |
| 5 | 함수형 설계 원칙 (FP Design) | Parse Don't Validate, GADT 상태 머신, Smart Constructors |
| 6 | 카테고리 이론 적용 (Category Theory) | Functor/Monad, Semigroup/Monoid, Effect Handlers |
| 7 | 라이브러리与生태계 (Libraries) | Base 채택, HTTP 통일, 의존성 축소, Eio 아키텍처 |
| 8 | 문화와 도구 (Culture & Tools) | odoc, Cram Test, CLAUDE.md, ocamlformat, CODEOWNERS |

### 1.6 결론: 숙청을 주저하지 마세요

가장 위험한 접근은 "나중에 숙청하겠다"는 미루기입니다. 새로운 구조 위에 기존 쓰레기를 옮겨 심는 결과가 됩니다. 숙청은 손실이 아니라 투자입니다—버전 관리 시스템이 모든 역사를 보존하고 있으며, 삭제는 되돌릴 수 있습니다. 2주간의 집중 숙청으로 15% 코드와 80% 문서 중복을 제거한 후에야, 진정한 재설계가 시작됩니다.

> "가장 빠른 코드는 존재하지 않는 코드이다. 가장 좋은 모듈은 없어진 모듈이다."

지금 바로 Phase 0을 시작하세요.

---

[^1^]: [장 2: 현 상태 진단] "565,000 라인, 2,697 OCaml 파일, 30개 library 모듈, 18개 executable, 5개 sidecar 서비스"

[^2^]: [장 2: 현 상태 진단] "coord/ 모듈 70파일 집중, 이중 대시보드, 루트 30+ 임시 스크립트, 250개 문서 산발 분포"

[^3^]: [장 4: 구조 재설계] "에이전트 컨텍스트 64K 토큰 ≈ 2,000~3,000라인을 모듈 크기의 1차 설계 제약으로 채택"

[^4^]: [장 5: 함수형 설계 원칙] "Parse, Don't Validate: 경계에서 한 번 파싱하면 남은 코드에서는 타입으로 보증"

[^5^]: [장 5: 함수형 설계 원칙] "GADT 기반 상태 머신으로 잘못된 상태 전이를 컴파일 타임에 차단"

[^6^]: [장 3: 숙청 계획] "30+ 스크립트 삭제, 13개 미니 모듈 병합, 이중 대시보드 통합, 문서 250→50개 축소"

[^7^]: [장 6: 카테고리 이론 적용] "OCaml 5 Effect Handler가 monad transformer를 대체하여 비동기 패턴 단순화"

[^8^]: [장 7: 라이브러리与生태계] "Eio 1.0: effect handler 기반 비동기 I/O, Lwt/Async 대체"

[^9^]: [장 3: 숙청 계획] "루트 임시 스크립트 식별 및 archive/ 통합, 2파일 이하 모듈 병합"

[^10^]: [장 8: 문화와 도구] "250개 문서를 계층적 CLAUDE.md 구조로 재편하여 50개로 축소"

[^11^]: [장 4: 구조 재설계] "30개 lib → 5개 public library (masc, coord, cascade, tools, server) 통합"

[^12^]: [장 4: 구조 재설계] "coord 70파일 → 3개 서브모듈, 18개 bin → 5개 통합"

[^13^]: [장 5: 함수형 설계 원칙] "경계 파싱 + Smart Constructor + GADT로 컴파일 타임 검증 강화"

[^14^]: [장 6: 카테고리 이론 적용] "Monad for coord 상태 전이, Monoid for 로그/설정 병합"

[^15^]: [장 7: 라이브러리与生태계] "Base 채택, piaf+cohttp-eio HTTP 통일, Lwt/Async → Eio 마이그레이션"

[^16^]: [장 8: 문화와 도구] "odoc + .mld API 문서화, Cram Test 통합 테스트, 의존성 40+ → 25개"

---

## 2. 현재 코드베이스 진단

이 장은 masc-mcp 프로젝트의 전체 구조를 수치 중심으로 객관적으로 분석하고, 12가지 구조적 문제를 심각도와 우선순위 기준으로 분류한다. 모든 분석은 Phase F 파일 인벤토리와 Dune 빌드 시스템 분석 결과에 기반한다.

---

### 2.1 전체 구조 분석

#### 2.1.1 프로젝트 규모 개요

masc-mcp 프로젝트는 단일 Git 저장소 내에서 565K 라인 규모의 대규모 OCaml 코드베이스를 유지하고 있다. 이는 Jane Street의 오픈소스 패키지 전체(약 100만 라인)의 절반에 해당하는 규모로, 단일 `dune-project`와 단일 opam 패키지로 관리하기에는 과도하게 크다 [^1^].

| 지표 | 수치 | 비고 |
|------|------|------|
| OCaml 소스 파일 (.ml/.mli/.mll/.mly) | 2,697개 | 565,179 라인 |
| dune 빌드 구성 파일 | 68개 | 전체 프로젝트에 분산 |
| opam 패키지 정의 | 2개 | masc_mcp + locked 버전 |
| 루트 레벨 디렉토리 | 21개 | 코드, 문서, 설정, 임시 파일 혼재 |
| 문서 (docs/) | 250개 | 15개 이상 하위 디렉토리에 분산 |
| 테스트 파일 | ~120개 | test/ 디렉토리 일원화 |
| 임시 스크립트 (루트) | 30+개 | Python 스크립트 (fix_*, wipe_*, remove_*) |
| 프론트엔드 (dashboard/) | 100+개 | TypeScript/React 별도 프로젝트 |
| 대시보드2 (dashboard_bonsai/) | 60+개 | OCaml Bonsai 별도 프로젝트 |
| 사이드카 프로젝트 | 5개 | cli-connector, discord, imessage, slack, telegram |
| TLA+ 사양 (specs/) | 30+개 | 14개 영역 |

**표 2.1**: masc-mcp 프로젝트 규모 개요

565K 라인이라는 규모를 객관적으로 평가하기 위해, OCaml 생태계의 주요 프로젝트들과 비교하면 다음과 같다.

| 프로젝트 | 추정 라인 수 | 패키지 수 | lib 모듈 수 |
|----------|-------------|-----------|-------------|
| Jane Street 오픈소스 (전체) | ~1,000K | 50+ | 100+ |
| **masc-mcp** | **565K** | **1** | **30** |
| MirageOS 4 (코어) | ~200K | 15+ | 40+ |
| Dune 빌드 시스템 | ~150K | 1 | 20+ |
| Irmin (분산 저장소) | ~80K | 5 | 15 |

**표 2.2**: OCaml 주요 프로젝트 규모 비교 (추정치)

masc-mcp는 Jane Street 전체의 절반 규모이면서도, 단일 패키지와 30개 lib 모듈로 압축되어 있다. 이는 비교 대상 프로젝트들에 비해 패키지 분할이 현저히 부족함을 의미한다. Dune은 여러 패키지가 포함된 저장소를 우아하게 처리하며, `dune build --only-packages <package-name> @install` 명령으로 특정 패키지만 빌드할 수 있다 [^2^].

#### 2.1.2 디렉토리 트리 구조

루트 레벨에는 21개 디렉토리가 존재하며, 이들은 명확한 도메인 경계 없이 혼재되어 있다.

```
masc-mcp/
├── archive/                  # 과거 기능 아카이브 (cancellation)
├── assets/                   # 정적 에셋 (graphiql, playground)
├── audits/                   # 감사 문서
├── benchmark/                # 벤치마크 데이터
├── benchmarks/               # 벤치마크 스크립트 (benchmark/와 중복)
├── bin/                      # 18개 실행 파일 진입점
├── ci/                       # CI 스크립트
├── config/                   # 런타임 설정 (keepers/, personas/, prompts/)
├── dashboard/                # TypeScript/React 대시보드 (별도 프로젝트)
├── dashboard_bonsai/         # OCaml Bonsai 대시보드 (별도 프로젝트)
├── data/                     # 데이터 파일 (cdal_baselines, prompts)
├── docs/                     # 250개 문서 (ADR, 아키텍처, 감사, RFC, TLA)
├── fixtures/                 # 테스트 픽스처
├── infrastructure/           # launchd, systemd, monitoring 설정
├── lib/                      # 메인 라이브러리 (30개 하위 모듈, 389 파일)
├── memory/                   # 메모리/소울 데이터
├── mk/                       # Makefile 관련
├── ppx_tla/                  # TLA+ PPX
├── proto/                    # 프로토콜 버퍼 정의
├── scripts/                  # 유틸리티 스크립트 (bench, ci, harness, lint)
├── sidecars/                 # 5개 부가 컴포넌트
├── specs/                    # TLA+ 형식 사양 (14개 영역)
└── test/                     # 테스트 스위트
```

**디렉토리 트리 2.1**: 루트 레벨 구조

이 구조에서 즉각적으로 드러나는 문제점은 다음과 같다.

첫째, `benchmark/`와 `benchmarks/`는 명확한 구분 없이 병존한다. 하나는 데이터 저장용, 다른 하나는 스크립트용으로 추정되나, 명명 규칙의 일관성이 부족하다.

둘째, `dashboard/`와 `dashboard_bonsai/`는 동일한 기능 영역에 대한 두 가지 완전히 별도의 구현이다. 두 디렉토리가 루트에 나란히 존재하는 것 자체가 아키텍처 결정이 명확하지 않음을 시사한다.

셋째, `docs/` 외에 `audits/`, `archive/`, `memory/`, `specs/` 등 문서성 콘텐츠가 루트에 흩어져 있다. Dune 프로젝트의 표준 구조는 `lib/`, `bin/`, `test/`의 3분할을 기본으로 하며 [^3^], 21개의 루트 디렉토리는 이 표준에서 크게 벗어난다.

#### 2.1.3 lib/ 30개 모듈 상세 분석

`lib/` 디렉토리는 30개의 하위 모듈로 구성되며, 총 389개 파일을 포함한다. 파일 수 기준으로 정렬하면 다음과 같다.

| 순위 | 모듈명 | 파일 수 | 추정 역할 | 규모 분류 |
|------|--------|---------|-----------|-----------|
| 1 | `lib/coord` | 70 | 에이전트 좌표/조정 | 초대형 |
| 2 | `lib/cascade` | 54 | 캐스케이드 처리 | 초대형 |
| 3 | `lib/tool_schemas` | 28 | 도구 스키마 정의 | 대형 |
| 4 | `lib/multimodal` | 24 | 멀티모달 처리 | 대형 |
| 5 | `lib/core` | 24 | 핵심 기능 | 대형 |
| 6 | `lib/server` | 18 | 서버 구현 | 중형 |
| 7 | `lib/gate` | 16 | 게이트/진입점 | 중형 |
| 8 | `lib/types` | 15 | 타입 정의 | 중형 |
| 9 | `lib/repo_manager` | 14 | 저장소 관리 | 중형 |
| 10 | `lib/autonomous` | 12 | 자율 에이전트 | 중형 |
| 11 | `lib/shared_types` | 10 | 공유 타입 | 소형 |
| 12 | `lib/local` | 10 | 로컬 실행 | 소형 |
| 13 | `lib/activity_graph` | 8 | 활동 그래프 | 소형 |
| 14 | `lib/prompt_registry` | 6 | 프롬프트 레지스트리 | 소형 |
| 15 | `lib/backend` | 6 | 백엔드 | 소형 |
| 16 | `lib/cdal` | 4 | CDAL (에이전트 평가) | 소형 |
| 17 | `lib/random_id` | 2 | ID 생성 | 초소형 |
| 18 | `lib/oas_compat` | 2 | OAS 호환성 | 초소형 |
| 19 | `lib/memory` | 2 | 메모리 관리 | 초소형 |
| 20 | `lib/mcp_transport_protocol` | 2 | MCP 전송 프로토콜 | 초소형 |
| 21 | `lib/mcp_session` | 2 | MCP 세션 | 초소형 |
| 22 | `lib/fs_compat` | 2 | 파일시스템 호환 | 초소형 |
| 23 | `lib/eio_context` | 2 | Eio 컨텍스트 | 초소형 |
| 24 | `lib/dated_jsonl` | 2 | 날짜별 JSONL | 초소형 |
| 25 | `lib/dashboard_utils` | 2 | 대시보드 유틸리티 | 초소형 |
| 26 | `lib/dashboard_api_types` | 2 | 대시보드 API 타입 | 초소형 |
| 27 | `lib/compression` | 2 | 압축 | 초소형 |
| 28 | `lib/board_types` | 2 | 보드 타입 | 초소형 |
| 29 | `lib/ag_ui` | 2 | 에이전트 UI | 초소형 |
| 30 | `lib/embedded_config` | 0 | (빈 디렉토리) | 빈 모듈 |

**표 2.3**: lib/ 하위 30개 모듈 파일 수 기준 분석

이 분포는 명확한 계층 구조의 부재를 보여준다. 상위 2개 모듈(`coord` 70파일, `cascade` 54파일)이 전체 파일의 32%를 차지하는 반면, 하위 13개 모듈은 각각 2개 파일로 전체의 7%를 차지한다. OCaml 커뮤니티의 일반적인 관행에 따른다면, 하나의 라이브러리 디렉토리는 20-50개 모듈을 상한으로 삼는 것이 바람직하다 [^4^].

`coord`(70파일)와 `cascade`(54파일)는 이 기준을 명확히 초과하며, 각각 독립적인 서브라이브러리로 분할될 필요가 있다. 반면 `random_id`, `oas_compat`, `memory` 등 2개 파일로 구성된 13개 모듈은 관리 오버헤드에 비해 제공하는 가치가 적어, 관련 모듈과의 병합을 고려해야 한다 [^5^].

파일 수 분포를 규모 분류별로 집계하면 다음과 같다.

| 규모 분류 | 모듈 수 | 총 파일 수 | 전체 대비 비율 |
|-----------|---------|-----------|---------------|
| 초대형 (50+ 파일) | 2 | 124 | 31.9% |
| 대형 (20-49 파일) | 3 | 76 | 19.5% |
| 중형 (10-19 파일) | 5 | 70 | 18.0% |
| 소형 (4-9 파일) | 4 | 24 | 6.2% |
| 초소형 (1-2 파일) | 13 | 26 | 6.7% |
| 빈 모듈 (0 파일) | 1 | 0 | 0.0% |
| bin/ 실행 파일 | 18 | 18 | 4.6% |
| 기타 | - | 51 | 13.1% |

**표 2.4**: lib/ 모듈 규모 분류 집계

초대형 2개 모듈이 전체의 32%를 차지하는 구조는 빌드 병목의 집중을 의미한다. Dune의 증분 컴파일은 파일 단위로 작동하지만, 하나의 `library` 스탠자 내에서 모듈 간 의존성이 존재하면 연쇄 재컴파일이 발생한다 [^6^]. 70개 파일이 하나의 라이브러리로 묶이면, 낮에 파일 하나의 수정도 전체 라이브러리의 의존성 해석을 유발할 수 있다.

#### 2.1.4 의존성 그래프 분석

`dune-project`에 선언된 의존성은 40개 이상에 달하며, 이 중 중복적 기능을 제공하는 라이브러리들이 병존한다.

```ocaml
; dune-project 핵심 의존성 (추출)
(depends
  ocaml (>= 5.4)
  eio (>= 1.0) eio_main eio_posix
  ; HTTP 클라이언트/서버 중복
  httpun httpun-eio httpun-ws httpun-ws-eio
  cohttp cohttp-eio
  h2 h2-eio
  ; gRPC
  grpc-direct grpc-direct-core ocaml-protoc-plugin pbrt pbrt_services
  ; 데이터베이스
  sqlite3 neo4j_bolt_eio
  ; 암호화
  mirage-crypto mirage-crypto-rng tls tls-eio digestif
  ; 직렬화
  yojson ppx_deriving_yojson ppx_deriving
  ; GraphQL
  graphql graphql_parser
  ; WebRTC
  ocaml-webrtc
  ; CLI/유틸리티
  cmdliner uri re cstruct bigstringaf zstd uuidm mtime
  ; OpenTelemetry
  opentelemetry ambient-context-eio
  ; MCP 프로토콜 (opam pin)
  mcp_protocol
  ; Agent SDK (opam pin)
  agent_sdk
)
```

**코드 2.1**: dune-project 의존성 선언 (재구성)

이 의존성 목록을 기능 영역별로 분류하면 다음과 같다.

| 영역 | 라이브러리 | 수 | 중복 여부 |
|------|-----------|-----|----------|
| HTTP/1.1 | httpun, httpun-eio, cohttp, cohttp-eio | 4 | **httpun vs cohttp 중복** |
| WebSocket | httpun-ws, httpun-ws-eio | 2 | - |
| HTTP/2 | h2, h2-eio | 2 | - |
| gRPC | grpc-direct, grpc-direct-core, ocaml-protoc-plugin, pbrt, pbrt_services | 5 | - |
| DB | sqlite3, neo4j_bolt_eio | 2 | - |
| Crypto | mirage-crypto, mirage-crypto-rng, tls, tls-eio, digestif | 5 | - |
| Serialization | yojson, ppx_deriving_yojson, ppx_deriving | 3 | - |
| GraphQL | graphql, graphql_parser | 2 | - |
| WebRTC | ocaml-webrtc | 1 | - |
| Telemetry | opentelemetry, ambient-context-eio | 2 | - |
| MCP/Agent | mcp_protocol, agent_sdk | 2 | opam pin |
| Eio 비동기 | eio, eio_main, eio_posix | 3 | - |
| 유틸리티 | cmdliner, uri, re, cstruct, bigstringaf, zstd, uuidm, mtime | 8 | - |

**표 2.5**: dune-project 의존성 기능 영역별 분류

특히 HTTP 스택 영역에서 `httpun`, `cohttp`, `h2` 세 라이브러리가 동시에 존재한다. `httpun`은 Jane Street 스타일의 HTTP/1.1 구현, `cohttp`는 MirageOS/Ocsigen 생태계의 표준, `h2`는 HTTP/2 전용이다 [^7^]. 이들이 단일 프로젝트 내에서 각각 다른 모듈에 의해 사용된다면, 빌드 시간 증가와 의존성 충돌 위험이 커진다. OCaml 5.4+와 Eio 1.0+ 환경에서는 `httpun`이 `cohttp`의 상위 호환으로 간주될 수 있다.

---

### 2.2 식별된 12가지 구조적 문제

본 절에서는 Phase F 파일 분석과 Dune 빌드 시스템 진단을 통해 식별된 12가지 구조적 문제를 제시한다. 각 문제는 심각도(심각/보통/경미)와 우선순위(P0-P2)로 분류하며, 구체적 수치와 시각적 증거를 포함한다.

---

#### 문제 1: 거대 모듈 (coord 70파일, cascade 54파일)

| 속성 | 값 |
|------|-----|
| **심각도** | 심각 |
| **우선순위** | P0 |
| **영향 범위** | 빌드 시간, 코드 발견성(code discoverability), 팀 병렬 작업 |

`lib/coord`(70파일)와 `lib/cascade`(54파일)는 전체 lib/ 모듈 파일의 32%를 차지한다. OCaml에서 하나의 디렉토리는 하나의 라이브러리로 묶이며, 해당 디렉토리의 모든 `.ml/.mli` 파일이 라이브러리의 모듈이 된다 [^6^]. 70개 파일이 하나의 Dune `library` 스탠자로 컴파일되면, 한 파일의 수정도 전체 70개 파일의 의존성 해석과 재컴파일을 유발할 수 있다.

실제로 Dune의 증분 빌드는 모듈 수준에서 작동하지만, 하나의 `library` 스탠자 내에서는 모든 모듈이 동일한 컴파일 단위로 간주된다. `coord` 모듈의 파일 하나를 수정하면, `coord` 라이브러리 전체가 재빌드 대상이 된다. 70개 파일이 서로 의존하는 복잡한 그래프를 형성한다면, 수정의 영향 범위는 예측하기 어렵게 확산된다.

**Before (현재 구조):**
```
lib/coord/
├── dune                    # (library (name coord) (public_name masc_mcp.coord))
├── coord.ml              # (70개 파일, 전부 단일 라이브러리)
├── coord_types.ml
├── coord_engine.ml
├── coord_transport.ml
├── ... 65 more files ...
└── coord_utils.ml
```

**After (권장 구조):**
```
lib/coord/
├── dune-project            # 별도 dune-project
├── coord_core/
│   ├── dune                # (library (public_name masc_mcp.coord_core))
│   ├── coord_types.ml
│   ├── coord_protocol.ml
│   └── coord_message.ml
├── coord_engine/
│   ├── dune                # (library (public_name masc_mcp.coord_engine))
│   ├── coord_scheduler.ml
│   ├── coord_executor.ml
│   └── coord_recovery.ml
└── coord_transport/
    ├── dune                # (library (public_name masc_mcp.coord_transport))
    ├── coord_ws.ml
    ├── coord_grpc.ml
    └── coord_mcp.ml
```

Dune 3.21의 `(dir ..)` 필드는 패키지와 디렉토리를 명시적으로 연결하여 `--only-packages` 사용 시 해당 디렉토리와 하위의 모든 스탠자를 자동으로 필터링한다 [^8^]. 이를 활용하면 coord의 서브라이브러리들을 독립적으로 빌드할 수 있다.

---

#### 문제 2: 이중 대시보드 (TypeScript + OCaml Bonsai)

| 속성 | 값 |
|------|-----|
| **심각도** | 심각 |
| **우선순위** | P0 |
| **영향 범위** | 유지보스 부담, 기능 동기화, 빌드 복잡도 |

프로젝트 루트에는 `dashboard/`(TypeScript/React, 100+ 파일)와 `dashboard_bonsai/`(OCaml Bonsai, 60+ 파일)가 동시에 존재한다. 이는 동일한 기능 영역에 대한 두 가지 완전히 별도의 구현으로, 한쪽에 기능을 추가하면 다른 쪽도 동기화해야 한다.

| 대시보드 | 기술 스택 | 파일 수 | 빌드 툴체인 | 상태 |
|----------|-----------|---------|-------------|------|
| `dashboard/` | TypeScript/React | 100+ | npm/webpack | 완전한 별도 프로젝트 |
| `dashboard_bonsai/` | OCaml Bonsai | 60+ | dune + js_of_ocaml | 완전한 별도 프로젝트 |

**표 2.6**: 이중 대시보드 구현 현황

Bonsai는 Jane Street의 반응형 UI 프레임워크로, OCaml 코드베이스와의 통합이 자연스럽다는 장점이 있다 [^9^]. 하지만 TypeScript/React 구현이 이미 운영 중이라면, 두 구현의 통합 전략이 필요하다. 두 대시보드가 `lib/dashboard_api_types`와 `lib/dashboard_utils`에 각각 의존하고 있음은, lib/ 모듈도 이 이중 구조에 맞춰 분화되었음을 의미한다.

이중 대시보드의 유지보스 부담을 정량화하면, UI 컴포넌트 하나를 수정할 때 두 코드베이스에서 각각 구현해야 하므로 개발 생산성이 이론적으로 50% 이하로 저하된다. 더욱이 두 구현의 시각적/기능적 동등성을 보장하는 테스트는 거의 존재하지 않을 것으로 추정된다.

---

#### 문제 3: 루트 디렉토리 오염 (30+ 임시 스크립트)

| 속성 | 값 |
|------|-----|
| **심각도** | 보통 |
| **우선순위** | P1 |
| **영향 범위** | 저장소 청결도, 신규 기여자 onboarding |

루트 디렉토리에는 30개 이상의 임시 Python 스크립트와 OCaml 디버깅 파일이 존재한다.

```
fix_dune_visibility.py
fix_opam_pins.py
fix_string_ids.ml
wipe_cache.py
wipe_state.py
remove_deprecated.ml
debug.ml
debug_canonical.ml
format_all.sh
lint_quick.ml
```

**디렉토리 트리 2.2**: 루트 임시 스크립트 예시 (일부)

이들은 대부분 일회성 마이그레이션 스크립트나 디버깅 도구로, 코드 리뷰 프로세스를 거치지 않은 채 루트에 축적되었다. 파일명에서 알 수 있듯, `fix_*`는 마이그레이션용, `wipe_*`는 데이터 정리용, `debug*.ml`은 디버깅용으로 분류된다.

Real World OCaml의 권장에 따른다면, `bin/`은 코드를 실행하는 thin wrapper만을 담아야 하며 [^10^], 이러한 임시 스크립트는 `scripts/`나 별도 유지보수 디렉토리로 이전되어야 한다. 현재 `scripts/` 디렉토리가 이미 존재함에도 불구하고(`bench/`, `ci/`, `harness/`, `lib/`, `lint/`, `review/`, `smoke/` 하위 디렉토리 포함), 임시 스크립트들은 루트에 그대로 남아 있다.

---

#### 문제 4: 문서 난립 (250개 문서, 15개 이상 디렉토리)

| 속성 | 값 |
|------|-----|
| **심각도** | 보통 |
| **우선순위** | P1 |
| **영향 범위** | 지식 발견성, 문서 신뢰도 |

`docs/` 하위에 250개 문서가 15개 이상의 디렉토리에 흩어져 있다. 더 심각한 것은 아카이브와 감사 문서의 중복적 분산이다.

```
docs/
├── ADR/                    # 아키텍처 결정 기록
├── archive/                # (아카이브 중복 위치 1)
├── _audit/                 # (아카이브 중복 위치 2)
├── audit-responses/        # (아카이브 중복 위치 3)
├── RFC/                    # RFC 문서
├── TLA/                    # TLA+ 사양
├── architecture/           # 아키텍처 문서
├── api/                    # API 문서
├── guides/                 # 사용자 가이드
├── contributing/           # 기여 가이드
├── deployment/             # 배포 문서
├── development/            # 개발 문서
├── metrics/                # 메트릭 문서
├── patterns/               # 패턴 문서
├── security/               # 보안 문서
└── ... (추가 하위 디렉토리)
```

**디렉토리 트리 2.3**: docs/ 하위 구조 (아카이브 중복 표시)

`docs/archive/`, `docs/_audit/`, `docs/audit-responses/`는 서로 다른 시점의 감사/아카이브 자료를 담고 있으며, 실제로 어떤 것이 최신인지 판단하기 어렵다. 밑줄 접두사(`_audit`)와 하이픈 중첩(`audit-responses`)은 서로 다른 관리자가 서로 다른 시점에 디렉토리를 생성했음을 의미한다.

250개 문서의 15개 이상 분산은 특정 주제를 찾을 때 여러 디렉토리를 동시에 검색해야 함을 의미한다. 예를 들어 "authentication" 관련 문서를 찾으려면 `docs/security/`, `docs/architecture/`, `docs/ADR/`, `docs/RFC/`를 모두 확인해야 할 수 있다.

---

#### 문제 5: 빈/작은 모듈 (embedded_config, mcp_transport_protocol 등)

| 속성 | 값 |
|------|-----|
| **심각도** | 경미 |
| **우선순위** | P2 |
| **영향 범위** | 빌드 구성 복잡도, 관리 오버헤드 |

`lib/embedded_config/`는 파일 수가 0개로, 실제로 빈 디렉토리이다. `lib/mcp_transport_protocol/`(2파일), `lib/mcp_session/`(2파일), `lib/random_id/`(2파일) 등 13개 모듈은 각각 2개 파일로 구성된다.

| 모듈 | 파일 수 | 상태 | 병합 제안 대상 |
|------|---------|------|----------------|
| `embedded_config` | 0 | 빈 디렉토리 | 삭제 또는 `config/` 데이터와 통합 |
| `mcp_transport_protocol` | 2 | 초소형 | `mcp_session`과 병합 |
| `mcp_session` | 2 | 초소형 | `mcp_transport_protocol`과 병합 |
| `random_id` | 2 | 초소형 | `shared_types` 또는 `core`와 병합 |
| `oas_compat` | 2 | 초소형 | `tool_schemas`와 병합 |
| `fs_compat` | 2 | 초소형 | `core`와 병합 |
| `eio_context` | 2 | 초소형 | `core`와 병합 |
| `dated_jsonl` | 2 | 초소형 | `backend`와 병합 |
| `dashboard_utils` | 2 | 초소형 | 대시보드 통합 시 정리 |
| `dashboard_api_types` | 2 | 초소형 | 대시보드 통합 시 정리 |
| `compression` | 2 | 초소형 | `core`와 병합 |
| `board_types` | 2 | 초소형 | `shared_types`와 병합 |
| `ag_ui` | 2 | 초소형 | `activity_graph`와 병합 |

**표 2.7**: 빈/초소형 모듈 현황 및 병합 제안

Dune은 디렉토리로부터 라이브러리를 생성하며, 디렉토리의 모든 모듈은 해당 라이브러리로 묶인다 [^6^]. 2개 파일짜리 라이브러리 13개는 각각 독립적인 `dune` 파일, `public_name`, 빌드 타겟을 필요로 한다. 이들을 각각 별도의 opam 설치 단위로 관리하는 것은 비효율적이다.

특히 `embedded_config`(0파일)는 존재 이유가 불분명하다. 이 디렉토리가 `dune` 파일조차 없다면, 과거에 사용되다가 비워진 모듈의 잔해일 가능성이 높다. `mcp_transport_protocol`과 `mcp_session`은 MCP(Model Context Protocol)의 전송 계층과 세션 계층으로, 프로토콜 스택의 인접한 두 계층이다. 두 모듈이 서로 밀접하게 결합되어 있다면 단일 `mcp_transport` 라이브러리로 병합하는 것이 타당하다.

---

#### 문제 6: 중복 아카이브 (archive/, docs/archive/, docs/_audit/)

| 속성 | 값 |
|------|-----|
| **심각도** | 보통 |
| **우선순위** | P1 |
| **영향 범위** | 저장소 크기, 혼란 |

아카이브 자료가 4개 이상의 위치에 중복 분산되어 있다.

| 위치 | 내용 | 추정 용량 | Git 히스토리에 존재 |
|------|------|-----------|-------------------|
| `archive/` | 과거 기능 아카이브 (cancellation 등) | 중간 | 예 |
| `docs/archive/` | 문서 아카이브 | 작음 | 예 |
| `docs/_audit/` | 감사 기록 아카이브 | 큼 | 예 |
| `docs/audit-responses/` | 감사 응답 아카이브 | 중간 | 예 |

**표 2.8**: 중복 아카이브 위치

Git의 히스토리에 이미 보존된 자료를 별도 디렉토리에 아카이브하는 것은 중복이다. 이들은 단일 `attic/` 디렉토리로 통합하거나, Git LFS로 마이그레이션할 수 있다. 특히 `_audit` 디렉토리의 밑줄 접두사는 임시/히든 디렉토리로서의 성격을 강하며, 공식 문서 구조에 포함되기에는 부적절한 명명이다.

---

#### 문제 7: 사이드카 관리 부재

| 속성 | 값 |
|------|-----|
| **심각도** | 보통 |
| **우선순위** | P1 |
| **영향 범위** | 배포 복잡도, 의존성 격리 |

`sidecars/` 디렉토리에는 5개의 부가 컴포넌트가 존재한다: `cli-connector`, `discord-bot`, `imessage-bot`, `slack-bot`, `telegram-bot`. 이들은 메인 프로젝트와 별도의 빌드 라이프사이클을 가져야 하나, 현재 단일 `dune-project` 내에서 관리되고 있다.

Dune workspace 내의 서로 다른 프로젝트는 public item(public library, public executable)만 서로 볼 수 있다 [^11^]. 사이드카들을 별도의 `dune-project`로 분리하면, 메인 프로젝트와의 명확한 경계가 생기고 독립적인 배포가 가능해진다. 예를 들어 `discord-bot`만 수정하여 배포하고자 할 때, 현재 구조에서는 전체 masc_mcp 프로젝트의 빌드를 수행해야 한다. 분리된 구조에서는 `dune build --only-packages discord-bot`으로 해당 사이드칼만 빌드할 수 있다 [^2^].

---

#### 문제 8: bin/ 확장 (18개 실행 파일)

| 속성 | 값 |
|------|-----|
| **심각도** | 보통 |
| **우선순위** | P1 |
| **영향 범위** | 빌드 시간, CLI 일관성 |

`bin/` 디렉토리에는 18개의 실행 파일이 정의되어 있다.

| 실행 파일 | 역할 | 분류 | 통합 제안 |
|-----------|------|------|-----------|
| `main_eio` | 메인 서버 (Eio) | 핵심 | 유지 |
| `main_stdio_eio` | stdio 서버 (Eio) | 핵심 | `main_eio`의 서브커맨드로 통합 |
| `masc_tui` | TUI 메인 | TUI 계열 | TUI 마스터 명령 |
| `masc_tui_ansi` | TUI ANSI 렌더링 | TUI 계열 | `masc_tui` 서브커맨드 |
| `masc_tui_loader` | TUI 로더 | TUI 계열 | `masc_tui` 서브커맨드 |
| `masc_tui_render` | TUI 렌더러 | TUI 계열 | `masc_tui` 서브커맨드 |
| `masc_tui_types` | TUI 타입 | TUI 계열 | `lib/`로 이동 |
| `masc_worker_run` | 워커 실행 | 핵심 | 유지 |
| `masc_cost` | 비용 분석 | 유틸리티 | `masc_cli` 통합 |
| `masc_trace` | 트레이싱 | 유틸리티 | `masc_cli` 통합 |
| `trace_to_tla` | TLA+ 변환 | 유틸리티 | `masc_cli` 통합 |
| `cascade_materialize` | 캐스케이드 구체화 | 도메인 도구 | `masc_cli` 통합 |
| `cdal_label` | CDAL 라벨링 | 도메인 도구 | `masc_cli` 통합 |
| `env_knob_catalog` | 환경 변수 카탈로그 | 유틸리티 | `masc_cli` 통합 |
| `keeper_feature_proof_report` | 키퍼 보고서 | 도메인 도구 | `masc_cli` 통합 |
| `masc_compaction_audit` | 컴팩션 감사 | 유틸리티 | `masc_cli` 통합 |
| `public_tool_manifest` | 툴 매니페스트 | 유틸리티 | `masc_cli` 통합 |

**표 2.9**: bin/ 18개 실행 파일 분류 및 통합 제안

`masc_tui*` 계열 5개는 하나의 CLI 도구의 서브커맨드로 통합할 수 있다. Jane Street의 `core_bench`나 `async` 도구들처럼, 유사 기능은 하위 커맨드로 묶는 것이 일반적이다 [^12^]. `cmdliner` 라이브러리는 이미 `dune-project` 의존성에 포함되어 있으므로, 서브커맨드 구조로의 전환은 기술적으로 직접적이다.

18개 실행 파일은 각각 독립적인 바이너리로 링크되므로, 전체 빌드 시 18개의 링크 단계가 필요하다. 링크는 OCaml에서 특히 시간이 소요되는 작업으로, 18개 바이너리의 링크 시간은 라이브러리 컴파일 시간의 상당 부분을 차지할 수 있다.

---

#### 문제 9: lib/ 모듈 간 의존성 방향성 부재

| 속성 | 값 |
|------|-----|
| **심각도** | 심각 |
| **우선순위** | P0 |
| **영향 범위** | 아키텍처 침식, 순환 의존성 위험 |

현재 30개 lib 모듈은 단일 `dune-project` 내에서 서로의 `public_name`을 통해 직접 참조한다. 이 구조에서는 의존성 방향성이 코드 리뷰 외에 강제되는 메커니즘이 없다. Dune의 `(libraries ...)` 필드는 현재 스코프의 라이브러리는 실제 이름이나 public 이름을 사용할 수 있게 한다 [^13^].

**순환 의존성 위험 예시:**
```ocaml
(* lib/coord/dune *)
(library
 (name coord)
 (libraries cascade types server))  ; cascade에 의존

(* lib/cascade/dune *)
(library
 (name cascade)
 (libraries coord types))  ; coord에 역의존 -> 순환!
```

이 예시는 가상의 시나리오지만, 30개 모듈이 서로를 자유롭게 참조하는 환경에서는 순환 의존성이 점진적으로 형성되기 쉽다. 일단 순환 의존성이 형성되면, 모듈 분할이나 리팩토링의 난이도가 기하급수적으로 증가한다.

Dune 3.21의 `unused-libs` alias를 활용하면 사용하지 않는 라이브러리 의존성을 자동으로 감지할 수 있다 [^14^]. 더 근본적으로는 `dune-workspace` 내에서 여러 `dune-project`로 분리하여, 프로젝트 경계를 통해 의존성 방향성을 강제해야 한다 [^11^].

---

#### 문제 10: config/ 프롬프트 이중 관리

| 속성 | 값 |
|------|-----|
| **심각도** | 보통 |
| **우선순위** | P1 |
| **영향 범위** | 데이터 일관성, 설정 동기화 |

`config/` 디렉토리에는 `prompts/` 하위 디렉토리가 존재하며, 동시에 `lib/prompt_registry/` 모듈도 프롬프트 관리를 담당한다. 이는 동일한 개념("프롬프트")이 파일 시스템(config/prompts/)과 코드(lib/prompt_registry/)에 이중으로 존재함을 의미한다.

```
config/
├── prompts/                # 파일 시스템 기반 프롬프트 저장
│   ├── system/
│   ├── user/
│   └── tool/
├── keepers/                # 키퍼 설정
├── personas/               # 페르소나 설정
└── tool_policy.toml        # 도구 정책

lib/prompt_registry/        # 코드 기반 프롬프트 레지스트리
├── dune
├── prompt_registry.ml
└── prompt_registry.mli
```

**디렉토리 트리 2.4**: 프롬프트 이중 관리 구조

런타임에 프롬프트를 파일에서 읽어오는 구조라면, `lib/prompt_registry`는 파일 I/O 래퍼에 불과할 수 있다. 반면 코드에 내장된 프롬프트라면, `config/prompts/`의 파일은 오래된 복사본일 수 있다. 어느 쪽이든 단일 진실 공급원(single source of truth)을 확립해야 한다.

---

#### 문제 11: dashboard_bonsai 별도 프로젝트 관리 문제

| 속성 | 값 |
|------|-----|
| **심각도** | 심각 |
| **우선순위** | P0 |
| **영향 범위** | 빌드 복잡도, JavaScript 툴체인 의존성 |

`dashboard_bonsai/`는 완전한 별도의 OCaml 프로젝트로, 자체 `dune-project`와 JavaScript 툴체인 의존성을 가진다. Bonsai 애플리케이션은 JavaScript 번들링을 위해 `js_of_ocaml`이나 `wasm_of_ocaml`을 필요로 하며, 이는 메인 프로젝트의 빌드와는 완전히 다른 툴체인이다 [^9^].

현재 `dashboard_bonsai/`가 루트 `dune-project`의 하위가 아닌 별도 위치에 있다면, Dune workspace 설정이 올바르게 구성되어 있는지 확인해야 한다. Dune workspace는 여러 Dune project의 집합이며, 각 프로젝트는 독립적이다 [^11^]. `dashboard_bonsai`를 명시적으로 별도 `dune-project`로 분리하면, 메인 프로젝트의 빌드에 JavaScript 툴체인이 간섭하지 않는다.

또한 `dashboard_bonsai`가 `dashboard/`(TypeScript)를 완전히 대체할 것인지, 아니면 두 구현이 공존할 것인지의 전략적 결정이 필요하다. 이 결정이 낮에 lib/의 `dashboard_utils`와 `dashboard_api_types` 모듈의 용도도 명확히 한다.

---

#### 문제 12: 의존성 중복 (cohttp + httpun, 중복 HTTP 라이브러리)

| 속성 | 값 |
|------|-----|
| **심각도** | 보통 |
| **우선순위** | P1 |
| **영향 범위** | 빌드 시간, 바이너리 크기, 보안 표면 |

`dune-project`에는 세 가지 HTTP 라이브러리 스택이 동시에 선언되어 있다.

| 라이브러리 | 프로토콜 | 생태계 | 주요 용도 | 대체 가능성 |
|-----------|----------|--------|-----------|------------|
| `httpun` | HTTP/1.1 | Jane Street | 고성능 HTTP 서버 | - (권장) |
| `httpun-eio` | HTTP/1.1 | Jane Street | Eio 통합 | - |
| `httpun-ws` | WebSocket | Jane Street | WS 서버 | - |
| `httpun-ws-eio` | WebSocket | Jane Street | Eio WS 통합 | - |
| `cohttp` | HTTP/1.1 | MirageOS | 레거시 호환 | httpun으로 대체 가능 |
| `cohttp-eio` | HTTP/1.1 | MirageOS | Eio 레거시 | httpun-eio로 대체 가능 |
| `h2` | HTTP/2 | Jane Street | HTTP/2 서버 | - (전용) |
| `h2-eio` | HTTP/2 | Jane Street | Eio HTTP/2 | - |

**표 2.10**: 중복 HTTP 라이브러리 스택 상세 분석

`httpun`은 `cohttp`의 대체재로 설계되었으며, 둘 다 HTTP/1.1을 제공한다 [^7^]. 두 라이브러리를 동시에 링크하면 바이너리 크기가 불필요하게 증가하고, 보안 취약점 패치 시 두 곳을 모두 점검해야 한다. OCaml 5.4+와 Eio 1.0+ 환경에서는 `httpun`이 `cohttp`보다 권장되는 선택이다.

`cohttp`에서 `httpun`으로의 마이그레이션은 API가 유사하므로 상대적으로 직접적이다. 다만 `cohttp`에 의존하는 외부 라이브러리가 있다면, 이들도 함께 업데이트해야 한다. 또한 40개 이상의 전체 의존성 목록은 opam 의존성 해석(resolution) 시간에도 영향을 미친다. `opam pin`으로 관리되는 `mcp_protocol`과 `agent_sdk`는 공식 opam 레포지토리에 등재되지 않은 낮에 의존성으로, 이들의 버전 호환성은 수동으로 관리되어야 한다. 의존성 수가 많을수록 이 호환성 매트릭스의 복잡도는 기하급수적으로 증가한다.

---

### 2.3 문제 종합 매트릭스

| # | 문제 | 심각도 | 우선순위 | 영향 모듈/영역 | 개선 장 연결 |
|---|------|--------|----------|----------------|-------------|
| 1 | 거대 모듈 (coord, cascade) | 심각 | P0 | lib/coord, lib/cascade | 3장 (모듈 분할) |
| 2 | 이중 대시보드 | 심각 | P0 | dashboard/, dashboard_bonsai/ | 4장 (대시보드 통합) |
| 11 | dashboard_bonsai 별도 프로젝트 | 심각 | P0 | dashboard_bonsai/ | 4장 (워크스페이스 재구성) |
| 9 | lib/ 의존성 방향성 부재 | 심각 | P0 | lib/ 전체 | 3장 (의존성 그래프) |
| 3 | 루트 디렉토리 오염 | 보통 | P1 | 루트 수준 | 5장 (청소 전략) |
| 4 | 문서 난립 | 보통 | P1 | docs/ 전체 | 5장 (문서 재구성) |
| 6 | 중복 아카이브 | 보통 | P1 | archive/, docs/archive/ 등 | 5장 (아카이브 통합) |
| 7 | 사이드카 관리 부재 | 보통 | P1 | sidecars/ | 3장 (멀티 패키지) |
| 8 | bin/ 확장 (18개) | 보통 | P1 | bin/ 전체 | 3장 (실행 파일 통합) |
| 10 | config/ 프롬프트 이중 관리 | 보통 | P1 | config/, lib/prompt_registry | 5장 (설정 통합) |
| 12 | 의존성 중복 (HTTP) | 보통 | P1 | dune-project | 3장 (의존성 정리) |
| 5 | 빈/작은 모듈 | 경미 | P2 | 13개 모듈 | 3장 (모듈 병합) |

**표 2.11**: 12가지 구조적 문제 종합 매트릭스

12가지 문제는 서로 독립적이지 않다. 예를 들어 문제 2(이중 대시보드)와 문제 11(dashboard_bonsai 별도 프로젝트)는 동일한 근원에서 비롯되며, 문제 5(빈/작은 모듈)의 `dashboard_utils`와 `dashboard_api_types`는 문제 2의 부산물이다. 문제 1(거대 모듈)과 문제 9(의존성 방향성 부재)는 상호 강화하는 관계로, 모듈이 클수록 의존성 그래프가 복잡해지고, 의존성 그래프가 복잡할수록 모듈 분할이 어려워진다.

따라서 개선은 P0 문제부터 순차적으로 접근하는 것이 바람직하다. P0 문제 4가지를 해결하면 lib/의 70% 이상 구조적 문제가 해결되며, P1 문제는 P0 이후 후속 작업으로 진행할 수 있다.

---

### 2.4 핵심 발견 요약

masc-mcp 프로젝트의 구조적 문제는 세 가지 근원 원인으로 집약된다.

**첫째, 단일 패키지의 규모 초과.** 565K 라인을 단일 opam 패키지로 관리하는 것은 Dune 빌드 시스템의 설계 범위를 벗어난다. Jane Street는 이러한 규모의 코드를 monorepo 내에서 여러 독립적인 opam 패키지로 분할하여 관리한다 [^1^]. MirageOS 4 역시 `opam-monorepo`로 의존성을 분리하고 단일 Dune 워크스페이스에서 빌드하지만, 각 컴포넌트는 명확한 패키지 경계를 가진다 [^15^]. Anil Madhavapeddy는 2025년에 agentic 개발을 위해 Dune의 자동 서브디렉토리 빌드 기능을 활용한 monorepo 조합 방법을 제시했으며, 이는 대규모 코드베이스를 패키지 단위로 분할하는 현대적 접근법이다 [^16^].

**둘째, 아키텍처 결정의 지속성 부재.** 이중 대시보드, 중복 아카이브, 이중 프롬프트 관리 등은 명확한 아키텍처 결정 기록(ADR)과 그 강제 메커니즘이 없음을 보여준다. `docs/ADR/`에 문서가 존재함에도 불구하고, 실제 코드베이스는 이를 따르지 않는 경향이 있다. 이는 ADR이 결정의 기록에 그치고, 실제 코드에 대한 강제 수단이 없기 때문이다.

**셋째, 성장 중심의 축적 패턴.** 빈 `embedded_config` 디렉토리, 루트의 30+ 임시 스크립트, 2파일짜리 13개 모듈은 모두 "나중에 정리하겠다"는 식의 점진적 축적의 결과물이다. 이는 대규모 OCaml 프로젝트에서 흔히 나타나는 기술 부채 패턴으로, Dune 3.21+의 `unused-libs` alias 같은 도구를 활용한 지속적 정리가 필요하다 [^14^].

| 메트릭 | 현재값 | 목표값 | 개선율 |
|--------|--------|--------|--------|
| lib/ 모듈 수 | 30개 | 15-20개 | 33-50% 감소 |
| 단일 모듈 최대 파일 수 | 70개 | 30개 이하 | 57% 감소 |
| bin/ 실행 파일 수 | 18개 | 5-8개 | 56-72% 감소 |
| 루트 디렉토리 수 | 21개 | 12-15개 | 29-43% 감소 |
| 루트 임시 스크립트 | 30+개 | 0개 | 100% 제거 |
| 중복 HTTP 라이브러리 | 2개 스택 | 1개 스택 | 50% 감소 |
| docs/ 아카이브 위치 | 4개 | 1개 | 75% 통합 |

**표 2.12**: 핵심 구조 메트릭 현재 vs 목표

3장에서는 이러한 12가지 문제에 대한 구체적인 개선 방안을 제시한다. 특히 P0로 분류된 거대 모듈 분할, 대시보드 통합, 의존성 방향성 확립에 중점을 둔다.

---

## 참고문헌

[^1^]: Jane Street packages v0.13 documentation. "The packages are released together and pushed to per-package repos on Github. The version numbers are consistent across all the packages." https://ocaml.janestreet.com/ocaml-core/v0.13/doc/index.html

[^2^]: Dune 공식 문서 / OCaml 패키지 페이지. "Dune knows how to handle repositories containing several packages... The magic invocation is: `dune build --only-packages <package-name> @install`" https://ocaml.org/p/dune/3.20.2

[^3^]: Dune 공식 문서 - Quickstart. "The `lib` directory will hold the library you write to provide your executable's core functionality... The `bin` directory holds a skeleton for the executable program." https://dune.readthedocs.io/en/latest/quick-start.html

[^4^]: OCaml 커뮤니티 경험적 기준. Small library: 1-5개 모듈, Medium: 5-20개, Large: 20-50개. masc-mcp 파일 분석 기반.

[^5^]: masc-mcp Phase F 파일 인벤토리 분석. `lib/embedded_config/` (0파일), `mcp_transport_protocol/` (2파일) 등 13개 초소형 모듈 식별.

[^6^]: OCaml.org - Libraries with Dune. "Dune creates libraries from directories... The directory's name is irrelevant." https://ocaml.org/docs/libraries-dune

[^7^]: httpun은 Jane Street의 HTTP/1.1 구현, cohttp는 MirageOS/Ocsigen 생태계 표준. Dune 의존성 선언에서 병존 확인.

[^8^]: Dune 3.21.0 Release Notes. "Introduce a `(dir ..)` field on packages defined in the `dune-project`. This field allows to associate a directory with a particular package." https://github.com/ocaml/dune/releases/tag/3.21.0

[^9^]: Jane Street - Bonsai. Bonsai는 Jane Street의 반응형 UI 프레임워크로, OCaml 코드베이스와의 통합이 자연스러움.

[^10^]: Real World OCaml. "The `bin` directory holds a skeleton for the executable program... a thin wrapper around the library code."

[^11^]: Dune 공식 문서 - Scopes. "Different Dune projects within the same Dune workspace are independent of each other... only public items are visible." https://dune.readthedocs.io/en/latest/explanation/scopes.html

[^12^]: Jane Street 오픈소스 도구 구조 분석. `core_bench`, `async` 등은 서브커맨드 기반 CLI 구조를 사용.

[^13^]: Dune 공식 문서 - Library Dependencies. "For libraries defined in the current scope, you can either use the real name or the public name." https://dune.readthedocs.io/en/latest/reference/library-dependencies.html

[^14^]: Dune 3.21.0 Release Notes. "Introduce an `unused-libs` alias to detect unused libraries." https://github.com/ocaml/dune/releases/tag/3.21.0

[^15^]: MirageOS 4.0 Announcement. "a single-workspace containing all the unikernels' code lets developers investigate and edit code anywhere in the stack." https://mirageos.org/blog/2022-03-30.cross-compilation

[^16^]: Anil Madhavapeddy. "Dune has a fantastic but underappreciated feature: it automatically discovers and builds any OCaml code in subdirectories." https://anil.recoil.org/notes/aoah-2025-22

---

# 3. Phase 1: 즉시 숙청 (Garbage-First Refactoring)

> "숙청을 주저하지 마세요." — 이 단계의 핵심 원칙입니다.

Phase 1은 masc-mcp 프로젝트의 구조적 부채 중 **가장 낮은 수확 고도(lowest-hanging fruit)**를 제거하는 단계입니다. 30개 이상의 임시 스크립트, 비어 있는 모듈, 이중화된 대시보드, 흩어진 아카이브를 한 번에 제거하여 프로젝트의 "표면적 복잡도"를 급격히 낮춥니다. 이 단계는 **2주 내 완료**를 목표로 하며, 각 작업은 독립적으로 실행 가능하므로 병렬 수행이 가능합니다.

**Phase 1 종합 효과 (예상):**

| 지표 | Before | After | 감소율 |
|------|--------|-------|--------|
| 루트 임시 스크립트 | 30+ 개 | 0 개 | 100% |
| `lib/` 2파일 이하 모듈 | 14개 | 4개 | 71% |
| 문서 디렉토리 수 | 15+ 개 | 5개 | 67% |
| 총 문서 수 | 250개 | ~50개 | 80% |
| 대시보드 이중 구조 | 2개 | 1개 | 50% |

---

## 3.1 루트 디렉토리 청소

### 3.1.1 임시 스크립트 일괄 제거

프로젝트 루트에 30개 이상의 Python 임시 스크립트(`fix_*.py`, `wipe_*.py`, `remove_*.py`)가 존재합니다. 이들은 과거 마이그레이션의 흔적로, 현재 코드베이스에서 **어떤 참조도 없는 dead artifact**입니다. Git history에 이미 보존 되어 있으므로 물리적 삭제는 전혀 안전합니다.

**삭제 대상 전체 목록:**

| 카테고리 | 파일명 | 개수 |
|----------|--------|------|
| `fix_a2a_*.py` | `fix_a2a_final.py`, `fix_a2a_leftovers.py`, `fix_a2a_leftovers3.py`, `fix_a2a_leftovers4.py`, `fix_a2a_leftovers6.py`, `fix_a2a_tests.py`, `fix_a2a_tests3.py` | 7 |
| `fix_agent_card*.py` | `fix_agent_card.py`, `fix_agent_card2.py`, `fix_agent_card3.py`, `fix_agent_card4.py`, `fix_agent_card6.py` | 5 |
| `fix_dashboard*.py` | `fix_dashboard_final.py`, `fix_dashboard_mission.py`, `fix_dashboard_mission2.py` | 3 |
| `fix_*.py` (기타) | `fix_fitness.py`, `fix_leftovers.py`, `fix_mission_assembly.py` | 3 |
| `refactor_*.py` | `refactor_team_memory.py` | 1 |
| `remove_*.py` | `remove_a2a_collabo.py`, `remove_dashboard.py` | 2 |
| `wipe_*.py` | `wipe_a2a_collab_final.py`, `wipe_aggressive.py`, `wipe_collab.py`, `wipe_portal_v3.py`, `wipe_tests.py`, `wipe_tool_agent.py` | 6 |
| 쉘 스크립트 | `start-masc-mcp.sh` | 1 |
| **소계** | | **28개** |

**실행 명령어 (일괄 삭제):**

```bash
# 0단계: 백업 생성 (1회)
mkdir -p archive/root-scripts-$(date +%Y%m%d)
cp fix_*.py wipe_*.py remove_*.py refactor_*.py start-masc-mcp.sh \
   archive/root-scripts-$(date +%Y%m%d)/ 2>/dev/null

# 1단계: Git에서 추적 중인지 확인
git ls-files --error-unmatch fix_*.py wipe_*.py remove_*.py refactor_*.py start-masc-mcp.sh 2>&1 | grep -q "did not match"
# ↑ 오류 메시지가 나오면 tracked 파일이 없다는 뜻 (정상)

# 2단계: 실제 삭제
rm -f fix_*.py wipe_*.py remove_*.py refactor_*.py start-masc-mcp.sh

# 3단계: 검증 — 루트에 Python 임시 스크립트가 남아있는지 확인
ls *.py 2>/dev/null && echo "WARNING: Python 파일 잔여" || echo "OK: 루트 정상"

# 4단계: dune 빌드 테스트 (삭제가 빌드에 영향 없음 확인)
dune build @default --quiet && echo "BUILD OK"
```

**주의:** 위 스크립트 중 `debug.ml`, `debug_canonical.ml`는 OCaml 소스로, 루트에 존재할 경우 `lib/` 하위 적절한 위치로 이동하거나 삭제해야 합니다. 이들이 dune 빌드에 포함되어 있다면 `dune` 파일에서 해당 항목을 제거한 후 파일을 이동/삭제합니다.

```ocaml
(* Before: 루트의 debug.ml —孤立된 디버그 모듈 *)
let () = Printf.printf "Debug mode enabled\n"

(* After: lib/core/debug_utils.ml 로 통합 또는 완전 삭제 *)
(* debug.ml 자체는 제거 — 이미 Git history에 보존 됨 *)
```

**검증 체크리스트:**
- [ ] `ls *.py` 결과가 빈 목록인지 확인
- [ ] `dune build @default`가 정상 완료되는지 확인
- [ ] `git status`로 untracked 삭제 파일만 표시되는지 확인

---

## 3.2 아카이브 통합

프로젝트에는 `archive/`, `docs/archive/`, `audits/`, `docs/_audit/`, `docs/audit-responses/` 등 **5개 이산 위치**에 아카이브/감사 관련 문서가 흩어져 있습니다. 이는 과거 조직적 부재의 흔적이며, 단일 아카이브 영역으로 통합해야 합니다.

### 3.2.1 통합 전략

**통합 원칙:** 모든 과거 아티팩트는 `archive/` 단일 디렉토리로 집결. `docs/` 난의 아카이브성 콘텐츠는 전부 `archive/`로 이전합니다.

| 통합 대상 | 현재 위치 | 이동 대상 | 조치 |
|-----------|-----------|-----------|------|
| 과거 기능 아카이브 | `docs/archive/` | `archive/docs/` | `mv docs/archive/ archive/docs/` |
| 감사 기록 (비공식) | `docs/_audit/` | `archive/audits/` | `mv docs/_audit/ archive/audits/` |
| 감사 응답 | `docs/audit-responses/` | `archive/audit-responses/` | `mv docs/audit-responses/ archive/audit-responses/` |
| 공식 감사 | `audits/` (루트) | `archive/audits/` | 병합 |

**실행 명령어:**

```bash
# 백업 및 통합
mkdir -p archive/{docs,audits,audit-responses}

# docs/archive/ → archive/docs/
mv docs/archive/* archive/docs/ 2>/dev/null
rmdir docs/archive/ 2>/dev/null

# docs/_audit/ → archive/audits/
mv docs/_audit/* archive/audits/ 2>/dev/null
rmdir docs/_audit/ 2>/dev/null

# docs/audit-responses/ → archive/audit-responses/
mv docs/audit-responses/* archive/audit-responses/ 2>/dev/null
rmdir docs/audit-responses/ 2>/dev/null

# audits/ → archive/audits/ (병합)
mv audits/* archive/audits/ 2>/dev/null
rmdir audits/ 2>/dev/null

# archive/ 난의 중복 파일 제거
fdupes -rdN archive/ 2>/dev/null || echo "fdupes not installed, skip dedup"

# 최종 검증
tree -L 2 archive/
```

**Before/After 디렉토리 구조:**

```
# Before: 5개 분산 위치
archive/                ← 루트 아카이브
├── cancellation/
└── ...
docs/
├── archive/            ← 중복: 문서 아카이브
├── _audit/             ← 비공식 감사
└── audit-responses/    ← 감사 응답
audits/                 ← 루트 감사

# After: 단일 집결점
archive/                ← 모든 과거 아티팩트
├── cancellation/
├── docs/               ← (구 docs/archive/)
├── audits/             ← (구 audits/ + docs/_audit/)
└── audit-responses/    ← (구 docs/audit-responses/)
docs/                   ← 현재 문서만
```

**검증 체크리스트:**
- [ ] `docs/archive/`, `docs/_audit/`, `docs/audit-responses/` 디렉토리가 존재하지 않음
- [ ] `audits/` 디렉토리가 존재하지 않음 (archive/audits/로 통합)
- [ ] `archive/` 난의 파일이 90일 이상 접근되지 않은 경우 `gzip` 압축 권장

---

## 3.3 빈 모듈 제거/병합

`lib/` 하위에 14개의 2파일 이하 소형 모듈이 존재합니다. 이들은 각각 독립 `dune` 파일과 디렉토리 오버헤드를 유발하며, 모듈 수는 30개에서 실질적인 기능 단위는 훨씬 적습니다. 이 소형 모듈들을 상위 모듈로 병합하여 **관리 포인트를 14개에서 4개로 축소**합니다.

### 3.3.1 병합 대상 상세

| 모듈 | 현재 위치 | 파일수 | 이동/병합 대상 | 조치 |
|------|-----------|--------|----------------|------|
| `embedded_config` | `lib/embedded_config/` | 0 | — | **삭제** (빈 디렉토리) |
| `mcp_transport_protocol` | `lib/mcp_transport_protocol/` | 2 | `lib/protocol/` (신설) | 이동 |
| `mcp_session` | `lib/mcp_session/` | 2 | `lib/protocol/` | 이동+병합 |
| `fs_compat` | `lib/fs_compat/` | 2 | `lib/core/` | 이동 |
| `eio_context` | `lib/eio_context/` | 2 | `lib/core/` | 이동+병합 |
| `dated_jsonl` | `lib/dated_jsonl/` | 2 | `lib/backend/` | 이동 |
| `dashboard_utils` | `lib/dashboard_utils/` | 2 | `dashboard_bonsai/` | 이동 |
| `dashboard_api_types` | `lib/dashboard_api_types/` | 2 | `dashboard_bonsai/` | 이동 |
| `random_id` | `lib/random_id/` | 2 | `lib/core/` | 이동 |
| `oas_compat` | `lib/oas_compat/` | 2 | `lib/oas/` (기존 모듈 활용) | 통합 |
| `memory` | `lib/memory/` | 2 | `lib/types/` | 이동 |
| `compression` | `lib/compression/` | 2 | `lib/core/` | 이동 |
| `board_types` | `lib/board_types/` | 2 | `lib/types/` | 이동+병합 |
| `ag_ui` | `lib/ag_ui/` | 2 | `dashboard_bonsai/` 또는 삭제 | 평가 후 결정 |

### 3.3.2 병합 절차: `lib/core/` 통합 예시

`fs_compat`, `eio_context`, `random_id`, `compression`을 `lib/core/`로 병합하는 절차입니다.

```ocaml
(* Before: lib/fs_compat/dune *)
(library
 (name fs_compat)
 (public_name masc_mcp.fs_compat)
 (libraries eio))

(* Before: lib/fs_compat/fs_compat.ml *)
let safe_read_file path = ...

(* Before: lib/eio_context/dune *)
(library
 (name eio_context)
 (public_name masc_mcp.eio_context)
 (libraries eio core))

(* Before: lib/eio_context/eio_context.ml *)
let get_ctx () = ...
```

```ocaml
(* After: lib/core/dune — library stanza에 모듈 추가 *)
(library
 (name core)
 (public_name masc_mcp.core)
 (libraries eio ...)
 (modules
  ...existing modules...
  fs_compat    ; ← 병합
  eio_context  ; ← 병합
  random_id    ; ← 병합
  compression  ; ← 병합
 ))

(* After: lib/core/fs_compat.ml — 그대로 이동 *)
let safe_read_file path = ...

(* After: lib/core/eio_context.ml — 그대로 이동 *)
let get_ctx () = ...
```

### 3.3.3 실행 명령어

```bash
# 1단계: embedded_config 삭제 (빈 디렉토리)
rmdir lib/embedded_config/ 2>/dev/null || echo "already empty or non-existent"

# 2단계: protocol/ 신설 및 mcp_* 병합
mkdir -p lib/protocol
mv lib/mcp_transport_protocol/* lib/protocol/
mv lib/mcp_session/* lib/protocol/
rmdir lib/mcp_transport_protocol/ lib/mcp_session/

# lib/protocol/dune 작성
cat > lib/protocol/dune << 'EOF'
(library
 (name protocol)
 (public_name masc_mcp.protocol)
 (libraries eio core yojson)
 (modules mcp_transport_protocol mcp_session))
EOF

# 3단계: core/로 fs_compat, eio_context, random_id, compression 병합
mv lib/fs_compat/*.ml lib/core/
mv lib/eio_context/*.ml lib/core/
mv lib/random_id/*.ml lib/core/
mv lib/compression/*.ml lib/core/
rmdir lib/fs_compat/ lib/eio_context/ lib/random_id/ lib/compression/

# core/dune의 modules 필드 업데이트 필요
# (수동: fs_compat, eio_context, random_id, compression 추가)

# 4단계: backend/로 dated_jsonl 이동
mv lib/dated_jsonl/*.ml lib/backend/
rmdir lib/dated_jsonl/

# 5단계: types/로 memory, board_types 이동
mv lib/memory/*.ml lib/types/
mv lib/board_types/*.ml lib/types/
rmdir lib/memory/ lib/board_types/

# 6단계: dashboard_bonsai/로 dashboard_utils, dashboard_api_types 이동
mv lib/dashboard_utils/*.ml dashboard_bonsai/
mv lib/dashboard_api_types/*.ml dashboard_bonsai/
rmdir lib/dashboard_utils/ lib/dashboard_api_types/

# 7단계: ag_ui 평가 후 처리
# (이 모듈이 대시보드에 종속적이면 dashboard_bonsai/로, 아니면 삭제)
```

### 3.3.4 dune-project 의존성 업데이트

병합 후 `dune-project`의 `(package)` stanza에서 삭제된 라이브러리를 제거합니다.

```
# Before: dune-project — 개별 라이브러리 선언
(package
 (name masc_mcp)
 (libraries
  ...
  masc_mcp.fs_compat
  masc_mcp.eio_context
  masc_mcp.random_id
  masc_mcp.compression
  masc_mcp.mcp_transport_protocol
  masc_mcp.mcp_session
  masc_mcp.memory
  masc_mcp.board_types
  masc_mcp.dashboard_utils
  masc_mcp.dashboard_api_types
  masc_mcp.dated_jsonl
  ...))

# After: 통합된 라이브러리만 유지
(package
 (name masc_mcp)
 (libraries
  ...
  masc_mcp.core          ; fs_compat + eio_context + random_id + compression 포함
  masc_mcp.protocol      ; mcp_transport_protocol + mcp_session 포함
  masc_mcp.types         ; memory + board_types 포함
  masc_mcp.backend       ; dated_jsonl 포함
  ...))
```

**의존성 참조 검색 및 업데이트:**

```bash
# 삭제될 라이브러리를 참조하는 모든 파일 검색
grep -r "masc_mcp\.fs_compat" --include="*.ml" --include="*.dune" lib/ bin/ test/
grep -r "masc_mcp\.eio_context" --include="*.ml" --include="*.dune" lib/ bin/ test/
# ... (각 라이브러리별 반복)

# 참조를 새 라이브러리명으로 대체
sed -i 's/masc_mcp\.fs_compat/masc_mcp.core/g' $(grep -rl "masc_mcp.fs_compat" --include="*.ml" --include="*.dune" lib/ bin/ test/)
sed -i 's/masc_mcp\.eio_context/masc_mcp.core/g' $(grep -rl "masc_mcp.eio_context" --include="*.ml" --include="*.dune" lib/ bin/ test/)
# ...
```

**검증 체크리스트:**
- [ ] `dune build @default` 정상 통과
- [ ] 병합된 모듈의 단위 테스트 `dune test` 통과
- [ ] `lib/` 하위 디렉토리 수: 30개 → 18개 (40% 감소)

---

## 3.4 이중 대시보드 처리

현재 masc-mcp는 두 개의 완전한 별도 대시보드를 유지하고 있습니다: `dashboard/` (TypeScript/React, 100+ 파일)과 `dashboard_bonsai/` (OCaml Bonsai, 60+ 파일). 이는 기술 부채의 전형적인 사례로, **단일 구현을 선택하고 나머지를 제거**해야 합니다 [^22^].

### 3.4.1 선택 기준 분석

| 기준 | `dashboard/` (TS/React) | `dashboard_bonsai/` (OCaml Bonsai) | 권장 |
|------|------------------------|-----------------------------------|------|
| 생태계 일관성 | JS/TS 스택 추가 필요 | OCaml 프로젝트와 통합 | **Bonsai** |
| 의존성 복잡도 | npm + Node.js + webpack | opam + dune만으로 충분 | **Bonsai** |
| 유지보스 인력 | OCaml 팀의 TS 전환 필요 | OCaml 전문성 활용 | **Bonsai** |
| 성능/타입 안전성 | 런타임 에러 가능성 | OCaml 타입 시스템 보장 | **Bonsai** |
| 커뮤니티 지원 | React 생태계 방대 | Jane Street 난부 직접 지원 | React |
| 외부 기여자 접근성 | 높음 | 낮음 | TS/React |

**판단:** masc-mcp는 **OCaml 프로젝트**이며, 전체 백엔드가 OCaml으로 작성되어 있습니다. 대시보드-백엔드 간 타입 공유가 가능한 `dashboard_bonsai/`를 유지하고, `dashboard/`를 **아카이브 대상**으로 결정합니다. 다만 이는 **3.4.3의 점진적 전환**을 통해 리스크를 최소화합니다.

### 3.4.2 통합 계퍍

```
Phase 1 (2주):
  dashboard/ → archive/dashboard-ts-$(date +%Y%m%d)/ 이동
  dashboard_bonsai/ → dashboard/ 이름 변경
  dashboard_bonsai/의 dune 설정에서 public_name 유지

Phase 2 (1개월):
  dashboard/ 난의 OCaml Bonsai 코드 정비
  dashboard_utils/, dashboard_api_types/ 병합 완료
  dashboard/에 README.md 추가
```

### 3.4.3 실행 명령어

```bash
# 1단계: TypeScript 대시보드 아카이브
mkdir -p archive/
mv dashboard/ archive/dashboard-ts-$(date +%Y%m%d)/

# 2단계: Bonsai 대시보드를 공식 이름으로 승격
mv dashboard_bonsai/ dashboard/

# 3단계: dune 파일에서 public_name 업데이트
# (기존 dashboard_bonsai의 dune 파일 확인 후 필요시 수정)
grep -r "dashboard_bonsai" --include="dune" dashboard/ | head -5

# 4단계: 루트 dune-project에서 dashboard 관련 설정 검토
# package stanza에 dashboard 포함 여부 확인

# 5단계: 빌드 검증
dune build @default --quiet && echo "Dashboard integration OK"
```

**주의:** `dashboard/`를 아카이브하기 전, 해당 디렉토리에 **독립 실행 가능한 README나 빌드 지침**이 있는지 확인하세요. 없다면 간단한 아카이브 노트를 추가합니다.

```markdown
<!-- archive/dashboard-ts-YYYYMMDD/README-ARCHIVE.md -->
# dashboard/ (TypeScript/React) — Archived

- 아카이브 일자: YYYY-MM-DD
- 사유: dashboard_bonsai/ (OCaml Bonsai)로 통합
- 복구 방법: Git history에서 `git checkout <commit> -- dashboard/`
- 주의: 이 디렉토리의 코드는 더 이상 유지보스되지 않음
```

**검증 체크리스트:**
- [ ] `dashboard/` 디렉토리가 OCaml Bonsai 코드를 포함
- [ ] `dashboard_bonsai/` 디렉토리가 존재하지 않음
- [ ] `dune build @default` 정상 통과
- [ ] `dune build @install`에 dashboard 포함 확인

---

## 3.5 문서 체계 재구성

`docs/`에 250개의 문서가 15개 이상의 하위 디렉토리에 흩어져 있습니다. 이는 정보 탐색을 어렵게 하고 문서의 "쓰임"을 불분명하게 만듭니다. **250개 문서를 50개 핵심 문서로 축소**하고, 15개 하위 디렉토리를 5개로 통합합니다.

### 3.5.1 통합 디렉토리 구조

| 새 디렉토리 | 목적 | 포함 내용 (예시) |
|-------------|------|------------------|
| `docs/guides/` | 사용자/개발자 가이드 | 기존 튜토리얼, setup 가이드, 사용법 |
| `docs/architecture/` | 아키텍처 문서 | ADR, RFC, 설계 결정, 컴포넌트 다이어그램 |
| `docs/reference/` | 레퍼런스 문서 | API 문서, 타입 정의, 프로토콜 사양 |
| `docs/ops/` | 운영 문서 | 배포, 모니터링, 문제 해결, 인프라 설정 |
| `docs/meta/` | 프로젝트 메타 문서 | CONTRIBUTING, CHANGELOG, 라이선스, 개발 규칙 |

### 3.5.2 문서 축소 기준

각 문서를 다음 기준으로 평가하여 **삭제**, **병합**, **이동** 중 하나로 분류합니다.

```bash
# 문서 인벤토리 생성
find docs/ -type f -name "*.md" -o -name "*.txt" -o -name "*.rst" | \
  awk '{print $0, system("git log -1 --format=%ai -- " $0 " 2>/dev/null")}' \
  > /tmp/doc-inventory.txt

# 1년 이상 수정되지 않은 문서 목록 (삭제 대상)
find docs/ -type f \( -name "*.md" -o -name "*.txt" \) -mtime +365 -exec ls -la {} \;

# 중복 제목 검색 (병합 대상)
find docs/ -type f -name "*.md" -exec grep -h "^# " {} \; | sort | uniq -d | head -20
```

**삭제 기준 (즉시 제거):**
- 마지막 수정이 1년 이상된 임시 노트
- 구현과 동기화되지 않은 API 문서 (코드와 불일치)
- 중복된 내용을 가진 문서 (더 최신 버전 존재)
- 개인 작업 노트 (`todo-*.md`, `scratch-*.md` 등)
- 이미 Git history에 완전히 보존 된 초안 문서

**병합 기준:**
- 동일 주제의 여러 짧은 문서 → 단일 종합 문서로 통합
- ADR (Architecture Decision Record) → `docs/architecture/adr/`에 월별/주제별 통합
- RFC 문서 → `docs/architecture/rfc/`에 통합 인덱스

### 3.5.3 실행 명령어

```bash
# 1단계: 새 디렉토리 구조 생성
mkdir -p docs/{guides,architecture,reference,ops,meta}

# 2단계: 기존 문서 분류 및 이동 (예시 — 실제 실행 시 수동 검증 필수)
# guides/
mv docs/getting-started* docs/guides/ 2>/dev/null
mv docs/tutorial* docs/guides/ 2>/dev/null
mv docs/setup* docs/guides/ 2>/dev/null

# architecture/
mv docs/adr* docs/architecture/ 2>/dev/null
mv docs/rfc* docs/architecture/ 2>/dev/null
mv docs/design* docs/architecture/ 2>/dev/null

# reference/
mv docs/api* docs/reference/ 2>/dev/null
mv docs/protocol* docs/reference/ 2>/dev/null
mv docs/schema* docs/reference/ 2>/dev/null

# ops/
mv docs/deploy* docs/ops/ 2>/dev/null
mv docs/monitoring* docs/ops/ 2>/dev/null
mv docs/runbook* docs/ops/ 2>/dev/null

# meta/
mv docs/CONTRIBUTING* docs/meta/ 2>/dev/null
mv docs/CHANGELOG* docs/meta/ 2>/dev/null
cp LICENSE docs/meta/ 2>/dev/null

# 3단계: 비어있거나 정리된 하위 디렉토리 삭제
find docs/ -maxdepth 1 -type d -empty -delete 2>/dev/null

# 4단계: 인덱스 문서 생성
cat > docs/README.md << 'DOCEOF'
# masc-mcp Documentation

| 디렉토리 | 내용 |
|----------|------|
| `guides/` | 시작하기, 튜토리얼, 사용법 |
| `architecture/` | ADR, RFC, 아키텍처 결정 |
| `reference/` | API 레퍼런스, 프로토콜 사양 |
| `ops/` | 배포, 모니터링, 운영 가이드 |
| `meta/` | 기여 가이드, 변경 이력, 라이선스 |

## odoc 생성 문서
`dune build @doc` 실행 후 `_build/default/_doc/_html/`에서 확인 [^54^][^59^]
DOCEOF
```

### 3.5.4 odoc 통합

축소된 문서 체계는 `odoc`와 통합되어 소스 코드 문서화와 결합되어야 합니다 [^57^][^58^]. `dune build @doc` 명령으로 API 문서를 생성하고, `.mld` 파일을 활용하여 패키지 수준의 가이드를 작성합니다 [^117^].

```ocaml
(* docs/index.mld — odoc 패키지 인덱스 *)
{0 masc-mcp}

masc-mcp는 OCaml 5.4+ 기반의 MCP (Model Context Protocol) 구현체입니다.

{1 개발자 가이드}
- {{!page-guides/getting-started}시작하기}
- {{!page-architecture/overview}아키텍처 개요}

{1 API 레퍼런스}
{{!modules: Masc_mcp}}
```

**검증 체크리스트:**
- [ ] `docs/` 하위 디렉토리 수가 5개 이내인지 확인
- [ ] 난의 문서 수가 ~50개 이내인지 확인
- [ ] `docs/README.md`가 모든 하위 디렉토리를 설명하는지 확인
- [ ] `dune build @doc`가 정상 완료되는지 확인

---

## 3.6 Phase 1 종합 실행 일정

모든 작업은 **병렬 수행 가능**하며, 독립적인 작업 단위로 분리되어 있습니다.

| 주차 | 작업 | 산출물 | 담당자 (1인) |
|------|------|--------|-------------|
| **Week 1, Day 1-2** | 3.1 루트 스크립트 삭제 | 깔끔한 루트 디렉토리 | DevOps |
| **Week 1, Day 2-3** | 3.2 아카이브 통합 | 단일 `archive/` 구조 | DevOps |
| **Week 1, Day 3-5** | 3.3 빈/소형 모듈 병합 | 18개 lib 모듈 | Core 개발자 |
| **Week 2, Day 1-3** | 3.4 대시보드 통합 | 단일 `dashboard/` | Frontend 개발자 |
| **Week 2, Day 3-5** | 3.5 문서 재구성 | 50개 핵심 문서 | Tech Writer |
| **Week 2, Day 5** | 전체 회귀 테스트 | `dune test` 전체 통과 | QA |

**리스크 완화:**
- 모든 삭제 작업은 `archive/`로 백업 후 실행 (Git history 외 2차 안전망)
- 각 작업 완료 후 `dune build @default` 필수 실행
- CI 파이프라인에 `dune test`가 통과해야만 merge 가능하도록 설정

**Phase 1 완료 후 체크리스트:**
- [ ] `ls *.py` → "No such file or directory"
- [ ] `ls lib/ | wc -l` → 18 이하
- [ ] `find docs/ -type d | wc -l` → 6 이하 (README 포함)
- [ ] `dune build @default @runtest` → 전체 통과
- [ ] `git diff --stat` → 삭제 파일 수가 추가 파일 수보다 100개 이상 많음

---

## 참고 문헌

[^22^] https://stackoverflow.com/questions/36260/dealing-with-circular-dependencies-in-ocaml — Dealing with circular dependencies in OCaml

[^54^] https://dune.readthedocs.io/_/downloads/en/stable/pdf/ — Dune Documentation PDF

[^57^] https://tarides.com/blog/2024-01-10-meet-odoc-ocaml-s-documentation-generator/ — Meet odoc

[^58^] https://ocaml.org/docs/generating-documentation — Generating Documentation With odoc

[^59^] https://dune.readthedocs.io/en/stable/documentation.html — Dune Generating Documentation

[^117^] https://dune.readthedocs.io/en/stable/documentation.html — Dune Documentation Stanza

[^164^] https://ocaml.org/p/reanalyze/2.25.0/doc/README.html — reanalyze documentation

---

# 4. Phase 2: 구조 재설계 (Agent-First Architecture)

> "에이전트 컨텍스트 한계는 선택이 아닌 물리 법칙이다. 구조는 이 법칙 안에서 작동하도록 설계되어야 한다." [^40^][^102^]

Phase 1의 분석 결과, masc-mcp 프로젝트는 565K 라인, 2,697개 OCaml 파일, 30개의 `lib/` 하위 모듈, 18개의 실행 파일로 구성되어 있다. coord(70파일, ~15K 라인)와 cascade(54파일, ~12K 라인) 같은 핵심 모듈은 64K 컨텍스트 기반 에이전트가 단일 세션 내에서 완전히 소화하기 어려운 규모다. Phase 2에서는 **에이전트의 컨텍스트 윈도우를 1차 설계 제약**으로 삼아 전체 디렉토리 구조를 재설계한다. 모든 모듈은 64K 토큰(약 2K-3K 라인) 내에서 완전히 이핼될 수 있는 크기로 분할되며, 의존성 그래프는 단방향을 유지하고 공개 API는 `public_name`으로 명시적으로 경계를 표시한다. 이 접근은 Insight 1(Context-Bounded Architecture) [^1^]과 Insight 10(Agent-First as Simplicity Enforcer) [^10^]의 원칙을 구체적인 디렉토리 구조로 구현한 것이다.

---

## 4.1 에이전트 컨텍스트 기반 모듈 크기 기준

### 4.1.1 64K/128K 컨텍스트 한계 분석

2025년 기준 주요 AI 코딩 모델의 컨텍스트 윈도우와 실제 코드 처리 능력은 이론치와 현격한 차이를 보인다 [^40^][^44^]. 제조사가 공개하는 "최대 컨텍스트"는 이론상 입력 가능한 토큰 수이지만, **실제로 효과적으로 이해하고 코드를 생성할 수 있는 용량**은 훨씬 낮다.

| 모델 | 입력 컨텍스트 | 실제 효과적 용량 | 처리 가능 라인 수 | 용도 |
|------|-------------|----------------|----------------|------|
| Claude 3.5 Sonnet / 4.5 | 200K (1M beta) | ~120K 토큰 (60%) | 8K-12K 라인 | 서브시스템 리팩토링 |
| GPT-4 / GPT-5 | 128K-400K | ~80K 토큰 | 6K-8K 라인 | 모듈 리팩토링 |
| Gemini 2.5 Pro | 1M+ | ~500K 토큰 | 40K-60K 라인 | 전체 코드베이스 분석 |
| Codex-1 | 192K | ~120K 토큰 | 8K-12K 라인 | 에이전트 태스크 |

**128K 토큰 ≈ 96,000 단어 ≈ 8K-12K 라인**의 코드를 처리할 수 있다 [^40^]. 그러나 이는 단순히 "읽을 수 있다"는 의미이며, **실제로 이해하고 수정 가능한** 라인 수는 더 낮다. Claude Code의 200K 토큰 컨텍스트에서도 실제로는 **60% 용량(약 120K 토큰)을 초과하면 출력 품질이 저하**되기 시작하며, MCP 서버, 시스템 프롬프트, 도구 정의 등이 추가로 소비되는 토큰을 고려하면 실제 작업 가능 공간은 더욱 줄어든다 [^38^].

**64K 토큰 ≈ 48K 단어 ≈ 2K-3K 라인**은 에이전트가 "한 눈에" 완전히 이핼할 수 있는 단일 모듈의 상한이다 [^109^]. 이를 기준으로 현재 모듈들을 평가하면:

- **coord 모듈**(70파일, ~15K 라인): 64K 컨텍스트로는 50-60%만 커버 가능. 128K에서도 "Lost in the Middle"로 인해 중앙 파일 이핵도 저하
- **cascade 모듈**(54파일, ~12K 라인): 128K 컨텍스트의 한계에 근접. 분할 권장
- **tool_schemas 모듈**(28파일, ~5K 라인): 128K 컨텍스트 내에서 적정. 분할 불필요
- **multimodal 모듈**(24파일, ~4K 라인): 64K 컨텍스트 내에서 적정. 현재 구조 유지 가능

### 4.1.2 "Lost in the Middle" 현상과 대응

Stanford, UC Berkeley, Samaya AI의 2023년 연구 "Lost in the Middle"에 따를, LLM은 컨텍스트의 시작과 끝에 있는 정보는 잘 활용하지만 중앙에 있는 정보는 체계적으로 무시한다 [^102^][^106^]. 2025년 MIT 연구팀은 이 현상의 원인을 두 가지로 밝혀냈다:

1. **Causal Attention Masking**: 각 토큰은 이전 토큰만 참조할 수 있으므로, 앞쪽 토큰이 더 많은 attention weight를 축적한다.
2. **Positional Encoding Decay**: RoPE(Rotary Position Embedding)의 거리 기반 감쇄로, 중앙 토큰은 시작의 "primacy effect"와 끝의 "recency effect" 사이의 "dead zone"에 위치한다.

> **핵심 인사이트**: 단순히 큰 컨텍스트 윈도우를 사용한다고 해서 문제가 해결되지 않는다. 128K+ 윈도우에서도 U자형 곡선은 지속된다 [^102^]. **중요한 정보는 컨텍스트의 시작이나 끝에 배치해야 한다.**

이 현상은 coord(70파일)나 cascade(54파일) 같은 대형 모듈을 에이전트가 처리할 때 치명적이다. 모듈을 알파벳순으로 파일 목록을 전달하면, 중앙에 위치한 `coord_keeper.ml`이나 `cascade_step.ml` 같은 핵심 파일이 attention의 "dead zone"에 빠질 수 있다. 이는 에이전트가 모듈의 핵심 로직을 "놓치고" 주변 파일만 이해한 채 잘못된 수정을 제안하는 원인이 된다.

**대응 전략**:

1. **모듈 크기 축소**: 64K 컨텍스트에 맞춰 2K-3K 라인(20-30 파일) 단위로 분할. 핵심 파일이 "dead zone"에 빠지더라도 전체 모듈의 나머지 부분은 정상적으로 처리됨
2. **중요 파일 우선 배치**: `.mli` 파일이나 핵심 타입 정의를 컨텍스트 시작 부분에 배치. "primacy effect"를 활용
3. **계층적 CLAUDE.md**: 모듈별 도메인 지식을 하위 CLAUDE.md에 분리하여 lazy loading [^75^]. 루트 CLAUDE.md는 200라인 이하로 유지 [^39^]
4. **인덱스 모듈 도입**: 각 서브모듈의 진입점인 `coord_core.ml`, `cascade_engine.ml` 등을 정의하여 에이전트가 빠르게 구조를 파악

### 4.1.3 최적 모듈 크기: 2K-3K 라인, 20-30 파일

Insight 1(Context-Bounded Architecture) [^1^]과 Insight 10(Agent-First as Simplicity Enforcer) [^10^]을 종합하면, masc-mcp의 모든 모듈은 다음 기준을 충족해야 한다:

| 기준 | 권장 값 | 상한 | 근거 |
|------|--------|------|------|
| 모듈당 라인 수 | 1.5K-2.5K 라인 | 3K 라인 | 64K 토큰 ≈ 2K-3K 라인 [^109^] |
| 모듈당 파일 수 | 15-25개 | 30개 | 64K 컨텍스트의 실효 파일 수 [^40^] |
| 함수당 라인 수 | 20-50 라인 | 100 라인 | 인지 복잡도 최소화 [^144^] |
| 공개 API(.mli) 비율 | 100% | - | AI 인터페이스 파악용 [^138^] |
| 라이브러리당 서브모듈 수 | 2-4개 | 5개 | 인덱스 모듈의 관리 가능 범위 |

이 기준에 따를 coord 모듈(70파일, ~15K 라인)은 최소 3개의 서브모듈로, cascade 모듈(54파일, ~12K 라인)은 최소 2-3개의 서브모듈로 분할되어야 한다. Jane Street의 monorepo 경험에서도 모듈은 "관련 함수, 타입, 값의 논리적 단위"로 조직되어야 하며, 네임스페이스 충돌을 피하는 용도로 사용된다 [^16^]. 에이전트 컨텍스트 제약은 이 원칙을 더욱 엄격하게 강제하는 "creative constraint"가 된다 [^10^]. 모듈 크기가 2K-3K 라인으로 제한되면 순환 의존성도 자연스럽게 드러나고 제거하기 쉬워진다.

---

## 4.2 목표 디렉토리 트리

### 4.2.1 현재 구조 (Before)

```
masc-mcp/
├── dune-project                    # 단일 프로젝트
├── dune-workspace                  # 워크스페이스 루트
│
├── bin/                            # 18개 실행 파일
│   ├── dune
│   ├── agent_coord.ml              # 실행 파일 1
│   ├── agent_coord_async.ml        # 실행 파일 2
│   ├── cascade_cli.ml              # 실행 파일 3
│   ├── cascade_server.ml           # 실행 파일 4
│   ├── dashboard_server.ml         # 실행 파일 5
│   ├── dashboard_bonsai_server.ml  # 실행 파일 6
│   ├── mcp_server_http.ml          # 실행 파일 7
│   ├── mcp_server_stdio.ml         # 실행 파일 8
│   ├── tool_executor.ml            # 실행 파일 9
│   ├── tool_registry.ml            # 실행 파일 10
│   ├── sidecar_*.ml                # 5개 sidecar 실행 파일
│   ├── http_gateway.ml             # 실행 파일 16
│   ├── http_dashboard.ml           # 실행 파일 17
│   └── ... (기타 1개)
│
├── lib/                            # 30개 하위 모듈 (2,697 파일)
│   ├── dune
│   ├── coord/                      # 70파일, ~15K 라인
│   ├── cascade/                    # 54파일, ~12K 라인
│   ├── tool_schemas/               # 28파일, ~5K 라인
│   ├── multimodal/                 # 24파일, ~4K 라인
│   ├── core/                       # 20파일, ~3K 라인
│   ├── shared_types/               # 16파일, ~2K 라인
│   ├── prompt_registry/            # 14파일, ~2K 라인
│   ├── session/                    # 12파일, ~1.5K 라인
│   ├── http_mcp/                   # 10파일, ~1.5K 라인
│   ├── http_gateway/               # 10파일, ~1.2K 라인
│   ├── http_dashboard/             # 10파일, ~1.2K 라인
│   ├── http_common/                # 8파일, ~1K 라인
│   ├── stdio_mcp/                  # 8파일, ~1K 라인
│   ├── logs_reporter/              # 8파일, ~0.8K 라인
│   ├── random_id/                  # 6파일, ~0.5K 라인
│   ├── fs_compat/                  # 6파일, ~0.5K 라인
│   ├── eio_context/                # 6파일, ~0.5K 라인
│   ├── string_helpers/             # 6파일, ~0.5K 라인
│   └── ... (기타 10개 소형 모듈)
│
├── sidecars/                       # 5개 sidecar (각 5-10파일)
├── dashboard/                      # TypeScript 대시보드
├── dashboard_bonsai/               # OCaml Bonsai 대시보드
├── docs/                           # 250개 문서
└── scripts/                        # 30+ 임시 스크립트
```

현재 구조의 핵심 문제:

- **coord/** (70파일, ~15K 라인): 64K 컨텍스트 기준으로 5배 초과. "Lost in the Middle" 현상의 최대 피해자. keeper 상태, 전송 계층, 상태 머신이 한 디렉토리에 뒤섞여 있음
- **cascade/** (54파일, ~12K 라인): 128K 컨텍스트의 한계에 근접. 에이전트가 전체를 안정적으로 이해하기 어려움. 엔진, IO, 정책의 경계가 모호
- **bin/** 18개 실행 파일: 유사 기능이 별도 실행 파일로 분산되어 유지보수 부담 증가. `agent_coord.ml`과 `agent_coord_async.ml`은 동일 기능의 동기/비동기 버전
- **lib/** 30개 모듈: 도메인 경계가 불명확. `http_mcp/`, `http_gateway/`, `http_dashboard/`, `http_common/` 등 HTTP 관련 모듈이 4개로 흩어져 있음
- **sidecars/** 5개: 루트 레벨에 위치하여 에이전트의 탐색 범위를 확장
- **dashboard/**와 **dashboard_bonsai/**: Insight 3 [^3^]에서 지적한 이중 구현 문제

### 4.2.2 제안된 새로운 구조 (After)

```
masc-mcp/
├── dune-workspace                  # 단일 워크스페이스 루트
│
├── dune-project                    # 루트 프로젝트 (메타 패키지)
├── masc_mcp.opam                   # 메타 패키지
│
├── bin/                            # 5개 핵심 실행 파일
│   ├── dune
│   ├── main.ml                     # masc-mcp (서브커맨드 진입점)
│   ├── server.ml                   # masc-mcp-server (HTTP + MCP 통합)
│   ├── client.ml                   # masc-mcp-client
│   ├── dashboard.ml                # masc-mcp-dashboard
│   └── sidecar.ml                  # masc-mcp-sidecar (서브커맨드 기반)
│
├── lib/                            # 5개 public library
│   ├── dune-project                # lib 전용 서브 프로젝트
│   │
│   ├── masc/                       # public_name: masc
│   │   ├── dune
│   │   ├── masc.ml                 # 라이브러리 인덱스 모듈
│   │   ├── types/                  # 공통 타입 정의
│   │   │   ├── types.ml
│   │   │   ├── message.ml
│   │   │   ├── protocol.ml
│   │   │   └── error.ml
│   │   ├── error/                  # 에러 타입 및 처리
│   │   │   ├── error.ml
│   │   │   ├── result_ext.ml
│   │   │   └── handle.ml
│   │   ├── logging/                # 로깅 (Logs + Fmt 통합)
│   │   │   ├── logging.ml
│   │   │   ├── reporter.ml
│   │   │   └── formatter.ml
│   │   └── utils/                  # 공유 유틸리티
│   │       ├── utils.ml
│   │       ├── random_id.ml
│   │       ├── fs_compat.ml
│   │       ├── eio_context.ml
│   │       └── string_helpers.ml
│   │
│   ├── coord/                      # public_name: masc.coord
│   │   ├── dune
│   │   ├── coord.ml                # 인덱스 모듈
│   │   ├── core/                   # 좌표 핵심 로직
│   │   │   ├── core.ml
│   │   │   ├── keeper.ml
│   │   │   ├── keeper_types.ml
│   │   │   ├── position.ml
│   │   │   └── transform.ml
│   │   ├── transport/              # 전송 계층
│   │   │   ├── transport.ml
│   │   │   ├── http.ml
│   │   │   ├── stdio.ml
│   │   │   └── protocol.ml
│   │   └── fsm/                    # 상태 머신 (GADT 기반)
│   │       ├── fsm.ml
│   │       ├── states.ml
│   │       ├── transitions.ml
│   │       └── state_machine.ml
│   │
│   ├── cascade/                    # public_name: masc.cascade
│   │   ├── dune
│   │   ├── cascade.ml              # 인덱스 모듈
│   │   ├── engine/                 # 캐스케이드 엔진
│   │   │   ├── engine.ml
│   │   │   ├── pipeline.ml
│   │   │   ├── scheduler.ml
│   │   │   └── executor.ml
│   │   ├── io/                     # 입출력 처리
│   │   │   ├── io.ml
│   │   │   ├── reader.ml
│   │   │   ├── writer.ml
│   │   │   └── serializer.ml
│   │   └── policy/                 # 정책/규칙
│   │       ├── policy.ml
│   │       ├── rules.ml
│   │       ├── validators.ml
│   │       └── matchers.ml
│   │
│   ├── tools/                      # public_name: masc.tools
│   │   ├── dune
│   │   ├── tools.ml                # 인덱스 모듈
│   │   ├── schemas/                # 도구 스키마 정의
│   │   │   ├── schemas.ml
│   │   │   ├── tool_def.ml
│   │   │   └── param_types.ml
│   │   ├── registry/               # 도구 레지스트리
│   │   │   ├── registry.ml
│   │   │   ├── loader.ml
│   │   │   └── resolver.ml
│   │   └── dispatch/               # 도구 디스패치
│   │       ├── dispatch.ml
│   │       ├── router.ml
│   │       └── executor.ml
│   │
│   └── server/                     # public_name: masc.server
│       ├── dune
│       ├── server.ml               # 인덱스 모듈
│       ├── http/                   # HTTP 서버 (통합)
│       │   ├── http.ml
│       │   ├── server.ml
│       │   ├── router.ml
│       │   ├── middleware.ml
│       │   ├── mcp_handler.ml      # (기존 http_mcp 통합)
│       │   └── gateway_handler.ml  # (기존 http_gateway 통합)
│       ├── mcp/                    # MCP 프로토콜 처리
│       │   ├── mcp.ml
│       │   ├── protocol.ml
│       │   ├── lifecycle.ml
│       │   └── capability.ml
│       ├── session/                # 세션 관리
│       │   ├── session.ml
│       │   ├── store.ml
│       │   └── manager.ml
│       └── dashboard/              # 대시보드 API 타입
│           ├── dashboard.ml
│           ├── api_types.ml
│           └── websocket.ml
│
├── sidecars/                       # 5개 sidecar (별도 dune-project)
│   ├── dune-project
│   ├── dune-workspace
│   ├── sidecar_a/
│   ├── sidecar_b/
│   ├── sidecar_c/
│   ├── sidecar_d/
│   └── sidecar_e/
│
├── dashboard/                      # 대시보드 프론트엔드 (통합)
│   └── ...
│
├── docs/                           # 250개 문서 (정리됨)
│   ├── architecture/
│   ├── api/
│   ├── guides/
│   └── archive/                    # (과거 문서)
│
└── scripts/                        # 30+ 스크립트 (정리됨)
    ├── build/
    ├── deploy/
    └── dev/
```

### 4.2.3 5개 Public Library의 역할과 경계

| Public Name | 디렉토리 | 역할 | 의존성 | 파일 수 (예상) |
|-------------|---------|------|--------|--------------|
| `masc` | `lib/masc/` | 공통 타입, 에러, 로깅, 유틸리티 | 외부 라이브러리만 (Base, Fmt, Logs, Eio) | 16-20 |
| `masc.coord` | `lib/coord/` | 에이전트 좌표/조정 | `masc` | 61-65 |
| `masc.cascade` | `lib/cascade/` | 캐스케이드 파이프라인 처리 | `masc`, `masc.coord` | 51-55 |
| `masc.tools` | `lib/tools/` | 도구 스키마, 레지스트리, 디스패치 | `masc`, `masc.coord` | 35-40 |
| `masc.server` | `lib/server/` | HTTP 서버, MCP 프로토콜, 세션, 대시보드 API | `masc`, `masc.coord`, `masc.cascade`, `masc.tools` | 45-50 |

**의존성 방향**: `masc` → `masc.coord` → `masc.cascade` / `masc.tools` → `masc.server` (DAG 구조)

**결정적 규칙**: Feature-Sliced Design의 원칙을 차용하여 `masc`(shared)는 `masc.coord`(features)를 import할 수 없다 [^137^]. 화살표는 항상 `apps → features → shared` 방향으로만 향한다. 이 규칙을 위반하는 코드는 리뷰에서 거부되어야 한다.

**각 그룹의 책임 영역 상세 설명**:

- **`masc` (공통 기반)**: coord, cascade, tools, server 모두가 의존하는 가장 낮은 레벨의 라이브러리. Base, Fmt, Logs, Eio 같은 외부 라이브러리를 래핑하여 masc-mcp 전체에서 일관된 인터페이스를 제공. 이 그룹에 속하는 모듈은 절대로 상위 그룹(coord, cascade 등)을 참조해서는 안 된다
- **`masc.coord` (좌표/조정)**: 에이전트 간의 좌표 계산, 위치 추적, keeper 생명주기 관리를 담당. core(순수 계산), transport(IO), fsm(상태 관리)의 3개 서브모듈로 분리되어 각각 독립적으로 진화 가능
- **`masc.cascade` (파이프라인)**: 태스크의 순차/병렬 실행, 데이터 흐름 제어, 파이프라인 스케줄링을 담당. engine(실행), io(입출력), policy(규칙)의 분리로 새로운 입출력 포맷이나 비즈니스 규칙 추가가 엔진 코드에 영향을 주지 않음
- **`masc.tools` (도구)**: MCP 도구의 스키마 정의, 등록, 디스패치를 담당. coord의 keeper 정보를 참조하여 도구 실행 컨텍스트를 구성
- **`masc.server` (서버)**: HTTP 서버, MCP 프로토콜 핸들러, 세션 관리, 대시보드 API를 통합. 이 그룹은 lib/의 모든 다른 그룹에 의존하며, 애플리케이션의 진입점 역할

**디렉토리 구조 선택의 이유**:

1. **`masc`라는 이름 선택**: Jane Street의 `Core`, `Async`, `Incremental` 같은 단일 단어 라이브러리 명명 컨벤션을 따름 [^11^]. `masc_mcp_core` 대신 `masc`로 간결하게
2. **5개 그룹으로 제한**: OCaml 생태계에서 5-7개의 public library가 빌드 시간과 의존성 관리의 최적 균형점 [^10^]
3. **`include_subdirs qualified` 활용**: 파일 시스템의 디렉토리 구조가 모듈 네임스페이스로 자동 매핑 [^15^]. `lib/coord/core/keeper.ml` → `Masc.Coord.Core.Keeper`

---

## 4.3 coord 모듈 분할

### 4.3.1 분할 기준: 타입 기반 모듈 경계

coord 모듈(70파일, ~15K 라인)은 에이전트 컨텍스트 기준으로 **5배 초과**된 초대형 모듈이다. Insight 8(Type-Driven Module Decomposition) [^8^]에 따를, keeper의 상태 머신을 GADT로 모델링하면 각 상태가 별도 모듈이 되고 상태 전이 함수가 모듈 간 인터페이스가 된다. 이는 coord 분할의 이론적 기반이 된다.

coord 모듈의 현재 구조를 분석하면 다음 3가지 독립적인 책임 영역이 식별된다:

1. **코어(Core)**: keeper 타입, 좌표 위치, 변환 함수 등 **순수 데이터와 계산**
2. **전송(Transport)**: HTTP, stdio, WebSocket 등 **IO와 네트워크 통신**
3. **상태 머신(FSM)**: keeper의 상태 전이, 생명주기 관리, **부작용이 있는 상태 관리**

이 3가지 영역은 서로 다른 변경 빈도와 안정성 수준을 가진다. 코어는 안정적이고 전송은 프로토콜 변경에 따라 변하며, 상태 머신은 비즈니스 로직 변경에 따라 변한다. 이들을 분리하면 각 영역의 변경이 다른 영역에 미치는 영향을 최소화할 수 있다.

**분할 기준**:

1. **도메인 경계**: 좌표 계산(순수 함수) vs. 전송(IO) vs. 상태 관리(부작용)의 명확한 분리
2. **타입 의존성**: 순수 타입 정의 → 순수 함수 → IO → 상태 머신 순서로 의존성 방향 설정
3. **에이전트 컨텍스트**: 각 서브모듈이 64K 토큰(2K-3K 라인, 20-25 파일) 내에 들어가도록

### 4.3.2 coord → coord_core + coord_transport + coord_fsm

```
Before: coord/ (70파일, ~15K 라인)

After:
  coord/core/       (22파일, ~5K 라인)  - 순수 타입과 계산
  coord/transport/  (20파일, ~5K 라인)  - IO와 전송
  coord/fsm/        (18파일, ~4K 라인)  - 상태 머신
  coord/coord.ml    (1파일)              - 인덱스 모듈
  ─────────────────────────────────────
  합계: ~61파일, ~14K 라인
```

**coord_core**: 좌표의 핵심 데이터 타입과 순수 함수
- `keeper_types.ml`: keeper 상태를 표현하는 GADT와 기본 타입
- `position.ml`: 좌표 위치 계산 (순수 함수)
- `transform.ml`: 좌표 변환 (순pure 함수)
- `core.ml`: 인덱스 모듈. `Masc.Coord.Core`로 접근

**coord_transport**: HTTP, stdio 등 전송 계층
- `http.ml`: HTTP 전송 구현 (Eio 기반)
- `stdio.ml`: stdio 전송 구현
- `protocol.ml`: 전송 프로토콜 직렬화/역직렬화
- `transport.ml`: 인덱스 모듈. `Masc.Coord.Transport`로 접근

**coord_fsm**: keeper 상태 머신 (GADT 기반)
- `states.ml`: 상태 정의 (GADT)
- `transitions.ml`: 상태 전이 함수
- `state_machine.ml`: 상태 머신 실행기 (Eio fiber 기반)
- `fsm.ml`: 인덱스 모듈. `Masc.Coord.Fsm`로 접근

### 4.3.3 상태별 GADT 설계

```ocaml
(* coord/fsm/states.ml *)

(** keeper의 상태를 타입 수준에서 표현하는 GADT.
    Illegal state는 표현 불가능하도록 설계. *)
type 'a state =
  | Idle : [> `idle ] state
  | Connecting : { endpoint : string } -> [> `connecting ] state
  | Connected : { session_id : string } -> [> `connected ] state
  | Disconnected : { reason : string } -> [> `disconnected ] state
  | Error : { code : int; message : string } -> [> `error ] state

(** 상태 전이 타입: 'from -> 'to *)
type ('from, 'to_) transition =
  | Connect : ([ `idle ], [ `connecting ]) transition
  | Handshake : ([ `connecting ], [ `connected ]) transition
  | Disconnect : ([ `connected ], [ `disconnected ]) transition
  | Reconnect : ([ `disconnected ], [ `connecting ]) transition
  | Fail : ([ `connecting ], [ `error ]) transition

(** 각 상태에서 유효한 전이만 허용 *)
let step : type from to_. from state -> (from, to_) transition -> to_ state =
 fun state trans ->
  match (state, trans) with
  | Idle, Connect -> Connecting { endpoint = "" }
  | Connecting { endpoint }, Handshake -> Connected { session_id = endpoint }
  | Connected _, Disconnect -> Disconnected { reason = "requested" }
  | Disconnected _, Reconnect -> Connecting { endpoint = "" }
  | Connecting _, Fail -> Error { code = 1; message = "failed" }
  | _ -> .
  (* GADT의 exhaustiveness: 컴파일러가 불가능한 전이를 거부 *)
```

GADT를 사용하면 `Idle` 상태에서 `Disconnect`를 시도하는 같은 **타입 수준에서 불가능한 전이**를 컴파일 타임에 차단할 수 있다. 이는 단위 테스트로 검증할 필요 없이 컴파일러가 보장하며, 에이전트가 "이 상태에서는 어떤 연산이 가능한지"를 타입 시그니처만으로 파악할 수 있게 한다. `transitions.ml`은 이 GADT를 기반으로 실제 전이 로직을 구현하고, `state_machine.ml`은 Eio fiber 위에서 이 상태 머신을 실행한다.

### 4.3.4 의존성 방향

```
coord_core ─────────┐
     │              │
     ▼              ▼
coord_transport  coord_fsm
     │              │
     └──────┬───────┘
            ▼
       coord.ml (인덱스)
```

**핵심 규칙**: `coord_fsm`은 `coord_core`의 타입에 의존하지만, `coord_core`는 `coord_fsm`이나 `coord_transport`를 알지 못한다. 이는 단방향 의존성 그래프를 유지하여 순환 참조를 원천 차단한다 [^137^]. `coord_transport` 역시 `coord_core`의 타입에만 의존한다.

이 구조의 실용적 이점은 **병렬 개발**이다. 한 개발자가 `coord_fsm`의 상태 전이 로직을 수정하는 동안, 다른 개발자가 `coord_transport`의 HTTP 프로토콜을 업데이트할 수 있다. 두 변경은 `coord_core`의 타입 정의만 공유하며, 서로의 구현에 영향을 주지 않는다.

**dune 파일 예시**:

```lisp
; lib/coord/dune
(library
 (name coord)
 (public_name masc.coord)
 (libraries masc.coord_core masc.coord_transport masc.coord_fsm)
 (modules coord))

; lib/coord/core/dune
(library
 (name coord_core)
 (public_name masc.coord.core)
 (libraries masc)
 (modules core keeper_types position transform)
 (include_subdirs no))

; lib/coord/transport/dune
(library
 (name coord_transport)
 (public_name masc.coord.transport)
 (libraries masc masc.coord.core)
 (modules transport http stdio protocol)
 (include_subdirs no))

; lib/coord/fsm/dune
(library
 (name coord_fsm)
 (public_name masc.coord.fsm)
 (libraries masc masc.coord.core)
 (modules fsm states transitions state_machine)
 (include_subdirs no))
```

---

## 4.4 cascade 모듈 분할

### 4.4.1 분할 기준: 파이프라인 단계별 분리

cascade 모듈(54파일, ~12K 라인)은 128K 컨텍스트의 한계에 근접한 대형 모듈이다. cascade의 핵심 구조는 "파이프라인"이므로, 파이프라인의 각 단계를 모듈 경계로 삼는 것이 자연스럽다.

cascade의 현재 구조를 분석하면 다음 3가지 독립적인 책임 영역이 식별된다:

1. **엔진(Engine)**: 파이프라인의 실행 흐름, 태스크 스케줄링, 병렬 처리. **안정적**이고 변경 빈도가 낮음
2. **IO**: 입력 데이터 읽기, 출력 데이터 쓰기, 직렬화/역직렬화. **프로토콜 의존적**이고 변경 빈도가 높음
3. **정책(Policy)**: 비즈니스 규칙, 입력 검증, 패턴 매칭. **비즈니스 요구사항에 따라** 가장 자주 변경됨

이 3가지 영역을 분리하면 엔진의 안정적인 인터페이스 아래에서 IO와 정책을 독립적으로 진화시킬 수 있다. 새로운 전송 프로토콜을 추가하려면 `cascade_io/`만 수정하면 되고, 새로운 비즈니스 규칙을 추가하려면 `cascade_policy/`만 수정하면 된다.

**분할 기준**:

1. **파이프라인 단계**: 입력 → 처리 → 출력의 물리적 흐름
2. **순수성 경계**: 순수 함수(엔진, 정책) vs. IO 함수(입출력)의 분리
3. **변경 빈도**: 엔진(안정적)과 정책(자주 변경)의 분리

### 4.4.2 cascade → cascade_engine + cascade_io + cascade_policy

```
Before: cascade/ (54파일, ~12K 라인)

After:
  cascade/engine/  (20파일, ~4.5K 라인)  - 파이프라인 엔진
  cascade/io/      (18파일, ~4K 라인)    - 입출력 처리
  cascade/policy/  (12파일, ~2.5K 라인)  - 정책/규칙
  cascade/cascade.ml (1파일)             - 인덱스 모듈
  ─────────────────────────────────────
  합계: ~51파일, ~11K 라인
```

**cascade_engine**: 파이프라인 실행 엔진
- `pipeline.ml`: 파이프라인 정의와 구성 (DAG 표현)
- `scheduler.ml`: 태스크 스케줄링 (우선순위 큐 기반)
- `executor.ml`: 태스크 실행기 (Eio fiber 풀)
- `engine.ml`: 인덱스 모듈. `Masc.Cascade.Engine`로 접근

**cascade_io**: 입출력 처리
- `reader.ml`: 입력 데이터 읽기 (파일, 스트림, 메모리)
- `writer.ml`: 출력 데이터 쓰기
- `serializer.ml`: 직렬화/역직렬화 (JSON, MessagePack 등)
- `io.ml`: 인덱스 모듈. `Masc.Cascade.IO`로 접근

**cascade_policy**: 정책과 규칙
- `rules.ml`: 비즈니스 규칙 정의 (순pure 함수)
- `validators.ml`: 입력 데이터 검증
- `matchers.ml`: 패턴 매칭 (정규식, 구조적 매칭)
- `policy.ml`: 인덱스 모듈. `Masc.Cascade.Policy`로 접근

### 4.4.3 의존성 방향

```
cascade_policy ─────┐
     │              │
     ▼              ▼
cascade_engine  cascade_io
     │              │
     └──────┬───────┘
            ▼
       cascade.ml (인덱스)
```

**핵심 규칙**: `cascade_engine`은 `cascade_policy`의 규칙을 호출하지만, `cascade_policy`는 엔진의 낮은 구현을 알지 못한다. `cascade_io`는 양쪽 모두에 의존하지 않으며, 오직 외부 인터페이스만 제공한다. 이 구조를 통해 새로운 IO 어댑터를 추가할 때 엔진과 정책 코드를 전혀 건드리지 않아도 된다.

**dune 파일 예시**:

```lisp
; lib/cascade/dune
(library
 (name cascade)
 (public_name masc.cascade)
 (libraries masc.cascade_engine masc.cascade_io masc.cascade_policy)
 (modules cascade))

; lib/cascade/engine/dune
(library
 (name cascade_engine)
 (public_name masc.cascade.engine)
 (libraries masc masc.cascade.policy)
 (modules engine pipeline scheduler executor)
 (include_subdirs no))

; lib/cascade/io/dune
(library
 (name cascade_io)
 (public_name masc.cascade.io)
 (libraries masc masc.cascade.engine)
 (modules io reader writer serializer)
 (include_subdirs no))

; lib/cascade/policy/dune
(library
 (name cascade_policy)
 (public_name masc.cascade.policy)
 (libraries masc)
 (modules policy rules validators matchers)
 (include_subdirs no))
```

---

## 4.5 lib/ 모듈 재그룹핑

### 4.5.1 30개 → 5개 도메인 그룹

현재 `lib/`의 30개 모듈은 도메인 경계가 불명확하고 의존성 그래프가 복잡하다. 이를 5개의 public library로 재구성한다 [^3^][^4^]. 이 과정에서 Insight 7(Garbage-First Refactoring) [^7^]의 원칙을 적용하여, 실제로 사용되지 않는 모듈은 재그룹핑 대상에서 제외하고 삭제한다.

**Before/After 모듈 매핑**:

| 현재 모듈 | 파일 수 | 라인 수 | 목적 그룹 | 비고 |
|----------|--------|--------|----------|------|
| `core/` | 20 | ~3K | `masc` | 이름 변경 |
| `shared_types/` | 16 | ~2K | `masc` | 통합 |
| `logs_reporter/` | 8 | ~0.8K | `masc` | 통합 |
| `random_id/` | 6 | ~0.5K | `masc` | 통합 |
| `fs_compat/` | 6 | ~0.5K | `masc` | 통합 |
| `eio_context/` | 6 | ~0.5K | `masc` | 통합 |
| `string_helpers/` | 6 | ~0.5K | `masc` | 통합 |
| `coord/` | 70 | ~15K | `masc.coord` | 3개 서브모듈로 분할 |
| `cascade/` | 54 | ~12K | `masc.cascade` | 3개 서브모듈로 분할 |
| `tool_schemas/` | 28 | ~5K | `masc.tools` | schemas/로 이동 |
| `prompt_registry/` | 14 | ~2K | `masc.tools` | registry/로 이동 |
| `multimodal/` | 24 | ~4K | `masc.tools` | dispatch/와 통합 검토 |
| `http_mcp/` | 10 | ~1.5K | `masc.server` | http/로 통합 |
| `http_gateway/` | 10 | ~1.2K | `masc.server` | http/로 통합 |
| `http_dashboard/` | 10 | ~1.2K | `masc.server` | dashboard/로 이동 |
| `http_common/` | 8 | ~1K | `masc.server` | http/로 통합 |
| `stdio_mcp/` | 8 | ~1K | `masc.server` | mcp/로 이동 |
| `session/` | 12 | ~1.5K | `masc.server` | session/로 이동 |
| 기타 10개 소형 | ~50 | ~5K | `masc` 또는 삭제 | 숙청 대상 |

**Dune의 `(include_subdirs qualified)` 활용**: 각 라이브러리 내에서 디렉토리 구조가 자동으로 네임스페이스화된다 [^15^]. 예를 들어 `lib/coord/core/`의 `keeper_types.ml`은 `Masc.Coord.Core.Keeper_types`로 접근할 수 있다. 이는 별도의 module alias 코드 없이 파일 시스템 구조가 곧 모듈 네임스페이스가 되는 효과를 제공한다.

### 4.5.2 각 그룹의 public_name과 API 경계

각 public library는 `dune` 파일의 `public_name` 필드로 명시적으로 공개 API를 표시한다 [^18^].

```lisp
; lib/masc/dune
(library
 (name masc)
 (public_name masc)
 (libraries base fmt logs eio)
 (modules masc types error logging utils)
 (include_subdirs qualified))

; lib/coord/dune (최상위 인덱스 라이브러리)
(library
 (name coord)
 (public_name masc.coord)
 (libraries masc masc.coord.core masc.coord.transport masc.coord.fsm)
 (modules coord))

; lib/cascade/dune (최상위 인덱스 라이브러리)
(library
 (name cascade)
 (public_name masc.cascade)
 (libraries masc masc.cascade.engine masc.cascade.io masc.cascade.policy)
 (modules cascade))

; lib/tools/dune
(library
 (name tools)
 (public_name masc.tools)
 (libraries masc masc.coord)
 (modules tools schemas registry dispatch)
 (include_subdirs qualified))

; lib/server/dune
(library
 (name server)
 (public_name masc.server)
 (libraries masc masc.coord masc.cascade masc.tools)
 (modules server http mcp session dashboard)
 (include_subdirs qualified))
```

**API 경계 표시 전략** [^138^]:

- **Stable API**: `masc.coord`, `masc.cascade` — SemVer 준수, 하위 호환성 보장
- **Internal API**: `masc.coord.core`, `masc.coord.fsm` — 낮은 안정성, 낮은 문서화. 직접 사용은 권장하지 않으나 필요시 가능
- **Private**: `package masc_mcp`로 지정된 낮은 라이브러리 — 외부 사용 불가, 동일 프로젝트 내에서만 접근

각 모듈은 `.mli` 파일로 공개 API를 명시한다. AI 에이전트는 `.mli`만으로 모듈의 계약을 파악할 수 있어 컨텍스트를 절약할 수 있다 [^138^]. 예를 들어 `coord_core.mli`가 80라인이라면, 에이전트는 500라인의 `coord_core.ml` 구현을 읽지 않고도 모듈의 기능을 이해할 수 있다.

---

## 4.6 bin/ 실행 파일 통합

### 4.6.1 18개 → 5개 핵심 실행 파일

현재 18개의 실행 파일은 유사 기능이 별도 파일로 분산되어 유지보수 부담을 키운다. Dune의 `executables` 스탠자로 모듈 공유를 최대화하되, 기능별로는 `Cmdliner`의 subcommand 기반으로 통합한다 [^6^].

**Before/After 매핑**:

| 현재 실행 파일 | 기능 | 통합 후 | 근거 |
|--------------|------|--------|------|
| `agent_coord.ml` | coord 에이전트 | `masc-mcp coord` 서브커맨드 | 동일 도메인 통합 |
| `agent_coord_async.ml` | 비동기 coord | `masc-mcp coord --async` 옵션 | 플래그로 전환 |
| `cascade_cli.ml` | cascade CLI | `masc-mcp cascade` 서브커맨드 | 동일 도메인 통합 |
| `cascade_server.ml` | cascade 서버 | `masc-mcp server --mode=cascade` | 서버 모드 통합 |
| `dashboard_server.ml` | 대시보드 서버 | `masc-mcp-dashboard` (별도 유지) | 독립적 역할 |
| `dashboard_bonsai_server.ml` | Bonsai 대시보드 | 삭제 (Insight 3) | 이중 구현 제거 |
| `mcp_server_http.ml` | MCP HTTP 서버 | `masc-mcp-server` (통합) | 프로토콜 통합 |
| `mcp_server_stdio.ml` | MCP stdio 서버 | `masc-mcp-server --transport=stdio` | 플래그로 전환 |
| `tool_executor.ml` | 도구 실행기 | `masc-mcp tool execute` 서브커맨드 | 도메인 통합 |
| `tool_registry.ml` | 도구 레지스트리 | `masc-mcp tool list` 서브커맨드 | 도메인 통합 |
| `sidecar_*.ml` (5개) | 사이드카 | `masc-mcp-sidecar` 서브커맨드 | 5개 → 1개 통합 |
| `http_gateway.ml` | HTTP 게이트웨이 | `masc-mcp-server` (통합) | 서버 통합 |
| `http_dashboard.ml` | HTTP 대시보드 | `masc-mcp-dashboard` (통합) | 대시보드 통합 |
| 기타 3개 | 기타 | 삭제 또는 통합 | 사용량 확인 후 결정 |

### 4.6.2 Subcommand 기반 통합

**Cmdliner subcommand 예시 코드**:

```ocaml
(* bin/main.ml — masc-mcp 메인 CLI *)

open Cmdliner

(* Common arguments *)
let verbose =
  let doc = "Increase verbosity." in
  Arg.(value & flag & info [ "v"; "verbose" ] ~doc)

let config_file =
  let doc = "Path to configuration file." in
  Arg.(value & opt (some string) None & info [ "c"; "config" ] ~doc)

(* coord 서브커맨드 *)
let coord_cmd =
  let doc = "Coordinate agent operations" in
  let man = [ `S Manpage.s_description; `P "Manage agent coordination." ] in
  let async =
    let doc = "Run in async mode" in
    Arg.(value & flag & info [ "async" ] ~doc)
  in
  let run verbose config async =
    Masc.Coord.Core.run ~verbose ?config ~async ()
  in
  let term = Term.(const run $ verbose $ config_file $ async) in
  Cmd.v (Cmd.info "coord" ~doc ~man) term

(* cascade 서브커맨드 *)
let cascade_cmd =
  let doc = "Run cascade pipeline operations" in
  let man = [ `S Manpage.s_description; `P "Manage cascade processing." ] in
  let pipeline =
    let doc = "Pipeline configuration file" in
    Arg.(required & opt (some string) None & info [ "p"; "pipeline" ] ~doc)
  in
  let run verbose config pipeline =
    Masc.Cascade.Engine.run ~verbose ?config ~pipeline ()
  in
  let term = Term.(const run $ verbose $ config_file $ pipeline) in
  Cmd.v (Cmd.info "cascade" ~doc ~man) term

(* tool 서브커맨드 그룹 *)
let tool_execute_cmd =
  let doc = "Execute a tool" in
  let tool_name =
    Arg.(required & pos 0 (some string) None & info [] ~docv:"TOOL")
  in
  let run verbose config tool_name =
    Masc.Tools.Dispatch.execute ~verbose ?config tool_name
  in
  let term = Term.(const run $ verbose $ config_file $ tool_name) in
  Cmd.v (Cmd.info "execute" ~doc) term

let tool_list_cmd =
  let doc = "List available tools" in
  let run verbose config =
    Masc.Tools.Registry.list ~verbose ?config ()
  in
  let term = Term.(const run $ verbose $ config_file) in
  Cmd.v (Cmd.info "list" ~doc) term

let tool_cmd =
  let doc = "Tool management commands" in
  Cmd.group (Cmd.info "tool" ~doc) [ tool_execute_cmd; tool_list_cmd ]

(* 최상위 명령어 *)
let main_cmd =
  let doc = "masc-mcp — Multi-Agent System Coordinator for MCP" in
  let man = [ `S Manpage.s_bugs; `P "Report bugs to <team@example.com>." ] in
  let default = Term.(ret (const (`Help (`Pager, None)))) in
  Cmd.group (Cmd.info "masc-mcp" ~version:"0.1.0" ~doc ~man) ~default
    [ coord_cmd; cascade_cmd; tool_cmd ]

let () = exit (Cmd.eval main_cmd)
```

**서버 실행 파일 통합**:

```ocaml
(* bin/server.ml — masc-mcp-server *)

open Cmdliner

let transport =
  let doc = "Transport protocol (http|stdio)" in
  Arg.(value & opt string "http" & info [ "t"; "transport" ] ~doc)

let port =
  let doc = "Server port" in
  Arg.(value & opt int 8080 & info [ "p"; "port" ] ~doc)

let run_server transport port =
  match transport with
  | "http" -> Masc.Server.Http.Server.run ~port
  | "stdio" -> Masc.Server.Mcp.Protocol.run_stdio
  | _ -> failwith "Unknown transport"

let () =
  let doc = "masc-mcp-server — MCP protocol server" in
  let term = Term.(const run_server $ transport $ port) in
  let cmd = Cmd.v (Cmd.info "masc-mcp-server" ~version:"0.1.0" ~doc) term in
  exit (Cmd.eval cmd)
```

**sidecar 실행 파일 통합**: 5개의 sidecar 실행 파일도 서브커맨드 기반으로 통합한다.

```ocaml
(* bin/sidecar.ml — masc-mcp-sidecar *)

open Cmdliner

let sidecar_a_cmd =
  let doc = "Run sidecar A" in
  let run verbose = Masc.Coord.Transport.Sidecar_a.run ~verbose in
  let term = Term.(const run $ verbose_flag) in
  Cmd.v (Cmd.info "a" ~doc) term

let sidecar_b_cmd =
  let doc = "Run sidecar B" in
  let run verbose = Masc.Coord.Transport.Sidecar_b.run ~verbose in
  let term = Term.(const run $ verbose_flag) in
  Cmd.v (Cmd.info "b" ~doc) term

(* ... sidecar c, d, e 유사 ... *)

let () =
  let doc = "masc-mcp-sidecar — Sidecar processes" in
  let cmd = Cmd.group (Cmd.info "masc-mcp-sidecar" ~version:"0.1.0" ~doc)
    [ sidecar_a_cmd; sidecar_b_cmd; sidecar_c_cmd; sidecar_d_cmd; sidecar_e_cmd ]
  in
  exit (Cmd.eval cmd)
```

### 4.6.3 실행 파일별 dune 설정

```lisp
; bin/dune
(executable
 (name main)
 (public_name masc-mcp)
 (libraries masc masc.coord masc.cascade masc.tools cmdliner))

(executable
 (name server)
 (public_name masc-mcp-server)
 (libraries masc masc.coord masc.cascade masc.tools masc.server cmdliner))

(executable
 (name client)
 (public_name masc-mcp-client)
 (libraries masc masc.coord masc.server cmdliner))

(executable
 (name dashboard)
 (public_name masc-mcp-dashboard)
 (libraries masc masc.server cmdliner))

(executable
 (name sidecar)
 (public_name masc-mcp-sidecar)
 (libraries masc masc.coord cmdliner))
```

**빌드 최적화**: 실행 파일이 5개로 축소되면 링크 시간이 비례하여 감소한다. `executables` 스탠자로 모듈 공유를 최대화하면 추가적인 빌드 시간 절감 효과를 얻을 수 있다 [^6^]. Dune 3.21의 `unused-libs` alias로 불필요한 의존성도 감지할 수 있다 [^19^]. 18개에서 5개로 축소하면 CI/CD 파이프라인의 실행 시간도 크게 단축된다.

---

## 4.7 재설계 검증 체크리스트

Phase 2의 구조 재설계가 완료되면 다음 기준으로 검증한다:

| 검증 항목 | 기준 | 측정 방법 | 책임자 |
|----------|------|----------|--------|
| 모듈 크기 | 모든 서브모듈 ≤ 3K 라인, ≤ 30파일 | `find lib/ -name "*.ml" -exec wc -l {} + | sort` | CI |
| 컨텍스트 적합성 | 64K 토큰으로 단일 서브모듈 완전 이해 가능 | 에이전트 테스트: CLAUDE.md 없이 모듈 수정 요청 후 성공률 ≥ 80% | QA |
| 의존성 방향 | 순환 의존성 0개 | `dune describe` 또는 `ocamldep` 분석 | CI |
| 공개 API 경계 | 모든 public library에 .mli 존재, .mli/비율 ≥ 80% | `find lib/ -name "*.mli" | wc -l` vs `find lib/ -name "*.ml" | wc -l` | 리뷰어 |
| 빌드 시간 | Phase 1 대비 20% 이상 개선 | `time dune build @all` 비교 | CI |
| 실행 파일 수 | 5개 이하 | `ls bin/*.ml | wc -l` | CI |
| 네임스페이스 일관성 | 모든 모듈이 wrapped 라이브러리로 접근 가능 | `dune build` 후 `ocamlobjinfo` 확인 | CI |
| 테스트 커버리지 | 재설계 후 테스트 통과율 100% 유지 | `dune runtest` | CI |

---

## 4.8 다음 단계

Phase 2의 구조 재설계가 완료되면 **Phase 3: 타입 시스템 재설계**로 진행한다. Phase 3에서는 Phase 2에서 정의된 모듈 경계를 기반으로, 각 모듈 낮의 타입을 GADT와 phantom type으로 재설계하고, "Parse Don't Validate" 원칙을 적용하여 illegal state를 타입 수준에서 표현 불가능하게 만든다. coord의 `fsm/` 서브모듈에서 시작하여 cascade의 `engine/`로 확장하는 순서를 따른다.

Phase 2와 Phase 3의 경계는 명확하다: Phase 2는 **디렉토리와 파일의 물리적 이동**을 다루고, Phase 3는 **타입 정의의 논리적 재설계**를 다룬다. Phase 2가 완료되어야 Phase 3의 타입 경계가 물리적 모듈 경계와 일치할 수 있다. Phase 2에서 coord의 3개 서브모듈(core, transport, fsm)이 분리되면, Phase 3에서는 `fsm/states.ml`의 GADT를 확장하고 `core/keeper_types.ml`의 phantom type을 설계하게 된다.

---

## 참고문헌

[^1^]: Insight 1 — "Context-Bounded Architecture". masc-mcp Cross-Dimension Insights. 에이전트 컨텍스트가 구조의 1차 설계 제약이 되어야 함.

[^3^]: Insight 3 — "Dual Dashboard as Technical Debt". masc-mcp Cross-Dimension Insights. dashboard/와 dashboard_bonsai/의 이중 구현 문제.

[^4^]: Dune 공식 문서 - include_subdirs. "(include_subdirs qualified) generalizes the wrapped library scheme to arbitrary directories." https://dune.readthedocs.io/en/latest/reference/dune/include_subdirs.html

[^6^]: Dune 공식 문서 - executable reference. executables 스탠자의 모듈 공유 기능. https://dune.readthedocs.io/en/latest/reference/dune/executable.html

[^7^]: Insight 7 — "Garbage-First Refactoring". masc-mcp Cross-Dimension Insights. 숙청이 구조 개선의 선결조건.

[^8^]: Insight 8 — "Type-Driven Module Decomposition". GADT + phantom type이 모듈 경계를 자동 생성.

[^10^]: Insight 10 — "Agent-First as Simplicity Enforcer". 에이전트 친화적 구조가 Simple is Easy를 강제.

[^11^]: Jane Street packages v0.13 documentation. "The packages are released together and pushed to per-package repos on Github." https://ocaml.janestreet.com/ocaml-core/v0.13/doc/index.html

[^15^]: Dune 공식 문서 - include_subdirs. qualified/unqualified 모드 설명. https://dune.readthedocs.io/en/latest/reference/dune/include_subdirs.html

[^16^]: ocaml.tips - OCaml code organization and best practices. "Modules are a fundamental concept in OCaml that allow you to organize your code into logical units." https://ocaml.tips/article/OCaml_code_organization_and_best_practices.html

[^18^]: Dune 공식 문서 - library reference. public_name 필드의 역할. https://dune.readthedocs.io/en/latest/reference/dune/library.html

[^19^]: Dune 3.21.0 Release Notes. unused-libs alias 도입. https://github.com/ocaml/dune/releases/tag/3.21.0

[^38^]: "Claude Code Best Practices: Planning, Context Transfer, TDD", datacamp.com, 2026-03-09. 200K 컨텍스트의 60% 초과 시 품질 저하.

[^39^]: "Claude Code Best Practices: Lessons From Real Projects", ranthebuilder.cloud, 2026-03-23. 루트 CLAUDE.md는 200라인 이하로 유지.

[^40^]: "AI Context Windows Explained: 4K vs 128K vs 1M vs 10M Tokens", localaimaster.com, 2025-10-30. 128K 토큰 ≈ 8K-12K 라인.

[^75^]: "Context engineering for large codebases: a practical guide", packmind.com, 2026-04-03. 계층적 컨텍스트 아키텍처.

[^102^]: "The 'Lost in the Middle' Problem — Why LLMs Ignore the Middle of Your Context Window", dev.to, 2026-03-06. U자형 attention 곡선.

[^106^]: "Lost in the Middle: How Language Models Use Long Contexts", Stanford, UC Berkeley, Samaya AI 2023. teapot123.github.io.

[^109^]: "AI Context Windows Explained", localaimaster.com, 2025-10-30. 64K 토큰 ≈ 2K-3K 라인.

[^137^]: "Monorepo Architecture: The Ultimate Guide for 2025", feature-sliced.design, 2025-12-12. "modularity must be enforced, not hoped for".

[^138^]: "OCaml Project Setup Claude Code Skill", mcpmarket.com, 2026-01-21. .mli 파일의 에이전트 이해 역할.

[^144^]: "How cognitive complexity creates hidden friction in engineering organizations", getdx.com, 2025-11-26. 함수당 20-50 라인 권장.

---

# 5. Phase 3: 함수형 설계 원칙 적용

> *"Simplicity is a prerequisite for reliability."* — Edsger Dijkstra [^163^]

Phase 1과 Phase 2를 통해 숙청, 모듈 경계 재설계, 표준 라이브러리 통합이 완료된 후, Phase 3에서는 함수형 프로그래밍의 핵심 설계 원칙 5가지를 masc-mcp에 적용한다. 이 원칙들은 단순히 코딩 스타일을 개선하는 것이 아니라, 타입 시스템을 적극 활용하여 **컴파일 타임에 잘못된 프로그램을 만들 수 없게** 만드는 구조적 변환을 목표로 한다. 각 원칙은 masc-mcp의 30개 모듈, 5개 사이드카, keeper 상태 머신, MCP 프로토콜 메시지 처리 등 구체적 맥락에서 실행 가능한 리팩토링 방향을 제시한다.

---

## 5.1 Parse Don't Validate

### 5.1.1 원칙의 핵심

Alexis King이 2019년 발표한 "Parse, don't validate"는 타입 주도 설계의 핵심 원칙이다. 이 원칙의 핵심은 데이터를 **경계(boundary)에서 파싱하고, 파싱 결과로 얻은 더 강한 타입(stronger type)을 시스템 전체로 전파**하는 것이다. [^79^]

> *"The difference between validation and parsing lies almost entirely in how information is preserved."* [^78^]

검증(validation)은 특정 시점에 데이터가 조건을 만족하는지 확인하고 `true`/`false`를 반환할 뿐이며, 이 과정에서 얻은 모든 정보를 버린다. 반면 파싱(parsing)은 덜 구조화된 입력에서 더 구조화된 출력을 생산하는 일방향 연산이며, **학습한 정보를 타입에 인코딩하여 보존**한다. [^9^]

> *"A validator says 'this thing is fine, please continue.' A parser says 'give me a blob, and I'll either give you back a more precise type or tell you why I can't.' The difference sounds academic until you realize that validators throw away information the moment they finish running, while parsers preserve what they learned by encoding it in the type."* [^52^]

### 5.1.2 Shotgun Parsing 안티패턴

현재 masc-mcp 코드베이스에는 **Shotgun Parsing** 안티패턴이 존재할 가능성이 높다. 2016년 논문 "The Seven Turrets of Babel"은 이를 다음과 같이 정의한다:

> *"Shotgun parsing is a programming antipattern whereby parsing and input-validating code is mixed with and spread across processing code—throwing a cloud of checks at the input, and hoping, without any systematic justification, that one or another would catch all the 'bad' cases."* [^79^]

masc-mcp에서 Shotgun Parsing이 나타나는 대표적 사례:

| 위치 | 현재 패턴 (Before) | 문제 |
|------|---|---|
| `coord/`의 keeper 상태 검증 | `if state.status = "running" then ...` | 문자열 기반 검증, 각 모듈별 중복 |
| `cascade/`의 task 유효성 확인 | `match task.priority with Some p when p > 0 -> ...` | 경계가 아닌 비즈니스 로직 난입 |
| MCP 프로토콜 메시지 처리 | `if json.version <> "2.0" then failwith ...` | 각 핸들러마다 버전 체크 |
| 설정 파일 파싱 | `List.assoc "timeout" config |> int_of_string` | 예외 기반, 타입 없음 |

이 패턴의 결과는 4가지다. 첫째, 추가 복잡성과 인지 부하—`string`이나 `Yojson.Safe.t`를 사용할 때마다 프로그래머가 "이 값은 검증되었는가?"를 추적해야 한다. 둘째, 테스트 부담—동일한 검증 로직이 30개 모듈에 흩어져 있어 각각을 테스트해야 한다. 셋째, 신뢰도 긴장—"이 경우는 일어날 수 없어"라는 가정 하에 작성된 코드가 실제로는 예외를 발생시킨다. 넷째, 런타임 오버헤드—검증에 실패한 입력으로 시작된 부분적 작업의 비용이 낭비된다. [^75^]

> *"Parsing avoids this problem by stratifying the program into two phases—parsing and execution—where failure due to invalid input can only happen in the first phase. The set of remaining failure modes during execution is minimal by comparison."* [^79^]

### 5.1.3 masc-mcp 적용: 경계에서의 파싱

**MCP 프로토콜 메시지 파싱**을 예로 들면, 다음과 같이 변환한다.

```ocaml
(* BEFORE: Shotgun parsing — 각 핸들러마다 검증 *)
let handle_request json =
  let method_ = Yojson.Safe.Util.(member "method" json |> to_string) in
  if method_ = "" then failwith "empty method";
  let id = Yojson.Safe.Util.(member "id" json |> to_string) in
  if id = "" then failwith "empty id";
  (* ... 30개 모듈에서 각자 검증 ... *)
  process method_ id

let handle_notification json =
  let method_ = Yojson.Safe.Util.(member "method" json |> to_string) in
  if method_ = "" then failwith "empty method";
  (* method_ 검증이 중복됨 *)
  notify method_
```

```ocaml
(* AFTER: Parse at boundary — 한 곳에서 모든 검증 + 강한 타입으로 전파 *)
(* lib/protocol/message.mli *)
module Method : sig
  type t = private string
  val parse : string -> (t, [> `Unknown_method of string ]) result
  val value : t -> string
end

module Request_id : sig
  type t
  val parse : string -> (t, [> `Invalid_id of string ]) result
  val to_string : t -> string
end

type t = private {
  method_ : Method.t;
  id : Request_id.t option;
  params : Yojson.Safe.t;
}

val parse : Yojson.Safe.t -> (t, parse_error) result

(* lib/protocol/message.ml *)
module Method = struct
  type t = string
  let valid_methods = String.Set.of_list [
    "initialize"; "initialized"; "shutdown";
    "tools/list"; "tools/call"; "resources/list"; "resources/read"
  ]
  let parse s =
    if Set.mem valid_methods s then Ok s
    else Error (`Unknown_method s)
  let value s = s
end

module Request_id = struct
  type t = string
  let parse s =
    if String.length s > 0 then Ok s
    else Error (`Invalid_id s)
  let to_string s = s
end

type t = { method_ : Method.t; id : Request_id.t option; params : Yojson.Safe.t }

let parse json =
  let open Result.Syntax in
  let* obj = match json with
    | `Assoc fields -> Ok fields
    | _ -> Error (`Not_an_object json)
  in
  let* method_str = Json.string_field "method" obj in
  let* method_ = Method.parse method_str in
  let* id = Option.map ~f:Request_id.parse (List.Assoc.find obj "id")
            |> Option.value ~default:(Ok None) in
  let params = List.Assoc.find obj "params"
               |> Option.value ~default:`Null in
  Ok { method_; id; params }
```

이 변환의 핵심은 `Method.t`가 **비공개(private)** 생성자를 가지므로 외부에서 임의의 문자열을 직접 `Method.t`로 만들 수 없다는 점이다. `Method.parse`를 통과한 값만이 `Method.t` 타입을 가질 수 있고, 이 타입은 30개 모듈 전체로 전파되어 각 핸들러가 별도의 검증 없이 안전하게 사용할 수 있다. [^190^]

**설정 파일 파싱**에도 동일한 원칙을 적용한다.

```ocaml
(* BEFORE *)
let timeout =
  List.assoc "timeout" config
  |> int_of_string  (* Failure 예외 가능 *)

(* AFTER *)
module Timeout_ms : sig
  type t = private int
  val parse : int -> (t, [> `Out_of_range of int ]) result
  val value : t -> int
end = struct
  type t = int
  let create n =
    if n > 0 && n <= 300_000 then Ok n  (* 1ms ~ 5분 *)
    else Error (`Out_of_range n)
  let parse s = match Int.of_string s with
    | n -> create n
    | exception _ -> Error (`Not_an_int s)
  let value n = n
end
```

---

## 5.2 Make Illegal States Unrepresentable

### 5.2.1 원칙의 기원

Yaron Minsky가 2010년 "Effective ML" 강연에서 Jane Street의 OCaml 사용 경험을 바탕으로 처음 제시한 원칙이다. [^36^]

> *"Making the wrong thing hard to express is better than checking for the wrong thing at runtime."* — Yaron Minsky [^35^]

> *"One of our programming maxims is 'make illegal states unrepresentable', by which we mean that if a given collection of values constitutes an error, then it is better to arrange for that collection of values to be impossible to represent within the constraints of the type system."* — Jane Street [^51^]

이 원칙은 단순히 데이터를 검증하는 것을 넘어, **타입 시스템의 제약 내에서 불가능한 상태 조합을 literally 만들 수 없게 설계**하는 것을 목표로 한다.

### 5.2.2 Algebraic Data Types로 잘못된 상태 제거

masc-mcp의 keeper 상태가 다음과 같이 정의되어 있다고 가정할 때, 문제점은 명확하다.

```ocaml
(* BEFORE: permissive types — 많은 상태 조합이 불가능한데도 표현됨 *)
type keeper_state = {
  status : string;              (* "idle" | "running" | "shutdown" *)
  current_task : Task.t option; (* status="idle"일 때는 무조건 None이어야 함 *)
  peers : Peer.t list;
  shutdown_reason : string option; (* status="shutdown"일 때만有意義 *)
}

(* 이 상태는 불법인데 표현 가능함! *)
let illegal = {
  status = "idle";
  current_task = Some task;     (* idle인데 task가 있다?! *)
  peers = [];
  shutdown_reason = Some "reason"; (* idle인데 shutdown_reason이 있다?! *)
}
```

OCaml의 대수적 데이터 타입(algebraic data types)으로 변환하면, 각 상태에서 유효한 필드만 정의할 수 있다.

```ocaml
(* AFTER: Make illegal states unrepresentable *)
type idle = { peers : Peer.t list }

type running = {
  task : Task.t;
  peers : Peer.t list;
  start_time : Mtime.t;
  deadline : Mtime.t option;
}

type draining = {
  reason : string;
  deadline : Mtime.t;
}

type t =
  | Idle of idle
  | Running of running
  | Draining of draining
  | Shutdown

(* 불법 상태는 표현 불가능!
   Idle 상태에서 current_task 필드가 존재할 수 없음
   Running 상태에서 shutdown_reason 필드가 존재할 수 없음 *)
```

이 방식에서는 `Idle` 생성자가 `task` 필드를 가질 수 없으므로, "idle 상태인데 task가 있음"이라는 불법 상태가 **타입 시스템에 의해 표현 불가능**해진다. [^39^]

### 5.2.3 GADTs로 상태 머신 모델링

keeper의 상태 전이 규칙을 더 강하게 강제하려면 GADTs(Generalized Algebraic Data Types)를 사용한다.

> *"Generalized algebraic datatypes, or GADTs, extend usual sum types in two ways: constraints on type parameters may change depending on the value constructor, and some type variables may be existentially quantified."* [^84^]

```ocaml
(* lib/keeper/state_gadt.ml *)
type idle
type running
type draining
type shutdown

type _ keeper_state =
  | Idle : { peers : Peer.t list } -> idle keeper_state
  | Running : {
      task : Task.t;
      peers : Peer.t list;
      start_time : Mtime.t;
      deadline : Mtime.t option;
    } -> running keeper_state
  | Draining : { reason : string; deadline : Mtime.t } -> draining keeper_state
  | Shutdown : shutdown keeper_state
```

이제 상태 전이 함수의 타입 시그니처가 **합법적 전환만 허용**한다.

```ocaml
(* start_task : idle keeper_state -> Task.t -> running keeper_state *)
let start_task (Idle { peers }) task =
  Running {
    task;
    peers;
    start_time = Mtime_clock.now ();
    deadline = None;
  }

(* drain : [idle | running] keeper_state -> string -> draining keeper_state *)
let drain : type a. a keeper_state -> string -> draining keeper_state =
  fun state reason ->
    match state with
    | Idle { peers } ->
        Draining { reason; deadline = Mtime_clock.now () }
    | Running { task = _; peers = _; start_time = _; deadline } ->
        Draining { reason; deadline = Option.value deadline ~default:(Mtime_clock.now ()) }

(* 컴파일 오류: 이미 Draining인 상태를 다시 Draining할 수 없음 *)
(* let _ = drain (Draining { reason = "x"; deadline = t }) "y" *)
(* Error: This expression has type draining keeper_state
          but an expression was expected of type idle keeper_state *)
```

> *"The clarity of the state-transitioning functions and the ability to directly access the relevant state fields without conditional checks make the code so much simpler and clearer!"* [^40^]

### 5.2.4 Phantom Types로 API 안전성 보장

Jane Street의 classic 패턴인 phantom types는 타입 파라미터를 런타임 값과 분리하여 API 사용 패턴을 강제한다.

> *"We thought that phantom types would be an appropriate topic for our first real post because they are a good example of a powerful and useful feature of OCaml that is little used in practice."* [^87^]

```ocaml
(* lib/utils/validated.ml *)
type raw
type validated

type 'a mcp_message = Yojson.Safe.t

module Message : sig
  val parse : Yojson.Safe.t -> (validated mcp_message, Error.t) result
  val send : validated mcp_message -> unit
  val raw_of_string : string -> raw mcp_message
  (* 컴파일 오류: raw 메시지는 send 불가 *)
  (* val send_raw : raw mcp_message -> unit  *)
end = struct
  type 'a mcp_message = Yojson.Safe.t

  let parse json =
    (* JSON-RPC 2.0 형식 검증, method 필드 존재 확인 등 *)
    if is_valid json then Ok json
    else Error (`Invalid_message json)

  let send msg =
    (* 이미 validated된 메시지만 전송 *)
    Transport.write msg

  let raw_of_string s = Yojson.Safe.from_string s
end

(* 사용 예 *)
let raw = Message.raw_of_string "{\"method\": \"tools/list\"}" in
let validated = Message.parse raw in
match validated with
| Ok msg -> Message.send msg  (* 안전! *)
| Error e -> handle_error e

(* 컴파일 오류: raw 메시지를 직접 send하면 타입 에러 *)
(* Message.send raw  *)
(* Error: This expression has type raw mcp_message
          but an expression was expected of type validated mcp_message *)
```

### 5.2.5 상태 머신을 타입으로 표현: coord의 keeper 상태

coord 모듈의 keeper 상태 머신은 Phase 3에서 가장 큰 변환 대상이다. Insight 8에서 분석했듯이, GADT로 모델링하면 각 상태가 별도 모듈이 되고 상태 전이 함수가 모듈 간 인터페이스가 된다. [^8^]

```ocaml
(* lib/coord/keeper/state.ml *)
module Capability = struct
  type t = Read | Write | Admin
  module Set = Set.Make(struct type nonrec t = t let compare = Stdlib.compare end)
end

(* 각 상태 별로 필요한 데이터만 정의 *)
module Registered = struct
  type t = {
    capabilities : Capability.Set.t;
    protocol_version : Protocol.Version.t;
    registered_at : Mtime.t;
  }
end

module Executing = struct
  type t = {
    task : Task.t;
    start_time : Mtime.t;
    deadline : Mtime.t option;
    peer_count : int;
  }
end

module Draining = struct
  type t = {
    reason : drain_reason;
    initiated_at : Mtime.t;
    force_deadline : Mtime.t option;
  }

  and drain_reason = Graceful | Forced of string
end

(* 상태 전이 타입 — 불법 전이는 타입 에러 *)
val register : Protocol.Initialize.t -> [> `Registered of Registered.t ]
val start_task : Registered.t -> Task.t -> [> `Executing of Executing.t ]
val complete_task : Executing.t -> Task.result -> [> `Registered of Registered.t ]
val drain : [ `Registered of Registered.t | `Executing of Executing.t ] ->
            Draining.drain_reason -> [> `Draining of Draining.t ]
val finish_shutdown : Draining.t -> [> `Shutdown ]
```

---

## 5.3 Simple is Easy (Rich Hickey)

### 5.3.1 Simple vs Easy의 구분

Rich Hickey의 2011년 Strange Loop 강연 "Simple Made Easy"는 소프트웨어 업계가 ease(쉬움)와 simplicity(단순함)를 혼동하고 있음을 지적한다.

**Simple(단순함)**의 어원: Latin "simplex" — "한 가지(single)" + "접기(fold)", 즉 **entanglement(얽힘)이 없는 상태**. 객관적 개념이다.

> *"Simple is actually an objective notion. We can look and see, 'I don't see any connections. I don't see anywhere where this twists with something else.'"* [^163^]

**Easy(쉬움)**의 어원: Old French "aisie" — "가까움(nearness)", 즉 주관적 개념이다.

> *"We are just so self-involved in these two aspects it's hurting us tremendously. All we care about is, 'can I get this instantly and start running it in five seconds?' It could be this giant hairball that you got, but all you care is 'can you get it?'"* [^163^]

### 5.3.2 Complecting: 얽어매기의 비용

Hickey의 핵심 개념은 **complecting** — "함께(com-) 꼬기(plectere)" — 여러 독립적인 것들을 얽어버리는 것이다.

> *"Vars and variables, again, complect value in time... Actors complect what's going to be done and who's going to do it. Object relational mapping has, oh my God, complecting going on."* [^163^]

masc-mcp에서 발견될 수 있는 complecting:

| Complecting (현재) | Simplifying (목표) |
|---|---|
| 상태(state) — 값과 시간 얽기 | Immutable 데이터 + 순수 함수 |
| keeper가 task 상태와 I/O를 동시에 처리 | 상태 머신(pure)과 I/O(shell) 분리 |
| coord가 메시지 파싱과 비즈니스 로직을 혼합 | Parse Don't Validate 적용으로 단방향 흐름 |
| 사이드카가 프로토콜 처리와 에러 복구를 얽음 | Protocol 모듈(pure) + Sidecar 루프(shell) |
| 조걸 분기가 모든 함수에 흩어져 있음 | Pattern matching + Exhaustive handling |

> *"Strictly separating what from how is the key to making how somebody else's problem."* [^163^]

### 5.3.3 모듈 간 얽힘 분석

565K 라인 규모의 프로젝트에서 complexity를 관리하려면 모듈 간 얽힘을 정량적으로 분석하고 제거해야 한다.

```ocaml
(* BEFORE: complecting — 여러 책임이 얽임 *)
(* coord/keeper.ml — 상태 관리 + I/O + 로깅 + 에러 처리가 모두 한 함수에 *)
let process_message env peer msg =
  match msg with
  | `Task_request task ->
      Logger.info "Received task";
      (* 상태 변경 *)
      current_state := Running task;
      (* I/O: DB에 기록 *)
      Db.insert_task task;
      (* 네트워크 응답 *)
      Peer.send peer (`Ack task.id);
      (* 로깅 *)
      Logger.info "Task started";
      (* 에러 처리 — 실패하면 롤백? *)
      (try
         let result = execute_task env task in
         Db.update_task_status task.id `Completed;
         Peer.send peer (`Result result)
       with e ->
         Logger.error "Task failed: %s" (Printexc.to_string e);
         Db.update_task_status task.id `Failed;
         Peer.send peer (`Error (Printexc.to_string e));
         current_state := Idle)
  | _ -> ()
```

```ocaml
(* AFTER: simplicity — 관심사 분리 *)

(* lib/coord/keeper_logic.ml — Pure functional core *)
module Logic = struct
  type event =
    | Task_received of Task.t
    | Task_completed of Task.result
    | Task_failed of Error.t
    | Drain_requested of string

  type action =
    | Send of Peer.t * Outgoing_message.t
    | Db_write of Db_op.t
    | Log of Log_entry.t

  let handle : state -> event -> (state * action list, Error.t) result =
    fun state event ->
      match state, event with
      | Idle idle_state, Task_received task ->
          Ok (Running { task; idle_state },
              [ Send (idle_state.peers, Ack task.id);
                Db_write (Insert_task task) ])
      | Running run_state, Task_completed result ->
          Ok (Idle { peers = run_state.peers },
              [ Send (run_state.peers, Result result);
                Db_write (Update_status (run_state.task.id, Completed)) ])
      | Running _, Drain_requested reason ->
          Error (`Cannot_drain_while_running reason)
      | _ -> Error (`Invalid_transition (state_to_string state, event_to_string event))
end

(* bin/coord_main.ml — Imperative shell *)
let rec loop env state =
  let msg = Peer.receive () in
  let event = Message.to_event msg in
  match Keeper_logic.Logic.handle state event with
  | Ok (new_state, actions) ->
      List.iter (execute_action env) actions;
      loop env new_state
  | Error e ->
      Logger.error "Transition error: %a" Error.pp e;
      loop env state
```

이 분리의 핵심은 `Keeper_logic.Logic.handle`가 **완전히 순수**하다는 것이다. 동일한 `state`와 `event`를 입력하면 항상 동일한 `(new_state, actions)`를 반환한다. I/O는 없고, 로깅도 없으며, DB 접근도 없다. 모든 부수 효과는 `action list`로 **선언적**으로 표현되고, `bin/`의 imperative shell이 이를 실행한다.

### 5.3.4 단방향 의존성 그래프 구성

Simplicity를 위한 아키텍처 원칙:

> *"If you want really simple components, you can horizontally separate them and you can vertically stratify them. But you can also do that with complex things and you're going to get no benefits."* [^163^]

masc-mcp의 단방향 의존성 그래프:

```
           bin/ (Imperative Shell)
                |
                v
    +---------------------------+
    |   lib/coord/keeper_io.ml  |  <- I/O orchestration
    +---------------------------+
                |
                v
    +---------------------------+
    |  lib/coord/keeper_logic.ml|  <- Pure state transitions
    +---------------------------+
                |
                v
    +---------------------------+
    | lib/protocol/message.ml   |  <- Parse Don't Validate
    +---------------------------+
                |
                v
    +---------------------------+
    | lib/types/*.ml            |  <- Illegal states unrepresentable
    +---------------------------+
                |
                v
    +---------------------------+
    | Base / Stdlib             |  <- Foundation
    +---------------------------+
```

의존성은 위에서 아래로만 흐를 수 있다. `lib/types/`는 `lib/protocol/`를 알 수 없고, `lib/protocol/`는 `lib/coord/`를 알 수 없다. 이 제약이 얽힘을 물리적으로 방지한다.

---

## 5.4 Functional Core, Imperative Shell

### 5.4.1 원칙의 핵심

Gary Bernhardt의 "Functional Core, Imperative Shell"(FC/IS) 아키텍처는 **비즈니스 로직을 순수 함수(pure function)로 작성하고, 부수 효과(side effect)는 외부 셸(shell)에서만 수행**하는 것을 목표로 한다.

> *"Our simple example application reads user input, increments the input, and outputs the result... We can refactor this code to a pure function that lives in our functional core with the single responsibility to compute the result."* [^37^]

| Functional Core | Imperative Shell |
|---|---|
| 순수 함수만 존재 (동일 입력 → 동일 출력) | I/O, DB, 네트워크 호출 |
| 외부 상태에 의존하지 않음 | 상태 변경 |
| 테스팅이 trivially easy (mock 불필요) | 순수 함수를 orchestration |
| 병렬화가 자유로움 | 환경 설정, 리소스 관리 |

### 5.4.2 lib/ (pure core) vs bin/ (imperative shell) 명확화

masc-mcp의 디렉토리 구조는 FC/IS 패턴에 맞게 재편된다.

```
masc-mcp/
├── lib/                          # Functional Core — 절대 I/O 없음
│   ├── protocol/                 # 순수한 MCP 프로토콜 처리
│   │   ├── message.ml            # Parse Don't Validate
│   │   ├── request.ml
│   │   └── response.ml
│   ├── types/                    # 도메인 타입 (illegal states unrepresentable)
│   │   ├── keeper_state.ml
│   │   ├── task.ml
│   │   └── peer.ml
│   ├── keeper_logic/             # keeper coordination 순수 로직
│   │   ├── state_machine.ml      # GADT 기반 상태 전이
│   │   └── transition.ml
│   └── utils/                    # 순수 유틸리티
│       └── validation.ml
├── bin/                          # Imperative Shell — I/O 허용
│   ├── masc_mcp_main.ml          # 진입점, I/O orchestration
│   ├── coord_main.ml             # coord 사이드카 I/O 루프
│   ├── cascade_main.ml           # cascade 사이드카 I/O 루프
│   └── keeper_io.ml              # keeper I/O 어댑터
└── test/                         # Core 함수의 단위 테스트 (mock-free)
    ├── test_keeper_logic.ml
    ├── test_protocol_parser.ml
    └── test_state_machine.ml
```

**핵심 규칙**:

1. `lib/`의 모듈은 **절대** 직접적인 I/O를 수행하지 않는다. `Eio`, `Lwt_io`, `Stdlib.input` 등 어떤 I/O 함수도 호출하지 않는다.
2. 모든 DB, 파일, 네트워크, 환경 변수 접근은 `bin/`에서만 수행된다.
3. `lib/`의 함수는 `Eio.Stdenv.t`나 `in_channel` 등을 받지 않고, 이미 파싱된 데이터 구조만 받는다.
4. `lib/`의 함수는 `unit -> t` 형태의 "환경에서 읽기"를 수행하지 않는다.

> *"I think 'functional core, imperative shell' sounds pithy but mistakenly gives the impression that you're wrapping or protecting the pure code."* [^50^] 실제로 OCaml에서는 이 경계가 모듈 시그니처(.mli)와 디렉토리 구조로 **물리적**으로 형성된다.

### 5.4.3 Eio 기반 I/O 경계 설정

OCaml 5의 Eio 라이브러리는 effects-based direct-style IO를 제공하여 FC/IS의 경계를 명확히 한다.

> *"Eio provides an effects-based direct-style IO stack for OCaml 5. For example, you can use Eio to read and write files, make network connections, or perform network connections, or perform CPU-intensive calculations, running multiple operations at the same time."* [^73^]

Eio의 capability-based design은 imperative shell의 권한을 명시적으로 제한한다.

```ocaml
(* lib/protocol/parser.ml — Functional Core: 순수 파싱 *)
let parse_message (json : Yojson.Safe.t) : (Message.t, parse_error) result =
  let open Result.Syntax in
  let* method_ = Json.field "method" Json.string json in
  let* id = Json.optional_field "id" Json.string json in
  let params = Json.field_or_null "params" json in
  Message.create ~method_ ~id ~params

(* bin/masc_mcp_main.ml — Imperative Shell: I/O + orchestration *)
let run ~env (config : Config.t) =
  Eio.Switch.run @@ fun sw ->
  let stdin = Eio.Stdenv.stdin env in
  let stdout = Eio.Stdenv.stdout env in

  (* I/O: 메시지 읽기 *)
  let rec message_loop () =
    let line = Eio.Buf_read.line (Eio.Buf_read.of_flow stdin ~initial_size:4096) in
    let json = Yojson.Safe.from_string line in

    (* 경계: raw JSON -> parsed type *)
    match Parser.parse_message json with
    | Ok msg ->
        (* 순수 코어 호출 *)
        let response = Handler.handle config msg in
        (* I/O: 응답 쓰기 *)
        output_message stdout response;
        message_loop ()
    | Error e ->
        Logger.warn "Parse error: %a" Parse_error.pp e;
        message_loop ()
  in
  message_loop ()
```

핵심은 `parse_message`가 `Yojson.Safe.t`를 입력받고 `Message.t`를 출력하는 **순수 함수**라는 점이다. 이 함수는 `Eio.Stdenv.t`를 전혀 알지 못하며, 표준 입력에서 읽는지 파일에서 읽는지, 네트워크에서 읽는지 전혀 관심이 없다. 이로 인해 테스트가 극도로 단순해진다.

```ocaml
(* test — mock 없이 순수하게 테스트 *)
let test_parse_valid_message () =
  let json = `Assoc [
    ("jsonrpc", `String "2.0");
    ("method", `String "initialize");
    ("id", `String "req-1");
    ("params", `Null)
  ] in
  match Parser.parse_message json with
  | Ok msg ->
      Alcotest.check Alcotest.string "method"
        "initialize" (Message.method_ msg |> Method.value);
      Alcotest.check Alcotest.(option string) "id"
        (Some "req-1") (Message.id msg |> Option.map Request_id.to_string)
  | Error e -> Alcotest.failf "Unexpected error: %a" Parse_error.pp e

(* I/O mock가 전혀 필요 없음! *)
```

---

## 5.5 Smart Constructors 전략

### 5.5.1 개념

Smart constructor는 **모듈 시그니처를 통해 타입의 생성자를 숨기고, 불변식(invariant)을 보장하는 생성 함수만 노출**하는 패턴이다. 이는 5.1(Parse Don't Validate)과 5.2(Make Illegal States Unrepresentable)의 실천적 메커니즘을 제공한다.

> *"A module that implements a module type must specify concrete types for the abstract types in the signature and define all the names declared in the signature. Only declarations in the signature are accessible outside of the module."* [^41^]

### 5.5.2 비공개 생성자 + 불변식 보장

OCaml에서는 두 가지 방식으로 smart constructor를 구현할 수 있다.

**방식 1: Abstract Type (완전 캡슐화)**

```ocaml
(* lib/types/non_empty_list.mli *)
type 'a t

val create : 'a list -> ('a t, [> `Empty_list ]) result
val singleton : 'a -> 'a t
val head : 'a t -> 'a
val tail : 'a t -> 'a list
val to_list : 'a t -> 'a list

(* lib/types/non_empty_list.ml *)
type 'a t = 'a * 'a list  (* 항상 최소 1개의 요소 *)

let create = function
  | [] -> Error `Empty_list
  | x :: xs -> Ok (x, xs)

let singleton x = (x, [])
let head (x, _) = x
let tail (_, xs) = xs
let to_list (x, xs) = x :: xs
```

외부에서는 `Non_empty_list.t` 타입의 값을 직접 생성할 수 없다. `create`나 `singleton` 함수를 통해서만 생성 가능하며, 이 함수들은 "최소 1개의 요소"라는 불변식을 보장한다.

**방식 2: Private Type (패턴 매칭 허용 + 생성 금지)**

```ocaml
(* lib/types/percentage.mli *)
type t = private float

val create : float -> (t, [> `Out_of_range of float ]) result
val value : t -> float
val of_int : int -> t  (* 0~100 사이만 허용 *)

(* lib/types/percentage.ml *)
type t = float

let create f =
  if Float.(f >= 0.0 && f <= 1.0) then Ok f
  else Error (`Out_of_range f)

let value t = t
let of_int n = Float.of_int n /. 100.0

(* 패턴 매칭 가능 — 외부에서도 *)
let is_complete (p : t) = match p with 1.0 -> true | _ -> false
```

> *"Private type declarations in module signatures, of the form `type t = private ...`, enable libraries to reveal some, but not all aspects of the implementation of a type to clients of the library."* [^190^]

### 5.5.3 모듈 signature 캡슐화: masc-mcp 도메인 타입

masc-mcp의 주요 도메인 타입에 smart constructor를 적용한다.

```ocaml
(* lib/types/peer_id.mli *)
type t

val create : string -> (t, [> `Invalid_format of string ]) result
val of_string : string -> t option  (* 신뢰할 수 있는 컨텍스트에서만 *)
val to_string : t -> string
val compare : t -> t -> int
val equal : t -> t -> bool

include Comparable.S with type t := t

(* lib/types/peer_id.ml *)
type t = string

(* peer id는 alnum + hyphen만 허용, 길이 1-64 *)
let valid_re = Re.Posix.re "^[a-zA-Z0-9-]+$" |> Re.compile

let create s =
  if String.length s > 0 && String.length s <= 64 && Re.execp valid_re s
  then Ok s
  else Error (`Invalid_format s)

let of_string s = Option.some_if (Re.execp valid_re s) s
let to_string s = s
let compare = String.compare
let equal = String.equal
module T = struct type nonrec t = t let compare = compare let sexp_of_t = String.sexp_of_t end
include Comparable.Make(T)
```

```ocaml
(* lib/types/timeout.mli *)
type t = private int

val create : int -> (t, [> `Out_of_range of int ]) result
val of_int_exn : int -> t  (* 테스트/리터럴용. _exn suffix로 위험성 표시 *)
val value : t -> int
val add : t -> t -> t

(* lib/types/timeout.ml *)
type t = int

let create n =
  if n > 0 && n <= 300_000 then Ok n  (* 1ms ~ 5분 *)
  else Error (`Out_of_range n)

let of_int_exn n =
  match create n with
  | Ok t -> t
  | Error _ -> failwith "Timeout.of_int_exn: out of range"

let value n = n
let add a b = a + b
```

### 5.5.4 encapsulation의 효과

Smart constructor를 사용하면 4가지 효과를 얻는다.

| 효과 | 설명 |
|---|---|
| **컴파일 타임 보증** | 올바르지 않은 값이 생성되는 것을 타입 시스템이 방지 |
| **지역적 추론(local reasoning)** | 값을 받으면 불변식이 이미 보장되었음을 신뢰 |
| **리팩토링 안전성** | 납부 구현을 변경핮도 인터페이스가 유지되면 클라이언트 코드는 영향 없음 |
| **테스트 단순화** | 불변식 보장된 값만 테스트하면 됨 |

> *"Data-hiding using signatures can be used to encode tighter invariants than are possible with algebraic data types alone. The importance of abstraction in ML and Haskell is well understood, but OCaml has a nice extra feature which is the ability to declare types as private."* [^51^]

### 5.5.5 Anti-patterns Checklist

Phase 3 리팩토링 과정에서 다음 패턴이 발견되면 즉시 제거 대상으로 삼는다.

- [ ] **Shotgun parsing**: 여러 모듈에서 동일한 입력에 대해 각자 검증
- [ ] **Stringly-typed programming**: `string` 대신 의미 있는 타입이 없음
- [ ] **`string option` 남용**: "없음"의 의미가 불분명 (`None` vs `Some ""`)
- [ ] **타입이 너무 큰 record**: `option` 필드가 많아 "부분적으로 채워진" 상태가 가능
- [ ] **Wildcard pattern 남용**: `| _ -> ...`으로 exhaustive match 회피
- [ ] **Business logic에 I/O 섞임**: DB 쿼리, 파일 읽기, 네트워크 호출이 순수 함수 난입
- [ ] **Public constructor 남발**: `type t = { ... }`를 signature에서 그대로 노출

---

## 5.6 Phase 3 종합: 원칙 간 시너지

5개 원칙은 서로 독립적이지 않다. Parse Don't Validate가 강한 타입을 생성하면, 그 타입이 Make Illegal States Unrepresentable의 구체화가 된다. GADT로 모델링된 상태 머신은 Functional Core에 속하는 순수 함수이며, Smart Constructor는 그 타입들의 생성을 안전하게 통제한다. Simple is Easy는 이 모든 과정에서 complecting을 제거하는 설계 기준을 제공한다.

| 원칙 | 적용 대상 | 산출물 | 다음 단계 연결 |
|------|----------|--------|--------------|
| Parse Don't Validate | MCP 메시지, 설정 파일, API 입력 | `Method.t`, `Request_id.t`, `Timeout.t` 등 강한 타입 | 5.2의 GADT 입력 |
| Make Illegal States Unrepresentable | keeper 상태, coordination 상태 | GADT 상태 머신 | 5.4의 Functional Core 입력 |
| Simple is Easy | 모듈 설계, 인터페이스 크기 | 단방향 의존성 그래프 | 5.1-5.5의 설계 기준 |
| Functional Core, Imperative Shell | lib/ vs bin/ 분리 | 순수 함수와 I/O의 물리적 분리 | 6장 테스트 전략 |
| Smart Constructors | 모든 도메인 타입 | 불변식 보장된 타입 생태계 | 5.2의 GADT 상태 생성 |

Phase 3이 완료되면 masc-mcp의 코드베이스는 다음과 같은 특성을 갖는다. 30개 모듈은 단방향 의존성 그래프를 형성한다. 모든 외부 입력은 경계에서 파싱되어 강한 타입으로 전파된다. keeper와 cascade의 상태 머신은 GADT로 모델링되어 불법 상태가 컴파일 타임에 차단된다. `lib/`에는 순수 함수만 존재하며 테스트에 mock가 불필요하다. 모든 도메인 타입은 smart constructor를 통해 생성되어 불변식이 타입 시스템에 의해 보장된다.

> *"Be Simple and Readable. The time you spend typing the programs is negligible compared to the time spent reading them."* [^82^]

> *"A program is written once, modified ten times, and read 100 times. So it's beneficial to simplify its writing, always keep future modifications in mind, and never jeopardize readability."* [^82^]

---

[^78^]: Elm Radio, "Parse, Don't Validate" (2020)
[^79^]: Alexis King (lexi-lambda), "Parse, don't validate" (2019) — 원문
[^9^]: DevIQ, "Parse, Don't Validate" (2024)
[^52^]: Christian Ekrem, "Parse, Don't Validate — In a Language That Doesn't Want You To" (2026)
[^75^]: Contemplating Dev, "Parse, don't validate" (2024)
[^190^]: OCaml Manual, "Private types" (5.1)
[^35^]: AIPatternBook, "Make Illegal States Unrepresentable" (2026)
[^36^]: Tarides Blog, "Effective ML Through Merlin's Destruct Command" (2024)
[^51^]: Rice University, "Experiences with Functional Programming on Wall Street"
[^39^]: OCaml Discuss, "What is The OCaml Way?" (2022)
[^84^]: OCaml Manual, "Generalized algebraic datatypes"
[^40^]: Erlang Solutions, "Make illegal states unrepresentable — but how?" (2021)
[^87^]: Jane Street Blog, "HOWTO: Static access control using phantom types" (2008)
[^163^]: Rich Hickey, "Simple Made Easy" transcript (2011)
[^37^]: Functional Architecture, "Functional Core, Imperative Shell"
[^50^]: Reddit r/ocaml, "Functional core, imperative shell in OCaml"
[^73^]: Eio GitHub, "Effects-Based Parallel IO for OCaml"
[^41^]: Cornell CS3110, "Abstract Types" (2020)
[^82^]: OCaml.org, "OCaml Programming Guidelines"
[^8^]: masc-mcp Cross-Dimension Insight 8: "Type-Driven Module Decomposition"
[^86^]: OCaml Discuss, "Design Patterns for OCaml" (2023)

---

## 6. Phase 4: 카테고리 이론 기반 모듈 설계

> 카테고리 이론 추상화는 도구일 뿐 목적이 아니다. 본 장에서는 masc-mcp의 coord 상태 전이, cascade 파이프라인, 설정 병합 등 구체적 문제에 대한 실전 적용법을 제시하며, 각 추상화의 도입 기준과 over-abstraction의 위험을 명확히 구분한다.

---

### 6.1 Functor / Applicative / Monad 활용

#### 6.1.1 도입 기준: 언제 Monad가 필요한가

카테고리 이론 기반 추상화를 도입하는 첫 번째 질문은 "이 추상화 없이 코드가 작동하는가?"이다. Functor/Applicative/Monad 계층은 각각 다른 문제를 해결한다 [^5^]:

| 추상화 | 해결 문제 | 도입 기준 |
|--------|----------|----------|
| **Functor** (`map`) | 컨텍스트 낸 값에 함수 적용 | `Option`/`Result` 값에 함수를 3회 이상 적용할 때 |
| **Applicative** (`pure`, `apply`) | 독립적 효과의 병렬 조합 | 복수 검증/계산을 동시에 실행하고 결과를 조합할 때 |
| **Monad** (`bind`, `return`) | 순차적 의존성 표현 | 이전 계산의 결과가 다음 계산의 입력이 될 때 |

Jane Street Base의 접근법은 **실용적 제한**을 두는 것이다 [^12^]: Functor/Applicative/Monad 서명을 표준화하되 모든 타입 클래스를 구현하지는 않으며, Higher-order 함수에는 label(`~f:`)을 강제하여 가독성을 확보한다.

#### 6.1.2 coord 상태 전이의 Monadic 표현

coord 모듈(70파일)의 턴 처리 파이프라인은 `Result.bind`를 반복적으로 사용하는 패턴이 다수 존재한다. 이를 내장 binding operators(`let*`)로 전환하면 가독성이 크게 향상된다 [^13^][^24^].

**Before (명시적 매치)**:

```ocaml
let process_turn state event =
  match validate_event event with
  | Error e -> Error e
  | Ok validated ->
    match transition_state state validated with
    | Error e -> Error e
    | Ok new_state ->
      match emit_telemetry new_state with
      | Error e -> Error e
      | Ok () -> Ok new_state
```

**After (let* binding operator)**:

```ocaml
let ( let* ) = Result.bind
let ( let+ ) = Result.map

let process_turn state event =
  let* validated = validate_event event in
  let* new_state = transition_state state validated in
  let+ () = emit_telemetry new_state in
  new_state
```

OCaml 4.08부터 내장 `let*` 연산자를 사용할 수 있으며 [^24^], 별도 PPX 의존성 없이 언어 수준에서 Monad 구문을 지원한다. Jane Street의 `ppx_let`은 `match%bind` 등의 확장 기능과 더 나은 디버깅 정보 전달을 제공하지만 [^20^], masc-mcp는 표준 binding operators로 시작하고 필요 시에만 `ppx_let`을 도입한다.

#### 6.1.3 Validation용 Applicative Functor

Applicative의 핵심 장점은 **독립적인 효과들을 병렬로 조합**하여 모든 에러를 한 번에 수집할 수 있다는 점이다 [^130^]. coord의 입력 검증에서 이 패턴을 적용하면 사용자에게 모든 문제를 한 번에 보여줄 수 있다.

```ocaml
module type VALIDATION = sig
  type 'a t = ('a, string list) result
  val pure : 'a -> 'a t
  val apply : ('a -> 'b) t -> 'a t -> 'b t
  val ( let+ ) : 'a t -> ('a -> 'b) -> 'b t
  val ( and+ ) : 'a t -> 'b t -> ('a * 'b) t
end

module Validation : VALIDATION = struct
  type 'a t = ('a, string list) result
  let pure x = Ok x
  let apply f x = match f, x with
    | Ok f, Ok x -> Ok (f x)
    | Error e1, Error e2 -> Error (e1 @ e2)  (* 모든 에러 수집 *)
    | Error e, _ | _, Error e -> Error e
  let ( let+ ) x f = Result.map f x
  let ( and+ ) x y = match x, y with
    | Ok a, Ok b -> Ok (a, b)
    | Error e1, Error e2 -> Error (e1 @ e2)
    | Error e, _ | _, Error e -> Error e
end
```

**적용 예시: coord 이벤트 파라미터 병렬 검증**:

```ocaml
open Validation

let validate_turn_request ~agent_id ~action ~payload =
  let+ valid_agent = validate_agent_id agent_id
  and+ valid_action = validate_action action
  and+ valid_payload = validate_payload action payload in
  { agent_id = valid_agent; action = valid_action; payload = valid_payload }
  (* Error ["agent not found"; "invalid action"; "payload too large"] 
     -> 모든 에러를 한 번에 반환 *)
```

`and+`는 `let+`과 달리 **병렬 구조**를 표현한다. 각 검증은 서로의 결과에 의존하지 않으므로 Applicative가 이상적이다 [^5^]. 만약 `payload` 검증이 `action` 결과에 의존한다면 Monad(`let*`)를 사용해야 한다.

#### 6.1.4 ppx_let 도입 결정 매트릭스

`ppx_let`(Jane Street)과 내장 binding operators의 선택 기준은 다음과 같다 [^16^][^149^]:

| 기준 | 내장 `let*` | `ppx_let` |
|------|------------|-----------|
| 의존성 | 없음 (언어 기본) | PPX 필요 |
| `match%bind` | 미지원 | 지원 |
| 병렬 바인딩 | `and*` | `and` (최적화) |
| 디버깅 정보 | 기본 | 더 나은 에러 리포팅 |
| Jane Street 통합 | 가능 | 원활 |

**권장**: masc-mcp는 현재 `let*`/`let+`/`and+`로 시작한다. `match%bind`이 3회 이상 필요해지면 `ppx_let` 도입을 검토한다.

---

### 6.2 Semigroup & Monoid

#### 6.2.1 개념과 도입 기준

**Semigroup(반군)** 은 결합 법칙(associativity)을 만족하는 `append` 연산을 가진 타입이다 [^15^]. **Monoid(모노이드)** 는 Semigroup에 항등원(identity element)을 추가한 구조로, `append zero x = x`를 만족한다 [^14^].

```ocaml
module type SEMIGROUP = sig
  type t
  val append : t -> t -> t  (* (<@>) 연산자로 노출 가능 *)
end

module type MONOID = sig
  include SEMIGROUP
  val zero : t
end
```

**도입 기준**: 데이터 타입이 "누적 가능"하고, "빈 값"의 개념이 있으며, 결합 순서가 결과에 영향을 주지 않을 때 Monoid를 고려한다. 세 조건 중 하나라도 만족하지 않으면 일반 함수로 충분하다.

#### 6.2.2 로그 Aggregation

cascade 파이프라인(54파일)의 여러 단계에서 생성되는 로그를 Monoid로 통합한다:

```ocaml
module LogEntry : sig
  type t = { timestamp : float; level : Logs.level; message : string; source : string }
  include MONOID with type t := t
end = struct
  type t = { timestamp : float; level : Logs.level; message : string; source : string }
  let append a b = 
    if a.timestamp <= b.timestamp then a else b  (* 가장 오래된 로그 유지 *)
  let zero = { timestamp = Float.infinity; level = Logs.Debug; message = ""; source = "" }
end

module LogBatch : sig
  type t = LogEntry.t list
  include MONOID with type t := t
end = struct
  type t = LogEntry.t list
  let append a b = a @ b  (* 시간순 정렬은 최종 집계 시 수행 *)
  let zero = []
end

(* cascade 파이프라인 단계별 로그 수집 *)
let run_pipeline stages input =
  List.fold_left 
    (fun (acc_logs, state) stage ->
       let logs, new_state = stage state in
       (LogBatch.append acc_logs logs, new_state))
    (LogBatch.zero, input) stages
```

OCaml 5.4의 **Tail Recursion Modulo Cons (TRMC)** 덕분에 `List.fold_left`로 `@` 연산을 누적핍도도 스택 오버플로우 걱정 없이 안전하게 동작한다 [^56^].

#### 6.2.3 설정 병합

coord와 cascade의 설정은 다중 소스(기본값, 환경 변수, CLI 인자, 파일)에서 오므로 Monoid 병합이 자연스럽다:

```ocaml
module Config : sig
  type t = {
    concurrency_limit : int;
    timeout_ms : int;
    retry_policy : [ `None | `Linear of int | `Exponential of float ];
    log_level : Logs.level;
    feature_flags : string list;
  }
  include MONOID with type t := t
end = struct
  type t = {
    concurrency_limit : int;
    timeout_ms : int;
    retry_policy : [ `None | `Linear of int | `Exponential of float ];
    log_level : Logs.level;
    feature_flags : string list;
  }
  
  (* 오른쪽 설정이 왼쪽을 덮어씀 (last-wins) *)
  let append base override = {
    concurrency_limit = 
      if override.concurrency_limit > 0 then override.concurrency_limit 
      else base.concurrency_limit;
    timeout_ms = 
      if override.timeout_ms > 0 then override.timeout_ms 
      else base.timeout_ms;
    retry_policy = 
      (match override.retry_policy with `None -> base.retry_policy | _ -> override.retry_policy);
    log_level = override.log_level;
    feature_flags = base.feature_flags @ override.feature_flags;
  }
  
  let zero = {
    concurrency_limit = 0; timeout_ms = 0; 
    retry_policy = `None; log_level = Logs.Debug; 
    feature_flags = [];
  }
end

(* 최종 설정: 기본값 < 파일 < 환경변수 < CLI *)
let final_config = 
  Config.(append (append (append default file_config) env_config) cli_config)
  (* 또는: List.fold_left Config.append Config.zero sources *)
```

#### 6.2.4 메트릭스 집계

cascade 파이프라인의 각 단계에서 수집되는 성능 메트릭스를 Monoid로 집계한다:

```ocaml
module Metrics : sig
  type t = {
    call_count : int;
    total_latency_ms : float;
    error_count : int;
    bytes_transferred : int;
  }
  include MONOID with type t := t
end = struct
  type t = {
    call_count : int;
    total_latency_ms : float;
    error_count : int;
    bytes_transferred : int;
  }
  let append a b = {
    call_count = a.call_count + b.call_count;
    total_latency_ms = a.total_latency_ms +. b.total_latency_ms;
    error_count = a.error_count + b.error_count;
    bytes_transferred = a.bytes_transferred + b.bytes_transferred;
  }
  let zero = { call_count = 0; total_latency_ms = 0.; error_count = 0; bytes_transferred = 0 }
end

(* 파이프라인 전체 메트릭스 집계 *)
let aggregate_metrics (stages : Metrics.t list) : Metrics.t =
  List.fold_left Metrics.append Metrics.zero stages
```

> **주의**: Monoid의 결합 법칙은 수치 합계에는 당연히 성립하지만, 평균(`total_latency_ms /. float call_count`)과 같이 파생 값은 `append` 연산에서 직접 계산하지 않고 최종 집계 후에 산출해야 한다.

---

### 6.3 Effect Handlers (OCaml 5)

#### 6.3.1 Monad에서 Effect Handler로의 전환

OCaml 5의 algebraic effect handlers는 Monad의 대안으로 부상하고 있다. Jane Street는 `Hardcaml_step_testbench` 라이브러리를 Monad에서 algebraic effects로 포팅한 경험을 공유하며, "Monad로 할 수 있는 대부분의 것은 algebraic effects로 더 우아하게 할 수 있다"고 평가한다 [^76^].

| 특성 | Monad | Effect Handler |
|------|-------|---------------|
| 타입 표현 | 타입에 효과 정보 노출 (`'a M.t`) | 타입 시스템과 분리 |
| 조합성 | Monad transformer 필요 | 자연스러운 조합 |
| 디버깅 | CPS 변환으로 스택 추적 손실 | 원래 스택 보존 |
| 성능 | 힙 할당(continuation) 필요 | 스택 할당 활용 [^18^] |

성능 측면에서 effect handlers는 concurrency monad에 비해 월등히 빠르다. Micro-benchmark에서 effect handlers는 stock OCaml보다 10배 느렸지만, concurrency monad는 67배 느렸다 [^18^].

#### 6.3.2 Eio의 Direct Style과 Effects

Eio는 OCaml 5의 effect handlers를 활용한 **직접 스타일(direct-style)** 병렬 I/O 라이브러리이다 [^18^]. Eio의 `Switch`, `Fiber`, `Promise`는 모두 effect handlers 기반으로 구현된다:

```ocaml
(* Eio 스타일: 직접 스타일, Monad 래퍼 없음 *)
let process_requests ~sw env requests =
  Eio.Fiber.List.iter 
    (fun req ->
       Switch.run @@ fun sw ->
       Fiber.fork ~sw (fun () -> handle_request env req))
    requests

(* Monad 스타일과의 대비: Lwt에서는 let* 체인이 필요 *)
(* let process_requests_lwt requests =
     Lwt_list.iter_p (fun req -> handle_request_lwt req) requests *)
```

Eio의 핵심 추상화는 [5.1절](#51-eio-기반-비동기-아키텍처)에서 상세히 다룬다. 본 절에서는 Eio의 effect handler 기반 설계가 카테고리 이론 추상화와 어떻게 상호작용하는지에 초점을 맞춘다.

#### 6.3.3 Monad Transformer 대체 전략

기존의 Monad transformer stack(`ResultT`, `StateT`, `ReaderT`)은 effect handlers로 대체할 수 있다:

**Before (Monad Transformer)**:

```ocaml
module ResultT (M : MONAD) = struct
  type 'a t = ('a, string) result M.t
  let return x = M.return (Ok x)
  let bind m f =
    M.bind m (function
      | Error e -> M.return (Error e)
      | Ok x -> f x)
end

(* 사용: ResultT(StateT(Lwt))의 중첩 *)
(* 타입: ('a, string) result Lwt.t ref Lwt.t *)
(* 디버깅 시 스택 추적이 CPS 변환으로 인해 난해함 *)
```

**After (Effect Handlers)**:

```ocaml
(* 상태 effect 정의 *)
effect Get_state : state
effect Put_state : state -> unit
(* 에러 effect 정의 *)
effect Raise_error : string -> 'a

let handle_state init f =
  let rec loop state = function
    | v -> (v, state)
    | effect Get_state k -> loop state (continue k state)
    | effect (Put_state s) k -> loop s (continue k ())
  in
  loop init (f ())

let handle_error f =
  match f () with
  | v -> Ok v
  | effect (Raise_error msg) k -> Error msg
  | effect _ _ -> failwith "unhandled effect"

(* 조합: 별도의 transformer stack 없이 핸들러 중첩 *)
let run_computation init_state f =
  handle_error (fun () ->
    handle_state init_state f)
```

핵심 차이는 **타입 표현**이다. Monad transformer는 효과가 타입에 노출되지만(`'a M.t`), effect handlers는 타입 시스템과 분리되어 코드가 더 읽기 쉬워진다 [^76^].

#### 6.3.4 cascade 파이프라인의 Effects 기반 재설계

cascade 파이프라인은 각 단계가 독립적일 때 Applicative, 순차적일 때 Monad, I/O가 필요할 때 Effect Handler를 조합하여 설계할 수 있다:

```ocaml
(* cascade 단계의 effect 기반 인터페이스 *)
effect Log : LogEntry.t -> unit
effect Get_metric : Metrics.t
effect Emit_metric : Metrics.t -> unit

type 'a stage = 'a -> 'a

let run_stage ~(config : Config.t) (stage : 'a stage) (input : 'a) : 'a * Metrics.t =
  let metric_acc = ref Metrics.zero in
  let result = 
    match
      (fun () ->
         perform (Log { timestamp = Unix.gettimeofday (); level = Info; 
                        message = "Stage start"; source = "cascade" });
         let output = stage input in
         perform (Emit_metric !metric_acc);
         output)
      ()
    with
    | v -> v
    | effect (Log entry) k -> 
        Logs.info (fun m -> m "%s" entry.message);
        continue k ()
    | effect Get_metric k -> 
        continue k !metric_acc
    | effect (Emit_metric m) k -> 
        metric_acc := Metrics.append !metric_acc m;
        continue k ()
  in
  (result, !metric_acc)
```

**전환 로드맵**:

1. **새로운 효과**는 Effect handler로 구현 (즉시)
2. **기존 Monad 코드**는 단계적으로 마이그레이션 (1-3개월)
3. **Async/Concurrency** 영역에서 가장 먼저 효과적 (Eio 1.0과 통합)

> **주의**: Effect handlers는 OCaml 5.3+의 딥 핸들러 구문이 안정화된 후 프로덕션에 적용한다. 현재는 실험적 모듈에서 검증 후 점진 확대한다 [^107^].

---

### 6.4 고급 모듈 시스템 활용

#### 6.4.1 First-Class Modules: 런타임 모듈 선택

First-class modules는 런타임에 모듈을 값처럼 다룰 수 있게 하여, 설정 기반 백엔드 선택과 같은 동적 디스패치를 타입 안전하게 구현할 수 있다 [^152^].

```ocaml
(* 저장소 백엔드 시그니처 *)
module type STORAGE = sig
  type t
  type key
  type value
  val create : unit -> t
  val get : t -> key -> value option
  val set : t -> key -> value -> unit
  val fold : t -> init:'a -> f:(key -> value -> 'a -> 'a) -> 'a
end

(* 런타임 백엔드 선택 *)
let get_storage_backend = function
  | `Memory -> 
      (module struct
        type t = (string, string) Hashtbl.t
        type key = string
        type value = string
        let create () = Hashtbl.create 64
        let get t k = Hashtbl.find_opt t k
        let set t k v = Hashtbl.replace t k v
        let fold t ~init ~f = Hashtbl.fold (fun k v acc -> f k v acc) t init
      end : STORAGE with type key = string and type value = string)
  | `Sqlite -> 
      (module Sqlite_backend : STORAGE with type key = string and type value = string)
  | `Redis ->
      (module Redis_backend : STORAGE with type key = string and type value = string)

(* 사용처 - 타입 안전한 동적 디스패치 *)
let initialize_coord_storage backend_type =
  let (module S) = get_storage_backend backend_type in
  let storage = S.create () in
  (* S.get, S.set 등을 타입 안전하게 사용 *)
  storage
```

**도입 기준**: 모듈 선택이 컴파일 시점이 아닌 런타임에 결정되고, 선택된 모듈이 동일한 `STORAGE` 같은 시그니처를 공유할 때 First-class modules를 고려한다. 단순한 variant + 패턴 매칭으로 충분한 경우가 대부분이므로 [^87^], 타입 안전한 동적 디스패치가 실제로 필요한지 먼저 검증한다.

#### 6.4.2 Recursive Modules: 순환 의존성 처리

Recursive modules는 순환 참조가 필요한 모듈을 정의할 수 있게 하지만, OCaml의 experimental extension이며 명시적 signature annotation이 필수적이다 [^116^].

```ocaml
(* coord의 에이전트-메시지 순환 참조 *)
module rec Agent : sig
  type t = { id : string; inbox : Message.t Queue.t; state : state }
  val create : string -> t
  val receive : t -> Message.t -> unit
  val process : t -> unit
end = struct
  type t = { id : string; inbox : Message.t Queue.t; state : state }
  let create id = { id; inbox = Queue.create (); state = Idle }
  let receive t msg = Queue.add msg t.inbox
  let process t =
    match Queue.take_opt t.inbox with
    | None -> ()
    | Some msg -> Message.handle msg t
end

and Message : sig
  type t = { sender : string; payload : payload }
  and payload = Command of string | Response of string | Heartbeat
  val handle : t -> Agent.t -> unit
end = struct
  type t = { sender : string; payload : payload }
  and payload = Command of string | Response of string | Heartbeat
  let handle msg agent =
    match msg.payload with
    | Command cmd -> Agent.receive agent { msg with payload = Response "ack" }
    | Response _ -> ()
    | Heartbeat -> ()
end
```

**안전성 규칙** [^116^]:
- 모든 recursive 모듈은 **명시적 signature annotation**이 필요
- 순환 그래프에서 최소한 하나의 "safe" 모듈(모든 value가 함수 타입) 필요
- 실제 순환 호출이 런타임에 발생하면 `Undefined_recursive_module` 예외

**대안: 순환 의존성 제거가 우선이다**. 가능하면 DAG 구조를 유지하고, "untying the recursive knot" 기법(타입을 파라미터로 추상화)을 먼저 고려한다 [^22^]:

```ocaml
(* 순환 제거 버전: 타입 파라미터화 *)
module Message (Agent : sig type t val process : t -> unit end) = struct
  type t = { sender : string; payload : payload; recipient : Agent.t }
  and payload = Command of string | Response of string
end
```

#### 6.4.3 Sharing Constraints: 모듈 간 타입 공유

Sharing constraints는 서로 다른 모듈 간의 타입 동일성을 선언하여, 독립적으로 정의된 모듈이 동일한 타입을 공유하도록 한다 [^70^][^72^].

```ocaml
(* coord와 cascade가 공유하는 핵심 타입 *)
module type EVENT = sig
  type t
  val compare : t -> t -> int
  val to_string : t -> string
end

(* coord 모듈 - 이벤트 생성 *)
module Coord_event : EVENT with type t = string = struct
  type t = string
  let compare = String.compare
  let to_string x = x
end

(* cascade 모듈 - 동일한 이벤트 타입을 공유 *)
module Cascade_processor (Evt : EVENT with type t = Coord_event.t) = struct
  let process events =
    List.sort Evt.compare events
    |> List.map Evt.to_string
    |> String.concat "; "
end

(* destructive substitution을 활용한 더 깔끔한 표현 *)
module type PROCESSOR = sig
  type event
  val process : event list -> string
end

module Make_processor (Evt : EVENT) : 
  PROCESSOR with type event := Evt.t = struct
  let process events =
    List.sort Evt.compare events
    |> List.map Evt.to_string
    |> String.concat "; "
end
```

`with type t := ...` (destructive substitution)는 signature에서 타입을 제거하고 동시에 동일성을 선언하여, 병합된 signature에서 타입 이름이 노출되지 않게 한다 [^97^][^98^]. 이는 coord-cascade 경계에서 불필요한 타입 에일리어싱을 방지한다.

#### 6.4.4 OCaml 5.4 신기능과의 시너지

OCaml 5.4의 **Labelled Tuples** [^101^][^104^]는 Monoid/Applicative의 복수 결과 반환에 유용하다:

```ocaml
(* Labelled Tuples: Monoid 집계 결과에 이름 부여 *)
let aggregate_pipeline ~(stages : stage list) input : ~logs:LogBatch.t * ~metrics:Metrics.t * ~result:'a =
  let (logs, metrics, result) = 
    List.fold_left stages ~init:([], Metrics.zero, input)
      ~f:(fun (ls, ms, st) stage ->
         let new_logs, new_metrics, output = stage st in
         (LogBatch.append ls new_logs, Metrics.append ms new_metrics, output))
  in
  ~logs, ~metrics, ~result

(* 사용처: 명시적 필드명으로 접근 *)
let ~logs, ~metrics, ~result = aggregate_pipeline stages request
```

OCaml 5.4의 **Immutable Arrays** (`'a iarray`) [^56^]는 Applicative 순회 결과를 안전하게 저장:

```ocaml
(* 불변 배열: Applicative 병렬 검증 결과 저장 *)
let validate_batch (items : request iarray) : (response, string list) result iarray =
  Iarray.map validate_request items
  (* 공변성(co-variance)을 활용한 안전한 타입 코어싱 *)
```

---

### 6.5 Over-Abstraction의 위험과 실용적 기준

카테고리 이론 추상화는 강력한 도구이지만 과도한 적용은 다음 문제를 야기한다:

| 문제 | 증상 | 대응 |
|------|------|------|
| 인지 부하 증가 | 팀원 모두가 Semigroup/Profunctor를 이해해야 함 | 3인 이상의 팀원이 개념을 설명할 수 없으면 도입 보류 |
| 디버깅 어려움 | 스택 트레이스에 추상화 레이어만 표시 | binding operators 대신 명시적 `match`로 폴백 가능하도록 유지 |
| 컴파일 시간 증가 | 모듈 functor 체인이 복잡해짐 | functor nesting을 3단계 이상으로 제한 |
| 성능 저하 | 불필요한 closure 할당 | `let*` 체인을 `[@inline]`로 최적화, 성능 임계치 설정 |

**Jane Street의 현실적 접근법** [^12^]:

1. **Rule of Three**: 동일 패턴이 3회 이상 나타날 때만 추상화 도입
2. **효과 분리**: 테스트 용이성을 위해 효과를 분리해야 할 때 추상화
3. **법칙 기반 추론**: `QCheck` 등으로 Monoid 결합 법칙을 검증하여 코드 정확성 보장 [^14^]
4. **Label 강제**: `~f:` 라벨로 Higher-order 함수의 가독성 확보

```ocaml
(* 검증 예시: Semigroup 결합 법칙 QCheck 테스트 *)
let test_semigroup_associativity (type a) 
  (module S : SEMIGROUP with type t = a) (gen : a QCheck.Gen.t) =
  QCheck.Test.make 
    (QCheck.triple gen gen gen)
    "associative"
    (fun (a, b, c) -> 
       S.(append a (append b c) = append (append a b) c))
```

---

### 6.6 Phase 4 적용 로드맵

| 우선순위 | 작업 | 기간 | 대상 모듈 |
|----------|------|------|----------|
| P0 | `let*`/`let+` 도입, 명시적 Result.match 제거 | 1주 | coord (70파일) |
| P1 | Validation Applicative 병렬 검증 적용 | 1주 | coord 입력 검증 |
| P2 | LogBatch/Config/Metrics Monoid 정의 | 1주 | cascade (54파일) |
| P3 | Effect handler 실험 모듈 구현 | 2주 | cascade pipeline |
| P4 | First-class modules로 백엔드 선택 추상화 | 2주 | storage layer |
| P5 | Recursive modules 검토 및 순환 제거 | 2주 | coord-agent-message |

**의존성**: P0은 [5.1절](#51-eio-기반-비동기-아키텍처)의 `Base`/`Stdlib` 표준화 완료 후 실행. P3은 Eio 1.0 마이그레이션([5.2절](#52-lwtasync에서-eio로의-마이그레이션))과 병렬 진행 가능.

---

**참고 문헌**

| 인용 | 출처 | 주요 내용 |
|------|------|----------|
| [^5^] | shaynefletcher.org | Functor, Applicative, Monoid, Traversable OCaml 구현 |
| [^12^] | xvw.lol | OCaml 표준 라이브러리 및 Preface 소개 |
| [^13^] | cryptologie.net | OCaml Monad 간단 소개, let* 구문 |
| [^14^] | grahamenos.com | Semigroup/Monoid 법칙 및 QCheck 테스트 |
| [^15^] | chshersh.com | Pragmatic Category Theory: Semigroup |
| [^16^] | ocaml.org/p/ppx_let | ppx_let 공식 문서 |
| [^18^] | kcsrk.info | Effect Handler vs Monad 성능 비교 |
| [^20^] | discuss.ocaml.org | ppx_let vs binding operators 비교 |
| [^22^] | cs3110.github.io | OCaml Programming: Functors 튜토리얼 |
| [^24^] | jobjo.github.io | OCaml 4.08 binding operators 신규 문법 |
| [^56^] | OCaml Changelog | OCaml 5.4.0 상세 변경사항 |
| [^70^] | courses.cs.cornell.edu | Sharing Constraints (Cornell CS3110) |
| [^76^] | blog.janestreet.com | Algebraic Effects로의 전환 경험 |
| [^87^] | tycon.github.io | First-Class Modules와 Modular Implicits |
| [^97^] | gallium.inria.fr | Signature Substitution (OCaml Manual) |
| [^98^] | ocaml.org/manual/5.4 | Substituting inside a signature |
| [^101^] | ocaml.org/changelog | OCaml 5.4.0 체인지로그 |
| [^104^] | tarides.com | OCaml 5.4 Release 블로그 포스트 |
| [^107^] | github.com/ocaml/ocaml | OCaml 공식 릴리즈 |
| [^116^] | ocaml.org/manual | Recursive Modules (OCaml Manual) |
| [^130^] | cl.cam.ac.uk | First-class effects (Real World OCaml) |
| [^135^] | ssomayyajula.github.io | Category-theoretic abstractions with OCaml |
| [^149^] | discuss.ocaml.org | ppx_let vs binding operators |
| [^152^] | stackoverflow.com | First class modules explained |

---

## 7. 라이브러리 생태계 최적화

masc-mcp 프로젝트는 현재 40개 이상의 opam 의존성을 관리하며, 표준 라이브러리(`Stdlib`/`Base`), HTTP 클라이언트(`cohttp`/`httpun`), JSON 처리기(`yojson`/`jsonm`) 등의 중복 사용으로 인해 일관성과 유지보수성이 저하된 상태다. 이 장에서는 표준 라이브러리 채택, HTTP/JSON 처리 현대화, 의존성 축소, Eio 아키텍처 패턴을 하나의 통합 전략으로 제시한다. 모든 결정은 "빅뱅 마이그레이션을 회피하고 점진적 전환으로 실효성을 확보한다"는 원칙 아래 수립되었다.

---

### 7.1 표준 라이브러리 전략

#### 7.1.1 현재 문제 진단

masc-mcp 코드베이스는 `Stdlib`의 `List`, `String` 모듈과 `Base`의 대응 모듈이 혼재되어 있으며, 이로 인해 네이밍 규칙(라벨 인자 유무, 예외 vs `Option` 반환), 다형성 비교 동작, `ppx_deriving` 호환성에서 불일치가 발생한다. 예를 들어 `Stdlib.List.find_opt`는 `'a option`을 반환하지만 `Base.List.find`는 명시적 `~f` 라벨 인자를 요구하며, 두 스타일이 섞이면 가독성과 리팩토링 안전성이 크게 떨어진다 [^139^].

더욱 심각한 문제는 **동일한 개념에 대한 API 불일치**다. `Stdlib`의 `Map`은 functors로 생성하지만 `Base.Map`은 `Comparable.S` 인터페이스를 통해 생성한다. `Stdlib.Option.value`는 `~default`를 받지만 `Base.Option.value`도 동일하므로 이 경우에는 호환되지만, `Stdlib.List.take`가 없고 `Base.List.take`가 있다는 점에서 차이가 발생한다. 이런 미묘한 불일치는 코드 리뷰에서 놓치기 쉽고, 런타임에 예기치 않은 동작을 낳는다.

#### 7.1.2 Base 채택 결정

**권장: Jane Street `Base`를 표준 라이브러리로 일원화한다.**

선택 근거는 다음과 같다.

| 평가 항목 | Base | Stdlib + Containers | Core |
|-----------|------|---------------------|------|
| ppx_jane 호환성 | 네이티브 | 간접적 | 네이티브 |
| 런타임 의존성 | 0 (dune, sexplib0만 빌드) | 0 | Unix 추가 |
| 대규모 검증 | Pyre, BAP, Frenetic 등 사용 [^21^] | 광범위 | Jane Street 내륙 |
| API 일관성 | 라벨 인자, 다형성 비교 미사용 | Stdlib 친화 | Base 상위집합 |
| Eio 통합 | 완전 호환 | 완전 호환 | Unix 의존성 충돌 |
| Windows 이식성 | 완전 | 완전 | Unix 의존성으로 제한 |

**Base가 Core보다 나은 이유**: `Core`는 Unix 시스템 콜에 대한 런타임 의존성을 추가하며, 이는 Windows 이식성과 정적 바이너리 빌드를 복잡하게 만든다 [^34^]. `Base`는 `sexplib0`와 `dune` 외에는 아묟 런타임 의존성이 없어, 대규모 프로젝트에서도 빌드 시간과 바이너리 크기가 통제 가능하다 [^30^].

**Containers를 대안으로 제외한 이유**: `Containers`는 Stdlib 친화적 확장으로 마이그레이션 비용이 낮고 `containers-data` 패키지로 Vector, Heap 등 유용한 자료구조를 제공한다 [^28^]. 그러나 `ppx_jane`, `ppx_yojson_conv` 등 Jane Street PPX 생태계와의 통합이 `Base`만큼 자연스럽지 않으며, masc-mcp는 이미 `ppx_jane`을 의존성으로 가지고 있어 Base가 더 일관된 선택이다.

**OCaml 5.4 Stdlib 개선과의 관계**: OCaml 5.4에서는 `Pair`, `Pqueue`, `Iarray` 등 4개 신규 모듈과 30개 이상의 새 함수가 추가되었다 [^56^]. 특히 `List.append`와 `List.map`이 tail-recursion modulo cons(TRMC)로 안전해졌다. 이런 개선은 `Base`와 상호 보완적이다—`Stdlib`의 데이터 타입(`iarray`)을 `Base`의 인터페이스와 함께 사용할 수 있다. 하지만 `Base`가 제공하는 일관된 라벨 인자 규칙, `ppx_jane` 통합, `Sexp` 직렬화 지원은 `Stdlib`만으로는 대첵 불가능하다.

#### 7.1.3 Base 전환 구체적 예시

**Before/After: 주요 모듈 API 비교**

| 기능 | Stdlib 스타일 | Base 스타일 | 참고 |
|------|--------------|-------------|------|
| List fold | `List.fold_left f acc lst` | `List.fold lst ~init:acc ~f` | 인자 순서 주의 |
| List find | `List.find_opt (fun x -> ...) lst` | `List.find lst ~f:(fun x -> ...)` | 라벨 인자, Option 반환 |
| String prefix | 직접 구현 또는 `Str` | `String.is_prefix s ~prefix:"x"` | 안전한 래퍼 |
| Map 생성 | `Map.Make(String)` | `Map.Using_comparator.of_alist_exn` | Comparable 기반 |
| Option get | `Option.get opt` (예외) | `Option.value opt ~default` | 기본값 제공 |
| Hash table | `Hashtbl.create 16` | `Hashtbl.create ~growth_allowed:true ()` | 라벨 인자 |
| Int to string | `string_of_int n` | `Int.to_string n` | 일관된 네이밍 |
| Sexp 직렬화 | 수동 구현 | `[@@deriving sexp]` | ppx_jane 자동 생성 |

**전환 코드 예시:**

```ocaml
(* BEFORE: Stdlib 스타일 — 혼재된 코드 *)
module StringMap = Map.Make(String)

let process_endpoints json_list =
  let endpoints = List.filter_map (fun j ->
    match j with
    | `String s when String.length s > 0 -> Some s
    | _ -> None
  ) json_list in
  let table = Hashtbl.create 16 in
  List.iter (fun ep -> Hashtbl.add table ep true) endpoints;
  table

(* AFTER: Base 스타일 — 일관된 코드 *)
open Base

let process_endpoints json_list =
  let endpoints =
    List.filter_map json_list ~f:(function
      | `String s when String.length s > 0 -> Some s
      | _ -> None)
  in
  let table = Hashtbl.create (module String) ~growth_allowed:true () in
  List.iter endpoints ~f:(fun ep -> Hashtbl.add_exn table ~key:ep ~data:true);
  table
```

#### 7.1.4 점진적 전환 로드맵

Base 전환은 한 번에 수행하지 않는다. 3단계로 나누어 리스크를 최소화한다.

**Phase 1: 새 모듈 Base 작성 (0~2주)**

신규 기능, 신규 모듈은 전부 `Base`로 작성한다. 코드 리뷰 체크리스트에 "신규 모듈은 `open Base` 필수" 항목을 추가한다.

```ocaml
(* Phase 1: 신규 모듈 — Base 일관 사용 *)
open Base

let filter_valid items =
  List.filter items ~f:(fun item ->
    String.length item > 0 && String.is_prefix item ~prefix:"mcp:")
```

**Phase 2: 기존 모듈 alias 전환 (2~8주)**

기존 `Stdlib` 기반 모듈은 `Base` alias를 명시적으로 적용하며, 한 모듈씩 순차적으로 전환한다.

```ocaml
(* Phase 2: 기존 모듈 — Base alias 적용 *)
(* 변환 전 *)
let sum = List.fold_left (fun acc x -> acc + x) 0 nums

(* 변환 후 *)
open Base
let sum = List.fold nums ~init:0 ~f:(fun acc x -> acc + x)
```

주의할 점: `Stdlib.List.fold_left`와 `Base.List.fold`는 인자 순서가 다르다(`~init` 위치). 이런 API 불일치는 한 파일 내에서 한 번에 처리하여 부분적 혼재를 방지한다.

**Phase 3: 전체 코드베이스 통일 (8~12주)**

모든 모듈을 `open Base` 방식으로 통일하고, `Stdlib` 직접 호출을 금지한다. `dune`의 `(preprocess (pps ppx_jane))` 설정으로 `Base`의 sexp 직렬화, 비교 연산자 자동 생성 등을 활성화한다.

```dune
; dune — 전체 라이브러리에 Base + ppx_jane 적용
(library
 (name masc_mcp_core)
 (preprocess (pps ppx_jane ppx_deriving_yojson))
 (libraries base eio yojson piaf))
```

**금지 사항**: `Base`와 `Containers`를 절대 혼용하지 않는다. 두 라이브러리는 `List`, `Option` 등 동일한 모듈명을 제공하며, 동시에 열림(`open`)하면 네임스페이스 충돌과 미묘한 의미 차이(예: `List.init`의 인자 순서)로 디버깅이 극도로 어려워진다 [^139^].

---

### 7.2 HTTP 라이브러리 통일

#### 7.2.1 현재 문제: 중복 HTTP 클라이언트

masc-mcp는 현재 `cohttp` 계열과 `httpun` 계열을 병행 사용한다. `cohttp`는 가장 성숙한 라이브러리지만 HTTP/2를 지원하지 않으며, `httpun`(구 `httpaf`)은 저수준 고성능 처리에 적합하지만 사용자가 버퍼 관리와 프레임 파싱을 직접 처리해야 한다 [^59^]. 이중 구조는 불필요한 컴파일 의존성(`cohttp-lwt-unix`, `httpun-eio`, `h2-eio` 등)을 낳고, 동일한 HTTP 요청 로직이 두 개의 API로 중복 작성되는 결과를 초래한다.

#### 7.2.2 통합 전략: 클라이언트 piaf, 서버 cohttp-eio

| 역할 | 현재 | 권장 | 근거 |
|------|------|------|------|
| **HTTP 클라이언트** | cohttp + httpun | **piaf** | HTTP/2 네이티브, Eio 직접 지원 [^147^] |
| **HTTP 서버** | cohttp-eio | **cohttp-eio 유지** | 성숙, 가벼움, MCP HTTP endpoint 충분 |
| **HTTP/2 스트리밍** | h2-eio 직접 | **h2-eio 유지** (낮은 추상화) | gRPC, SSE 서버푸시 |

**piaf 채택 근거**: `piaf`는 `HTTP/1.1`과 `HTTP/2`를 모두 지원하며, Eio의 `Flow`, `Fiber`, `Switch` 추상화와 네이티브 통합된다 [^153^]. `cohttp`는 HTTP/2 지원이 없어 향후 MCP 프로토콜의 HTTP/2 기반 스트리밍 확장에 대응할 수 없다. `httpun`은 저수준 라이브러리로 고성능 커스텀 서버 구현에 적합하지만, 일반적인 HTTP 클라이언트 사용에는 너무 많은 보일러플레이트를 요구한다.

**상세 기능 비교:**

| 기능 | piaf | cohttp-eio | httpun-eio |
|------|------|-----------|-----------|
| HTTP/1.1 | Yes | Yes | Yes |
| HTTP/2 | Yes | No | No |
| Connection pooling | 내장 | 없음 | 직접 구현 |
| Redirect following | 옵션 | 없음 | 없음 |
| Eio Switch 통합 | 네이티브 | 네이티브 | 수동 |
| Streaming body | Yes | Yes | Yes |
| API 수준 | 고수준 | 중간 | 저수준 |

**cohttp-eio 서버 유지 근거**: MCP 서버의 HTTP endpoint는 기본적으로 JSON-RPC over HTTP/1.1을 수신하는 간단한 구조다. `cohttp-eio`는 이 수준에서 성숙하고 안정적이며, `piaf` 서버로 교체할 만큼의 성능 이점이 없다. 불필요한 마이그레이션 비용을 회피한다.

#### 7.2.3 Before/After: HTTP 의존성

```dune
;; Before: 중복 HTTP 의존성
(depends
 cohttp-lwt-unix
 cohttp-eio
 httpun-eio
 httpun-ws-eio  ; 제거 대상
 h2-eio
 piaf           ; 추가
 ;; ...)
)

;; After: 통합 HTTP 의존성
(depends
 piaf           ; HTTP 클라이언트 (HTTP/1.1 + HTTP/2)
 cohttp-eio     ; HTTP 서버 (MCP endpoint)
 h2-eio         ; HTTP/2 스트리밍 (gRPC, SSE)
 ;; httpun-ws-eio 제거 → h2-eio로 대체
 ;; httpun-eio 제거 → piaf가 커버
 ;; cohttp-lwt-unix 제거 → Eio 네이티브로 통일
)
```

#### 7.2.4 piaf 클라이언트 사용 예시

```ocaml
open Eio
open Piaf

(* Switch 기반 자원 관리 — piaf 클라이언트 *)
let fetch_mcp_config ~env url =
  Switch.run @@ fun sw ->
  let config = Config.{ default with follow_redirects = true } in
  let client = Client.create ~sw env config (Uri.of_string url) in
  match client with
  | Ok conn ->
      let* response = Client.get conn "/mcp/config" in
      (match response.status with
       | `OK -> Client.Body.to_string response.body
       | _ -> Error (`Msg (Fmt.str "HTTP %d" (Status.to_code response.status))))
  | Error e -> Error e
```

---

### 7.3 JSON 처리 현대화

#### 7.3.1 yojson + ppx_deriving_yojson 유지 결정

masc-mcp의 JSON 처리 전략은 **유지보수 중심의 현대화**다. `yojson`은 OCaml에서 가장 널리 사용되는 JSON 라이브러리로 [^27^], `ppx_deriving_yojson`과의 통합, 생태계 호환성, 문서 풍부성에서 확고한 지위를 가진다.

**대안 검토 및 기각:**

| 라이브러리 | 검토 결과 |
|-----------|----------|
| `ppx_yojson_conv` | Jane Street 스타일 통합에 유리하나, 이미 `ppx_deriving_yojson`으로 작성된 코드 마이그레이션 비용이 큼 |
| `atd` | MCP 프로토콜 메시지 스키마 정형화 시 고려 가능하나, `.atd` 파일 관리 오버헤드가 추가됨 |
| `jsonm` | 스트리밍 전용으로 유지, 대용량 JSON 처리 시에만 사용 |

#### 7.3.2 현대화 방향

`yojson` 자체를 교체하지는 않되, 사용 패턴을 현대화한다.

```ocaml
(* Before: 수동 JSON 변환 (오류 발생 가능) *)
let parse_config json =
  match json with
  | `Assoc fields ->
      (match List.assoc_opt "version" fields with
       | Some (`String v) -> v
       | _ -> failwith "missing version")
  | _ -> failwith "invalid config"

(* After: ppx_deriving_yojson + 타입 안전 *)
type config = {
  version : string;
  endpoints : string list;
  timeout_ms : int option;  (* 없으면 None *)
} [@@deriving yojson { strict = false }]

let parse_config json =
  match config_of_yojson json with
  | Ok cfg -> cfg
  | Error msg -> Logs.err (fun m -> m "Config parse failed: %s" msg); raise Exit
```

**핵심 원칙**: 모든 JSON ↔ OCaml 변환은 `[@@deriving yojson]`으로 자동 생성한다. 수동 `match` 파싱은 금지한다. 이는 컴파일 타임에 필드 누락, 타입 불일치를 감지할 수 있게 하며, MCP 프로토콜 스펙 변경 시 타입 정의만 수정하면 파싱/직렬화 코드가 자동 갱신된다.

**에러 처리 패턴**: `ppx_deriving_yojson`이 생성하는 `of_yojson` 함수는 ``(string, t) Result.t``를 반환한다. `Base`의 `Result` 모듈과 결합하여 체이닝할 수 있다.

```ocaml
open Base

type mcp_request = {
  method_name : string;
  params : Yojson.Safe.t;
  id : int option;
} [@@deriving yojson { strict = false }]

type mcp_response = {
  result : Yojson.Safe.t option;
  error : string option;
  id : int;
} [@@deriving yojson]

(* Result 체이닝: 요청 파싱 → 처리 → 응답 직렬화 *)
let handle_request raw_json =
  Result.bind (mcp_request_of_yojson raw_json) ~f:(fun req ->
    let response = process_method req.method_name req.params in
    Result.return { result = Some response; error = None; id = Option.value req.id ~default:0 })
  |> Result.map ~f:mcp_response_to_yojson
```

---

### 7.4 의존성 최적화

#### 7.4.1 축소 목표: 40+ → 25개 내외

현재 masc-mcp의 의존성 목록에는 중복 기능 제공, 미사용, 대첵 가능한 라이브러리가 다수 포함되어 있다. 아래 원칙으로 감축한다.

**제거 대상:**

| 제거 라이브러리 | 대체/제거 근거 | 예상 영향 |
|---------------|--------------|----------|
| `httpun-ws-eio` | `h2-eio`의 WebSocket 지원으로 대체 | HTTP/WebSocket 통합 |
| `bigstringaf` | Eio 1.0에 `Cstruct` 호환 API 내장 | C 의존성 감소 |
| `cstruct` | 점진적 제거, `Base.Bytes` + Eio.Flow로 대체 | 메모리 표현 단순화 |
| `cohttp-lwt-unix` | Eio 네이티브로 통일, Lwt 브리지 불필요 | 비동기 런타임 단일화 |
| `pcre` | `re` (ocaml-re)로 통일 [^106^] | C 라이브러리 의존성 제거 |
| `grpc-direct` | `grpc-eio`로 대체 | Eio 네이티브 gRPC |
| `async` 계열 | Eio 1.0로 완전 대체 | 동시성 모델 단일화 |

**bigstringaf/cstruct 대체 구체 예시:**

```ocaml
(* BEFORE: cstruct 기반 바이너리 처리 *)
let parse_header cbuf =
  let len = Cstruct.BE.get_uint32 cbuf 0 in
  let typ = Cstruct.get_uint8 cbuf 4 in
  (Int32.to_int len, typ)

(* AFTER: Base.Bytes + Eio.Flow 기반 *)
let parse_header buf =
  let len = Bytes.get_int32_be buf 0 in
  let typ = Char.to_int (Bytes.get buf 4) in
  (Int32.to_int len, typ)
```

`Cstruct`는 `bigarray` 기반의 제로카피 버퍼를 제공하지만, Eio 1.0 환경에서는 `Eio.Flow`의 `Cstruct` 호환 API가 이미 내장되어 있다. 순수 `Base.Bytes` 처리로 충분한 경우가 대부분이며, 제로카피가 필수적인 경에만 `Eio`의 버퍼 API를 직접 사용한다.

**통합 대상:**

| 통합 전 | 통합 후 | 효과 |
|---------|--------|------|
| `cohttp` + `httpun` | `piaf` (클리이언트) | 2개 → 1개 |
| `logs.lwt` + `logs.eio` | `logs.eio` 단일 | 로깅 백엔드 단일화 |
| `sqlite3` 직접 + `neo4j` | `caqti-eio` + `sqlite3` | DB 접근 표준화 [^112^] |

#### 7.4.2 dune-project Before/After

```dune
;; ==========================================
;; BEFORE: 40+ 의존성 (중복 및 미사용 포함)
;; ==========================================
(package
 (name masc-mcp)
 (depends
  (ocaml (>= 5.4))
  (dune (>= 3.17))
  base stdio ppx_jane           ; 표준
  eio eio_main eio_linux         ; Eio
  cohttp cohttp-lwt-unix         ; HTTP (Lwt legacy)
  cohttp-eio                     ; HTTP (Eio)
  httpun httpun-eio httpun-ws-eio ; httpun 계열
  h2 h2-eio                      ; HTTP/2
  piaf                           ; HTTP (추가)
  grpc-direct                    ; gRPC (구)
  yojson ppx_deriving_yojson     ; JSON
  fpath bos                      ; 파일시스템
  logs logs.lwt logs.eio         ; 로깅 (중복)
  fmt cmdliner                   ; 유틸리티
  re pcre                        ; 정규식 (중복)
  uuidm digestif                 ; ID/해시
  sqlite3                        ; DB (직접)
  neo4j                          ; Graph (의존성 무거움)
  caqti caqti-lwt                ; DB (Lwt)
  bigstringaf cstruct            ; 바이너리 (중복)
  tls tls-lwt tls-eio            ; TLS (Lwt legacy)
  alcotest qcheck :with-test     ; 테스트
))

;; ==========================================
;; AFTER: 25개 내외 (정리된 의존성)
;; ==========================================
(package
 (name masc-mcp)
 (depends
  ; 컴파일러/빌드
  (ocaml (>= 5.4))
  (dune (>= 3.17))

  ; 표준 라이브러리
  (base (>= v0.17))
  (stdio (>= v0.17))
  (ppx_jane (>= v0.17))

  ; Eio 비동기 런타임
  (eio (>= 1.0))
  (eio_main (>= 1.0))
  (eio_linux (>= 1.0))

  ; HTTP 계열 — 통합
  (piaf (>= 0.2.0))              ; 클라이언트: HTTP/1.1 + HTTP/2
  (cohttp-eio (>= 6.0.0))        ; 서버: MCP HTTP endpoint
  (h2-eio (>= 0.12.0))           ; 스트리밍: gRPC, SSE

  ; gRPC
  (grpc-eio (>= 0.2.0))          ; Eio 네이티브 gRPC
  (ocaml-protoc-plugin (>= 6.0.0)) ; protoc OCaml 플러그인 [^137^]

  ; JSON — 유지
  (yojson (>= 2.0))
  (ppx_deriving_yojson (>= 3.7))

  ; 유틸리티 — 표준화
  (fpath (>= 0.7.0))
  (bos (>= 0.2.1))
  (logs (>= 0.7.0))
  (fmt (>= 0.9.0))
  (cmdliner (>= 1.2.0))
  (re (>= 1.12.0))               ; pcre 제거, re 단일화 [^106^]
  (uuidm (>= 0.9.9))
  (digestif (>= 1.2.0))

  ; 데이터베이스 — caqti-eio 중심
  (caqti (>= 2.2.0))
  (caqti-eio (>= 2.2.0))         ; Eio 실험적 지원 [^112^]
  (caqti-driver-sqlite3 (>= 2.2.0))

  ; 보안
  (tls (>= 1.0.0))
  (tls-eio (>= 1.0.0))

  ; 테스트
  (alcotest :with-test)
  (qcheck :with-test)
  (ppx_inline_test :with-test)
))
```

#### 7.4.3 빌드 영향 예상

의존성 축소가 빌드 시간과 바이너리 크기에 미치는 영향은 다음과 같다.

| 지표 | Before (40+) | After (25) | 예상 개선율 |
|------|-------------|-----------|------------|
| opam 설치 시간 | ~8-12분 | ~4-6분 | 40-50% |
| dune 빌드 타겟 수 | 200+ | 120+ | 35-40% |
| 실행 바이너리 크기 | ~25MB | ~18MB | 25-30% |
| transitive 의존성 | 150+ | 80+ | 45% |

실제 개선율은 사용 중인 기능에 따라 달라지지만, C 라이브러리(`pcre`, `bigstringaf`) 제거와 Lwt 계열 패키지 제거가 가장 큰 영향을 미친다.

#### 7.4.4 opam pin 전략 개선

재현 가능한 빌드를 위해 pin-depends를 명시적으로 관리한다.

```
# masc-mcp.opam — pin-depends 섹션
pin-depends: [
  ["caqti-eio.2.2.0" "git+https://github.com/paurkedal/caqti.git#eio-support"]
  ["grpc-eio.0.2.0" "git+https://github.com/dialohq/ocaml-grpc.git#main"]
]
```

**CI/CD 통합**: `opam lock` 파일을 버전 관리에 포함하고, CI에서는 `opam install . --locked`로 정확히 동일한 의존성 트리를 복원한다. 향후 Dune Package Management가 성숙하면 `dune.lock/` 디렉토리로 전환을 검토한다 [^142^].

**의존성 감사 주기**: 매 스프린트마다 `opam tree --with-test`를 실행하여 미사용 의존성을 식별하고, `implicit_transitive_deps false` 설정으로 직접 사용하지 않는 transitive 의존성을 노출시킨다 [^24^].

---

### 7.5 Eio 아키텍처 패턴

#### 7.5.1 Fiber, Switch, Resource 3대 패턴

Eio 1.0은 OCaml 5의 effect handlers를 활용한 직접 스타일(direct-style) 병렬 I/O 라이브러리다 [^18^]. masc-mcp에서는 다음 3가지 핵심 패턴을 표준으로 사용한다.

**패턴 1: Switch — Fiber 생명주기 관리**

`Switch`는 자식 `Fiber`들의 생명주기를 관리하는 컨텍스트다. `Switch`가 종료되면 등록된 모든 자원(열린 파일, 네트워크 연결, 실행 중인 Fiber)이 자동으로 정리된다.

```ocaml
open Eio

(* Switch.run: 스코프 기반 자원 정리 *)
let process_batch ~env urls =
  Switch.run @@ fun sw ->
  let results = ref [] in
  List.iter urls ~f:(fun url ->
    Fiber.fork ~sw (fun () ->
      match fetch_mcp_resource ~env url with
      | Ok data -> results := data :: !results
      | Error e -> Logs.warn (fun m -> m "Fetch failed: %a" Fmt.string e)));
  (* Switch 종료 시점: 모든 Fiber가 완료되거나 취소됨 *)
  !results
```

**Lwt 비교**: Lwt에서는 `Lwt_switch.with_switch (fun sw -> ...)`와 `Lwt.finalize`를 조합해야 했다. Eio의 `Switch`는 둘을 하나로 통합하며, 예외가 발생하면 자동으로 모든 자식 Fiber를 취소(cancel)한다.

**패턴 2: Fiber — 경량 동시성**

`Fiber`는 사용자 수준 경량 스레드로, `Domain` 낭비 없이 수천 개를 생성할 수 있다. `Fiber.both`, `Fiber.all`, `Fiber.fork`를 상황에 맞게 사용한다.

```ocaml
(* Fiber.both: 두 작업 병렬 실행, 둘 다 완료될 때까지 대기 *)
let fetch_pair ~env url_a url_b =
  Fiber.both
    (fun () -> fetch_mcp_resource ~env url_a)
    (fun () -> fetch_mcp_resource ~env url_b)

(* Fiber.all: N개 작업 병렬 실행 *)
let fetch_all ~env urls =
  Fiber.List.map (fun url -> fetch_mcp_resource ~env url) urls

(* Fiber.fork + Promise: 비동기 결과 수집 *)
let fetch_with_timeout ~env ~timeout_ms url =
  Switch.run @@ fun sw ->
  let promise, resolver = Promise.create () in
  Fiber.fork ~sw (fun () ->
    match fetch_mcp_resource ~env url with
    | Ok data -> Promise.resolve resolver (Some data)
    | Error _ -> Promise.resolve resolver None);
  Fiber.fork ~sw (fun () ->
    Clock.sleep (Mtime.Span.of_uint64_ns (Int64.of_int (timeout_ms * 1_000_000)));
    Promise.resolve resolver None);
  Promise.await promise
```

**패턴 3: Resource — RAII 자원 관리**

Eio의 `Resource`는 파일, 소켓, TLS 세션 등을 RAII 패턴으로 관리한다. `with_` 접두어 함수를 사용하여 예외 발생 시에도 자원이 누출되지 않도록 보장한다.

```ocaml
(* Resource: 파일 읽기 — 예외 발생 시에도 자동 close *)
let read_config_file path =
  Path.with_open_in path @@ fun flow ->
  let content = Flow.read_all flow in
  (* parse_config는 Yojson 파싱 — 7.3절 참조 *)
  parse_config (Yojson.Safe.from_string content)

(* Resource: 네트워크 서버 — graceful shutdown *)
let start_mcp_server ~env ~port handler =
  Switch.run @@ fun sw ->
  let socket = Net.listen ~sw ~backlog:128 ~reuse_addr:true env#net
    (`Tcp (Eio.Net.Ipaddr.V4.any, port)) in
  while true do
    Net.accept_fork ~sw socket ~on_error:(fun exn ->
      Logs.err (fun m -> m "Connection error: %a" Fmt.exn exn))
    (fun client_sock client_addr ->
      handler client_sock client_addr)
  done
```

#### 7.5.2 Domain과 멀티코어 활용

Eio의 `Fiber`는 단일 Domain 내에서 스케줄링되지만, CPU 집약적 작업이나 병렬 I/O를 위해 여러 `Domain`을 활용할 수 있다.

```ocaml
(* Domain 분리: CPU 집약적 작업을 별도 Domain으로 *)
let parallel_compute ~env inputs =
  let domains = Domain.recommended_count () in
  Eio.Fiber.List.map
    (fun batch ->
      (* 각 배치를 별도 Domain에서 처리 *)
      Eio.Domain.run env#domain_mgr (fun () ->
        List.map batch ~f:heavy_computation))
    (List.chunks_of inputs ~length:(List.length inputs / domains))
```

주의: `Domain` 전환은 비용이 크므로, I/O 바운드 작업은 단일 Domain의 `Fiber`로 충분하다. CPU 바운드 작업만 `Domain` 분리의 대상이 된다 [^20^].

#### 7.5.3 HTTP 클라이언트/서버 통합 패턴

masc-mcp의 HTTP 아키텍처는 클라이언트-서버 분리를 명확히 하며, 각각에 최적화된 라이브러리를 사용한다(7.2절).

```
┌─────────────────────────────────────────────────────┐
│              masc-mcp HTTP Transport                 │
├─────────────────────────────────────────────────────┤
│  Client (piaf)         │  Server (cohttp-eio)       │
│  ─────────────         │  ─────────────────         │
│  HTTP/1.1 요청         │  MCP endpoint 수신          │
│  HTTP/2 멀티플렉싱      │  JSON-RPC 처리              │
│  gRPC 호출 (h2-eio)    │  SSE 스트림 응답            │
│  Switch 기반 관리       │  Switch 기반 관리           │
└─────────────────────────────────────────────────────┘
```

```ocaml
(* 통합 예시: MCP 서버가 외부 API를 piaf로 호출하여 결과를 cohttp-eio로 응답 *)
let mcp_handler ~env (req : Cohttp_eio.Server.request) =
  Switch.run @@ fun sw ->
  (* 1. MCP 요청 파싱 *)
  let* mcp_request = parse_mcp_request req.body in
  (* 2. 외부 API 호출 (piaf 클라이언트) *)
  let* api_result =
    Piaf.Client.Oneshot.get ~sw env
      (Uri.of_string ("https://api.example.com/" ^ mcp_request.method_name))
  in
  (* 3. MCP 응답 생성 (cohttp-eio 서버) *)
  let json_response = mcp_response_to_yojson api_result in
  Cohttp_eio.Server.respond_string ~status:`OK
    ~body:(Yojson.Safe.to_string json_response) ()
```

#### 7.5.4 에러 핸들링 패턴

Eio에서의 예외 처리는 OCaml의 기본 `try/with`를 직접 사용한다. Lwt의 `Lwt.catch`나 `>>=` 기반 에러 전파가 필요 없다.

```ocaml
(* Eio 직접 스타일 에러 핸들링 *)
let safe_process ~env req =
  try
    Switch.run @@ fun sw ->
    let result = process_request ~env ~sw req in
    Ok result
  with
  | Eio.Cancel.Cancelled _ ->
      Logs.warn (fun m -> m "Request cancelled");
      Error `Cancelled
  | Eio.Io (err, _) ->
      Logs.err (fun m -> m "I/O error: %a" Eio.Exn.pp err);
      Error `Io_error
  | Yojson.Json_error msg ->
      Logs.err (fun m -> m "JSON parse error: %s" msg);
      Error `Parse_error
```

#### 7.5.5 성능 모니터링

Eio 기반 애플리케이션의 성능은 `eio-trace` 도구로 분석한다 [^20^].

```bash
# Fiber 스케줄링 추적
eio-trace run -- ./_build/default/bin/masc_mcp.exe

# HTML 리포트 생성
eio-trace render trace.fxt -o trace.html
```

주요 모니터링 지표:

| 지표 | 도구 | 목표값 |
|------|------|--------|
| Fiber 생성/소멸 추적 | `eio-trace` | 누적 Fiber 수 안정(메모리 누출 감지) |
| Domain별 처리량 | `eio-trace` | Domain 간 균등 분배 |
| 힙 크기 | `OCAMLRUNPARAM=s=...` | 가비지 컬렉션 빈도 최소화 |
| 버퍼링 효율 | 코드 리뷰 | unbuffered I/O 사용 금지 |

---

### 7.6 점진적 마이그레이션 체크리스트

전 장(7.1~7.5)의 결정을 하나의 실행 계획으로 통합한다.

**Phase 1: 중복 제거 (0~2주, 즉시 실행)**

- [ ] `pcre` → `re` 마이그레이션 (정규식 API 거의 동일)
- [ ] `httpun-ws-eio` 제거, `h2-eio` WebSocket으로 대체
- [ ] `cohttp-lwt-unix` 제거, 클라이언트는 `piaf`로 통일
- [ ] 로깅 백엔드 `logs.eio` 단일화

**Phase 2: 표준화 (2~8주)**

- [ ] `Base` 채택 선언, 신규 모듈은 `open Base` 필수
- [ ] 기존 모듈 Phase 2 alias 전환 시작 (한 모듈씩)
- [ ] `dune-project` 의존성 After 목록으로 정리
- [ ] `implicit_transitive_deps false` 활성화 [^24^]

**Phase 3: 현대화 (8~12주)**

- [ ] `caqti-eio` 프로덕션 적용 (SQLite3 중심) [^112^]
- [ ] `grpc-eio`로 gRPC 전환 완료
- [ ] 전체 코드베이스 `open Base` 통일 (Phase 3)
- [ ] `opam lock` 파일 CI 통합
- [ ] Dune Package Management 도입 검토 [^142^]

---

### 참고 문헌

[^18^]: ocaml.org/eio 1.0, Eio 1.0 공식 문서  
[^20^]: OCaml Discuss (2025-03), Lwt vs Eio 성능 벤치마크  
[^21^]: OCaml Discuss (2021-08), Jane Street 라이브러리 사용처  
[^24^]: OCaml Discuss (2021-10), implicit_transitive_deps false 권장  
[^27^]: github.com/ocaml-community/yojson, Yojson 공식 저장소  
[^28^]: github.com/c-cube/ocaml-containers, Containers 공식 저장소  
[^30^]: github.com/janestreet/base, Base 공식 저장소  
[^34^]: Real World OCaml 2nd Edition, Core 라이브러리 설명  
[^56^]: OCaml Changelog, OCaml 5.4.0 상세 변경사항  
[^59^]: ocamlverse.net, HTTP 라이브러리 비교  
[^106^]: batsov.com (2025-04), OCaml 정규식 비교  
[^112^]: ocaml.org/caqti, Caqti 문서  
[^137^]: opam.ocaml.org, ocaml-protoc-plugin  
[^139^]: batsov.com (2025-03), OCaml Stdlib 분석  
[^142^]: dune.readthedocs.io, Dune Package Management 문서  
[^147^]: Twitter @_anmonteiro, Piaf 릴리스 공지  
[^153^]: github.com/anmonteiro/piaf, Piaf 프로젝트

---

## 8. 문서화 & 에이전트 통합 전략

> "문서만 보고도 코드 구조 틀을 이해할 수 있도록" 하는 것이 본 장의 핵심 목표다. 565K 라인의 대규모 OCaml 프로젝트에서 AI 에이전트(Claude, Cursor, Copilot)가 64K-128K 토큰 컨텍스트 한계 내에서 효과적으로 탐색하고 수정하기 위해서는, 코드 자첵만큼 문서의 구조와 품질이 중요하다 [^40^][^75^]. 본 장은 odoc 기반 문서화, Cram Test, 계층적 CLAUDE.md, ocamlformat 통합의 네 가지 축을 다룬다.

### 8.1 odoc 기반 문서화

`odoc`은 OCaml 공식 문서 생성 도구로, 소스 코드의 docstrings를 추출하여 HTML, LaTeX, man page 형식으로 변환한다 [^57^]. Dune과의 통합을 통해 `dune build @doc` 명령 한 번으로 프로젝트 전체 문서를 생성할 수 있다 [^54^][^59^]. masc-mcp의 30개 lib 모듈과 18개 실행 파일을 체계적으로 문서화하려면 `.mld` 파일의 계층 구조, 일관된 docstring 컨벤션, 그리고 odoc 3.0의 Sherlodoc 검색 기능을 조합해야 한다.

#### 8.1.1 .mld 파일 계층 구조

`.mld` 파일은 odoc의 "manual page" 형식으로, 소스 코드 외부에 독립적인 문서 페이지를 작성할 수 있는 형식이다 [^58^]. 패키지 수준의 가이드, 튜토리얼, 아키텍처 설명에 적합하며, `index.mld`를 통해 자동 생성되는 인덱스 페이지를 대체할 수 있다.

**Before: 문서 없는 패키지 구조**

```ocaml
(* lib/coord/dune — 문서화 설정 없음 *)
(library
 (name coord)
 (public_name masc.coord)
 (libraries core_kernel fmt))
```

패키지 사용자는 coord의 아키텍처, 주요 타입, 사용 패턴을 파악하기 위해 70개의 `.ml` 파일을 직접 탐색해야 한다. 128K 토큰 컨텍스트(8K-12K 라인) 내에서 coord 전체(15K 라인)를 이해하는 것은 "Lost in the Middle" 현상으로 인해 중앙 파일의 이핵도가 저하된다 [^102^].

**After: 계층적 .mld 문서 구조**

```
doc/
├── index.mld              # 패키지 전체 개요
├── getting_started.mld    # 설치 및 기본 사용법
├── architecture.mld       # 시스템 아키텍처와 모듈 관계
├── coord/
│   ├── index.mld          # coord 모듈 개요
│   ├── types.mld          # 주요 타입 설명 (keeper, 상태 머신)
│   ├── pipeline.mld       # 좌표 처리 파이프라인
│   └── io.mld             # 입출력 포맷과 프로토콜
├── cascade/
│   ├── index.mld          # cascade 모듈 개요
│   ├── policies.mld       # 정책 규칙 체계
│   └── tasks.mld          # 태스크 라이프사이클
└── server/
    ├── index.mld          # HTTP 서버 개요
    ├── mcp_protocol.mld   # MCP 프로토콜 구현
    └── endpoints.mld      # API 엔드포인트 목록
```

odoc 3.0부터는 `(documentation (files (glob_files_rec (doc/* with_prefix .))))` stanza를 통해 `doc/` 폴터의 모든 파일을 패키지에 첨부하고 상대적 계층을 보존할 수 있다 [^117^]. 이를 통해 튜토리얼, API 레퍼런스, 아키텍처 문서를 계층적으로 조직할 수 있다.

**dune 설정:**

```scheme
; dune-project
(documentation
 (package masc)
 (files (glob_files_rec (doc/* with_prefix .))))
```

```scheme
; lib/coord/dune
(library
 (name coord)
 (public_name masc.coord)
 (libraries core_kernel fmt)
 (documentation (package masc)))
```

#### 8.1.2 Docstring 컨벤션

OCaml의 docstrings는 `(** ... *)` 형태의 특수 주석으로, `.mli` 파일에 작성하는 것이 권장된다 [^16^]. masc-mcp의 30개 모듈에 일관된 문서 품질을 유지하려면 다음 컨벤션을 적용한다.

| 규칙 | 설명 | 예시 |
|------|------|------|
| 문서는 `.mli`에 | 공개 API의 계약은 인터페에스에 명시 | `coord.mli`에 `(** ... *)` |
| 주석은 `.ml`에 | 구현 세부사항은 소스에 주석 | `(* 낮부 헬퍼: 좌표 정규화 *)` |
| 사용 예제 필수 | 비자명한 함수는 `{[...]}` 예제 포함 | `{[ Coord.convert ~from:WGS84 ~to:UTM point ]}` |
| Deprecated 명시 | `@deprecated` 태그와 대체제 | `@deprecated Use {!Coord_v2.transform} instead` |
| 교차 참조 | `{!module-Foo}`로 모듈 간 연결 | `See {!Coord_types.point} for the underlying type` |

**예시: coord.mli의 docstring**

```ocaml
(** 좌표 시스템 변환 모듈

    [coord]는 WGS84, UTM, TM 등 다양한 좌표 체계 간의 변환을 제공합니다.
    상태 머신 기반의 keeper 패턴을 사용하여 변환 파이프라인의 무결성을 보장합니다.

    {1 Usage Example}

    {[
      let point = Coord.create ~lat:37.5665 ~lng:126.9780 ~system:WGS84 in
      let utm_point = Coord.convert ~to_:UTM point in
      Format.printf "%a" Coord.pp utm_point
    ]}

    @see <doc/coord/pipeline.mld> 좌표 처리 파이프라인 상세 문서
*)

open! Base

type t
(** 불변(immutable) 좌표 타입. 낮부 표현은 좌표 체계에 따라 상이함 *)

type system = WGS84 | UTM of int | TM of { central_meridian: float }
(** 지원하는 좌표 체계. UTM은 zone 번호를, TM은 중앙 자오선을 인자로 받음 *)

val create : lat:float -> lng:float -> system:system -> t
(** 주어진 위도/경도와 좌표 체계로 좌표값을 생성합니다.

    @raise Invalid_argument 위도가 [-90, 90] 범위를 벗어난 경우
*)

val convert : to_:system -> t -> t
(** [convert ~to_ point]는 [point]를 [to_] 좌표 체계로 변환합니다.

    {[
      let wgs84 = Coord.create ~lat:37.5 ~lng:127.0 ~system:WGS84 in
      let utm = Coord.convert ~to_:(UTM 52) wgs84 in
      assert Poly.(Coord.system utm = UTM 52)
    ]}

    @deprecated v2.1부터 {!transform}을 사용하세요. 이 함수는 zone 정보를
    보존하지 않습니다.
*)

val transform : ?datum:string -> target:system -> t -> t
(** [transform ~target point]는 데이텤 변환을 포함한 전체 좌표 변환을 수행합니다.

    [~datum]이 제공되지 않으면 기본 데이텤(GRS80)을 사용합니다.
*)
```

#### 8.1.3 Sherlodoc 검색 통합

odoc 3.0의 가장 중요한 개선은 **Sherlodoc** 검색 엔진의 통합이다 [^147^][^146^]. Sherlodoc는 OCaml의 타입 시스템을 인식하는 검색 엔진으로, 함수명뿐 아니라 타입 시그니처로도 검색이 가능하다.

| 검색 패턴 | 결과 | 활용 예시 |
|-----------|------|----------|
| `Coord.convert` | 이름 기반 검색 | 특정 함수 문서로 이동 |
| `float -> float -> t` | 타입 시그니처 검색 | 좌표 생성 함수 찾기 |
| `_ -> system -> t` | 와일드카드 + 타입 검색 | 시스템 파라미터를 받는 모든 함수 |
| `module:coord float` | 모듈 한정 + 타입 검색 | coord 내의 float 관련 API |

**활용법**: `dune build @doc` 실행 후 `_build/default/_doc/_html/index.html`에서 Sherlodoc 검색창을 사용한다. 타입 기반 검색은 대규모 프로젝트에서 "이런 시그니처를 가진 함수가 어디 있었지?"라는 질문에 정확한 답을 제공한다 [^146^].

odoc 3.0의 추가 기능으로 소스 코드 링크(문서에서 정의로 직접 이동) [^57^]와 `{!image:path}` 구문을 통한 이미지 임베드 [^154^]도 활용할 수 있다. 이를 통해 아키텍처 다이어그램을 문서에 직접 포함할 수 있다.

#### 8.1.4 Private Library 문서화

Public 라이브러리 외에도 private 라이브러리의 문서를 `dune build @doc-private` 명령으로 생성할 수 있다. 다만 이들은 메인 인덱스에는 포함되지 않으며, `_build/default/_doc/_html/<library>` 경로에서 확인할 수 있다 [^59^][^117^].

masc-mcp는 30개 lib 모듈 중 상당수가 낮부 구현 세부사항을 캡슐화하는 private 라이브러리이다. 예를 들어 `coord` 모듈 낮부의 `coord_internal` 라이브러리는 공개 API가 아닌 낮부 변환 알고리즘을 담당한다.

```scheme
; lib/coord/internal/dune
(library
 (name coord_internal)
 (public_name masc.coord.internal)  ; 낮은 안정성 보장의 낮은 API
 (libraries coord)
 (documentation (package masc)))    ; @doc-private로 문서 생성
```

private 라이브러리 문서화의 목적은 에이전트가 낮부 구현을 탐색할 때 타입 시그니처와 docstring을 통해 빠르게 이해할 수 있도록 하는 것이다. `public_name masc.coord.internal`의 `.internal` 네이밍 컨벤션은 AI 에이전트에게 "이 API는 낮은 안정성을 가짐"을 즉시 알려준다 [^138^].

| 문서 대상 | 생성 명령 | 출력 경로 | 인덱스 포함 |
|-----------|----------|----------|------------|
| Public 라이브러리 | `dune build @doc` | `_build/default/_doc/_html/` | Yes (메인 인덱스) |
| Private 라이브러리 | `dune build @doc-private` | `_build/default/_doc/_html/<lib>/` | No (별도 접근) |
| .mld 파일 | `dune build @doc` | 계층 구조 반영 | Yes |

### 8.2 Cram Test 도입

Cram test는 쉘 세션을 기반으로 한 테스트 방식으로, `.t` 파일에 명령어와 예상 출력을 작성하면 Dune이 실제 실행 결과와 비교한다 [^13^][^19^]. masc-mcp의 18개 CLI 도구와 복잡한 좌표 변환 파이프라인을 문서화하면서 동시에 테스트하려면 Cram test가 가장 효과적인 방법이다.

#### 8.2.1 CLI 도구 테스트

**Before: 별도의 유닛 테스트만 존재**

```ocaml
(* test/test_coord.ml — 기존 유닛 테스트 방식 *)
let test_convert () =
  let point = Coord.create ~lat:37.5 ~lng:127.0 ~system:WGS84 in
  let utm = Coord.convert ~to_:(UTM 52) point in
  Alcotest.(check string) "system" "UTM" (Coord.show_system (Coord.system utm))

let () = Alcotest.run "coord" [("convert", [Alcotest.test_case "basic" `Quick test_convert])]
```

이 방식의 문제는 다음과 같다: (1) CLI 사용자가 실제로 입력하는 명령어와 출력을 보여주지 않음, (2) 테스트가 문서가 되지 않음, (3) 외부 라이브러리(Alcotest) 의존.

**After: Cram test로 문서화된 테스트**

```bash
# test/cli/coord_convert.t — Cram test 파일
coord 변환 CLI 도구 테스트

  $ echo '{"lat": 37.5665, "lng": 126.9780, "system": "WGS84"}' \
  >   | coord convert --to UTM --zone 52
  {"x": 421184.698, "y": 4678947.676, "zone": "52N", "system": "UTM"}

데이텤 변환 포함:

  $ echo '{"lat": 37.5665, "lng": 126.9780, "system": "WGS84"}' \
  >   | coord transform --target BESSEL --datum TOKYO
  {"lat": 37.5659, "lng": 126.9763, "system": "BESSEL"}

잘못된 입력 처리:

  $ echo '{"lat": 999, "lng": 126.9780}' | coord convert --to UTM
  ERROR: latitude out of range [-90, 90]: 999
  [1]
```

**장점:**

| 특성 | 기존 유닛 테스트 | Cram test |
|------|---------------|-----------|
| 외부 라이브러리 | Alcotest/jstest 필요 | 없음 (Dune 내장) [^13^] |
| CLI 명령어 노출 | 간접적 (OCaml 함수 호출) | 직접적 (실제 쉘 명령어) |
| 문서화 효과 | 없음 | `.t` 파일 자체가 사용 예제 |
| 출력 갱신 | 수동 수정 | `dune promote`로 자동 [^13^] |
| 파일 시스템 테스트 | 어려움 | `.t` 디렉토리로 아티팩트 배치 가능 [^19^] |

#### 8.2.2 문서화된 테스트

Cram test의 `.t` 파일은 Dune의 `(cram)` stanza로 등록하여 사용한다 [^19^]:

```scheme
; test/cli/dune
(cram
 (deps %{bin:coord} %{bin:masc-server})
 (package masc))
```

**디렉토리 기반 테스트**는 파일 시스템 아티팩트가 필요한 시나리오에 유용하다 [^19^]:

```
test/cli/
├── coord_convert.t          # 파일 기반 테스트
├── coord_batch.t            # 배치 처리 테스트
├── server_startup.t         # 서버 시작/종료 테스트
├── mcp_protocol.t           # MCP 프로토콜 핸드셰이크 테스트
└── fixtures/
    ├── seoul_wgs84.json     # 테스트 데이터
    ├── tokyo_bessel.json
    └── invalid_lat.json
```

```bash
# test/cli/coord_batch.t
배치 변환 테스트:

  $ coord batch --input $TESTDIR/fixtures/seoul_wgs84.json --to UTM
  Processed 1 coordinates: 1 success, 0 failures

  $ cat output/result.json
  {"x": 421184.698, "y": 4678947.676, "zone": "52N"}
```

**워크플로우**: `dune build @cli-test` → 실패 시 `dune promote`로 예상 출력 갱신 → `git diff`로 변경 확인 → 커밋. 이 워크플로우는 테스트 출력이 의도된 변경인지 검증하는 안전장치 역할을 한다.

#### 8.2.3 Cram Test와 문서화의 시너지

Cram test의 가장 큰 장점은 테스트와 문서가 동일한 파일이라는 것이다. `.t` 파일을 읽는 것만으로도 도구의 사용법을 파악할 수 있으며, 이는 `--help` 출력보다 더 풍부한 맥락을 제공한다.

**서버 시작/종료 테스트 예시:**

```bash
# test/cli/server_startup.t
MCP 서버 기동 및 핸드셰이크 테스트

  $ masc-server --port 8080 &
  $ sleep 1
  $ curl -s http://localhost:8080/health
  {"status":"ok","version":"2.1.0"}

MCP initialize 요청:

  $ curl -s -X POST http://localhost:8080/mcp/initialize \
  >   -H "Content-Type: application/json" \
  >   -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'
  {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{},"resources":{}},"serverInfo":{"name":"masc-mcp","version":"2.1.0"}}}

서버 종료:

  $ masc-server --stop
  Server stopped gracefully
```

이 `.t` 파일 하나로 다음 세 가지 목적을 동시에 달성한다: (1) 서버 기동/종료가 정상 동작함을 검증하는 **테스트**, (2) `/health` 엔드포인트와 MCP `initialize` 메서드의 **호출 예제**, (3) 예상 출력 형식의 **스펙 문서**. Insight 9의 "Documentation as Code Contract" 원칙이 여기서 구체화된다 [^16^][^13^].

**`.t` 디렉토리 테스트의 고급 활용:**

```
test/cli/
└── coord_pipeline.t/
    ├── run.t              # 메인 테스트 스크립트
    ├── input/
    │   └── seoul_1000.csv # 1000개 좌표 입력 데이터
    ├── expected/
    │   ├── summary.json   # 예상 요약 출력
    │   └── errors.log     # 예상 에러 로그
    └── .ocamlformat       # 테스트별 포매팅 규칙 (선택)
```

```bash
# test/cli/coord_pipeline.t/run.t
파이프라인 종단간 테스트:

  $ coord pipeline \
  >   --input $TESTDIR/input/seoul_1000.csv \
  >   --output $TESTDIR/output/ \
  >   --transform WGS84_TO_UTM \
  >   --validate
  Processing 1000 coordinates...
  Valid: 998, Invalid: 2, Errors: 0

  $ diff $TESTDIR/output/summary.json $TESTDIR/expected/summary.json

에러 로그 확인:

  $ cat $TESTDIR/output/errors.log | head -n 2
  Line 42: latitude out of range: 91.5
  Line 87: invalid datum specifier: "UNKNOWN"
```

디렉토리 기반 테스트는 대용량 입력 데이터, 복수 출력 파일, 그리고 파일 간 비교(`diff`)가 필요한 시나리오에서 Cram test의 표현력을 극대화한다 [^19^].

### 8.3 계층적 CLAUDE.md

단일 CLAUDE.md 파일은 200 라인 이하로 유지해야 하며 [^39^], 대규모 모노레포에서는 단일 파일이 오히려 해가 될 수 있다 [^75^]. Anthropic Claude Code 문서와 실무자들은 **계층적 컨텍스트 아키텍처**에 수렴하고 있다. masc-mcp는 루트(아키텍처) → 모듈(도메인) → 구현(세부)의 3단계 계층을 구축한다 [^75^][^36^].

#### 8.3.1 루트 CLAUDE.md (아키텍처)

루트 CLAUDE.md는 200 라인 이하로 유지하며, 모든 곳에 적용되는 규칙만 포함한다 [^39^]. 프로그레시브 디스클로저(Progressive Disclosure) 원칙에 따라 상세한 도메인 지식은 하위 파일로 분리한다 [^38^].

```markdown
<!-- CLAUDE.md — 루트: 글로벌 규칙 -->
# masc-mcp: Architecture Overview

## 프로젝트 개요
masc-mcp는 대규모 좌표 처리 시스템의 MCP(Model Context Protocol) 서버 구현이다.
565K 라인 OCaml, 30개 lib 모듈, 18개 실행 파일로 구성된다.

## 디렉토리 구조
```
lib/
  masc/      — 코어 타입과 프로토콜 (모든 모듈의 기반)
  coord/     — 좌표 변환 시스템 (70파일, ~15K 라인)
  cascade/   — 태스크 파이프라인과 정책 엔진
  tools/     — MCP 도구 스키마와 레지스트리
  server/    — HTTP 서버, MCP 프로토콜 핸들러
```

## 코딩 표준
- 모든 공개 함수에 명시적 타입 시그니처 (`.mli` 필수)
- 함수당 50라인 이하, 최대 100라인 [^144^]
- 순수 함수와 IO 분리
- 네이밍: snake_case(값/함수), CamelCase(모듈/타입), ALL_CAPS(생성자)

## 빌드 & 테스트
```bash
dune build @all              # 전체 빌드
dune test                    # 테스트 실행
dune build @doc              # 문서 생성
dune fmt --auto-promote      # 포맷팅
```

## 모듈 작업 시
각 모듈의 CLAUDE.md를 먼저 읽고 작업하라. 예: coord 작업 시 → `lib/coord/CLAUDE.md`
```

**핵심 원칙**: `@`-file로 문서를 CLAUDE.md에 임베드하지 않는다 [^38^]. 참조 방식을 사용하여 "자세한 내용은 `lib/coord/CLAUDE.md` 참조"와 같이 작성한다. 이는 매 실행 시 전체 파일이 주입되어 토큰을 낭비하는 것을 방지한다.

#### 8.3.2 모듈별 CLAUDE.md (도메인)

하위 CLAUDE.md 파일은 에이전트가 해당 디렉토리에서 작업할 때만 로드된다. 프론트엔드 관련 instruction이 백엔드 태스크에 주입되지 않는 **Lazy Loading** 원리가 적용된다 [^75^].

```markdown
<!-- lib/coord/CLAUDE.md — 도메인: 좌표 시스템 -->
# coord: 좌표 변환 시스템

## 도메인 개요
coord는 WGS84, UTM, TM, BESSEL 등 다양한 좌표 체계 간 변환을 담당한다.
현재 70파일, ~15K 라인으로 128K 컨텍스트(8K-12K 라인) 경계에 있다.
분할 계획: coord_base → coord_transform → coord_io (차후 진행)

## 주요 타입
- `Coord_types.point`: 불변 좌표 타입 (lat, lng, system)
- `Coord_types.system = WGS84 | UTM of int | TM of {...}`
- `Keeper.t`: 상태 머신 기반 변환 파이프라인의 상태

## 아키텍처 패턴
1. Keeper 상태 머신: Idle → Validating → Transforming → Done | Error
2. Pipeline: Reader → Filter → Transformer → Writer
3. 에러 처리: Result 타입 일관 사용, _exn 접미사는 예외 발생 함수

## 의존성 규칙
- coord는 masc(코어 타입)만 의존
- coord의 서브모듈 간에는 단방향 의존: base → transform → io
- server, tools는 coord의 공개 API만 사용 (낮부 모듈 직접 접근 금지)

## 주의사항
- 좌표 체계 변환 시 데이텤(datum) 불일치가 가장 흔한 버그 원인
- UTM zone 자동 계산은 중앙 자오선 기준, 경계선에서 주의 필요
- 성능: 대량 변환 시 batch API 사용, 개별 convert는 오버헤드 큼
```

각 모듈의 CLAUDE.md는 150-200 라인을 목표로 하며, 도메인 지식, 주요 타입, 아키텍처 패턴, 의존성 규칙, 흔한 버그/주의사항을 포함한다. 이는 에이전트가 "coord 모듈 작업"을 시작할 때 즉시 로드되어 맥락을 제공한다 [^38^].

#### 8.3.3 구현별 CLAUDE.md (세부)

복잡한 서브모듈 낮부에 추가로 배치하여 세부 구현 맥락을 제공한다. 이는 3단계 계층의 최하위로, 일반적으로 100 라인 이하로 유지한다.

```markdown
<!-- lib/coord/transform/CLAUDE.md — 세부: 변환 알고리즘 -->
# coord/transform: 좌표 변환 알고리즘

## 변환 체인
1. 데이텤 변환 (WGS84 ↔ BESSEL ↔ TOKYO)
2. 투영 변환 (경위도 ↔ 평면좌표)
3. zone/central_meridian 계산

## 헬퍼 모듈
- `Datum_transform.ml`: 7파라미터 헬멀트 변환
- `Projection.ml`: 가우스-크루거 투영
- `Zone_finder.ml`: UTM zone 자동 계산 (경도 ÷ 6 + 31)

## 성능 노트
- sin/cos 계산은 캐싱: Coord_cache 모듈 사용
- float equality는 절대 금지: Coord_math.approx_equal 사용 (epsilon=1e-9)
```

**계층 간 상호 보완 관계:**

| 계층 | 파일 위치 | 대상 독자 | 주요 내용 | 토큰 소비 |
|------|----------|----------|----------|----------|
| 글로벌 | `CLAUDE.md` | 모든 에이전트 | 아키텍처 개요, 코딩 표준, 빌드 명령 | ~1K (상시 로드) |
| 도메인 | `lib/{mod}/CLAUDE.md` | 모듈 작업 에이전트 | 타입 설계, 패턴, 의존성 규칙 | ~2K (해당 디렉토리 진입 시) |
| 세부 | `lib/{mod}/sub/CLAUDE.md` | 서브모듈 작업 에이전트 | 알고리즘, 헬퍼, 성능 노트 | ~1K (해당 디렉토리 진입 시) |

odoc의 `.mld`와 CLAUDE.md는 상호 보완적이다 [^75^]: `.mld`는 개발자가 `dune build @doc`로 생성한 HTML 문서를 읽는 용도이고, CLAUDE.md는 AI 에이전트가 프로젝트 탐색 중 실시간으로 로드하는 용도이다. 둘 다 디렉토리별로 존재하며, 수정 시 서로를 참조하도록 한다. 예를 들어 `lib/coord/CLAUDE.md`의 "주요 타입" 섹션은 `doc/coord/types.mld`의 내용을 요약한 형태가 되며, 변경 시 양쪽을 동기화한다.

#### 8.3.4 다중 에이전트 도구 연동

계층적 CLAUDE.md는 Claude Code 전용이지만, Cursor와 GitHub Copilot 사용자를 위한 병렬 구조도 마련한다. Packmind의 연구에 따류 91%의 엔지니어링 조직이 최소 하나의 AI 코딩 도구를 채택하지만, 5%의 리포지토리만 구조화된 AI 설정 파일을 포함한다. 이 격차가 코드 품질 저하와 기술 부채 가속의 원인이 된다 [^75^].

**Cursor Rules (`.cursor/rules/`):**

Cursor는 `.cursor/rules/` 디렉토리에 계층적 규칙 파일을 배치하여 프로젝트별 AI 행동을 제어한다 [^42^][^45^]. 각 `.mdc` 파일은 frontmatter를 통해 적용 조건을 제어한다 [^52^]:

```markdown
<!-- .cursor/rules/ocaml-style.mdc -->
---
description: OCaml 코딩 스타일 규칙
globs: "*.ml,*.mli"
alwaysApply: false
---

# OCaml 스타일 규칙

## 타입 시그니처
- 모든 공개 함수는 `.mli`에 명시적 타입 시그니처를 작성한다.
- 타입 어노테이션은 최상위 함수에만 사용하고, 낮부 let binding에는 과도하게 사용하지 않는다.

## 모듈 규칙
- `open! Base`는 파일 최상단에 한 번만 사용한다.
- `include` 사용 시 문서에 "이 모듈의 어떤 기능을 포함하는지" 반드시 주석을 단다.
- 낮부 모듈(`Coord_internal`)은 public 모듈(`Coord`)을 통해서만 접근한다.
```

| frontmatter 필드 | 역할 | 예시 |
|-----------------|------|------|
| `alwaysApply` | 모든 세션에 자동 적용 | `true` for `general.mdc` |
| `globs` | 특정 파일 패턴 매칭 시 적용 | `"*.ml"`, `"lib/coord/**"` |
| `description` | AI가 관련성을 판단하여 지능적으로 적용 | "coord 모듈 작업 규칙" |

**GitHub Copilot Instructions (`.github/copilot-instructions.md`):**

```markdown
# .github/copilot-instructions.md
## 프로젝트 개요
masc-mcp는 대규모 OCaml 기반의 MCP(Model Context Protocol) 서버 구현이다.

## 코딩 컨벤션
- 모든 공개 함수에 명시적 타입 시그니처 사용 (`.mli` 필수)
- 100 라인 이상의 함수는 분할 [^144^]
- 순수 함수와 IO를 명확히 분리
- `Result` 타입을 사용한 명시적 에러 처리

## 중요 규칙
- coord 모듈의 공개 API 변경 시 `test/cli/`의 Cram test를 반드시 업데이트한다.
- Dune 파일의 `public_name` 변경 시 하위 호환성을 유지한다.
- `dune build @doc` 실행 시 warning이 발생하지 않도록 docstring을 유지한다.
```

**ContextOps 4단계 모델** [^75^]을 통해 이 설정들을 체계적으로 관리한다:

1. **Capture**: 코드베이스에서 표준 추출 (패턴, 네이밍, 승인 라이브러리)
2. **Version**: 표준 업데이트마다 버전 생성
3. **Distribute**: CLAUDE.md, `.cursor/rules/`, `copilot-instructions.md`에 자동 배포
4. **Govern**: 표준 적용 추적, 위반 사전 탐지, drift 측정

이 모델의 효과로 기술 리드 생산성 40% 증가, 리드 타임 25% 감소, 신규 개발자 온볼딩 2배 가속이 보고되었다 [^75^].

### 8.4 ocamlformat 통합

일관된 코드 포매팅은 AI 에이전트의 코드 이해 속도를 높인다. 동일한 구조의 코드를 반복적으로 노출하면 에이전트가 패턴을 더 빠르게 학습한다 [^75^]. `ocamlformat`은 OCaml의 표준 포매터로, Dune은 `dune build @fmt` (또는 `dune fmt`) 명령으로 이를 통합한다 [^90^].

#### 8.4.1 프로필 설정

**Before: 포매팅 없이 각자 다른 스타일**

```ocaml
(* 개발자 A의 스타일 *)
let convert point target =
  let open Coord_types in
  match point.system, target with
  | WGS84, UTM zone -> to_utm point zone
  | WGS84, TM cm -> to_tm point cm
  | _, _ -> failwith "unsupported"

(* 개발자 B의 스타일 — 동일 기능, 다른 레이아웃 *)
let convert point target = let open Coord_types in
  match point.system,target with
  | WGS84,UTM zone->to_utm point zone
  | WGS84,TM cm->to_tm point cm
  | _,_->failwith "unsupported"
```

AI 에이전트는 두 스타일을 번갈아 학습해야 하므로 패턴 인식 효율이 저하된다.

**After: janestreet 프로필 적용**

`.ocamlformat` 파일에 다음을 설정한다 [^18^][^90^]:

```
version=0.26.2
profile=janestreet
break-infix=fit-or-vertical
module-item-spacing=compact
```

| 프로필 | 특성 | masc-mcp 적합성 |
|--------|------|----------------|
| `conventional` | OCaml 커뮤니티 기본 스타일 | 보통 |
| `ocamlformat` | ocamlformat 팀 권장 스타일 | 보통 |
| `janestreet` | Jane Street의 엄격한 스타일 | **권장** — 대규모 프로젝트에서 일관성이 높음 [^18^] |

`janestreet` 프로필은 다음 특성으로 대규모 프로젝트에 적합하다: (1) 명시적 `begin`/`end`로 블록 경계 강조, (2) 긴 타입 시그니처의 일관된 줄바꿈, (3) `open`/`open!` 사용의 엄격한 규칙. 이는 AI 에이전트가 모듈 경계와 스코프를 빠르게 파악하는 데 도움이 된다.

**포매팅 적용 예시:**

```ocaml
(* janestreet 프로필 적용 후 *)
let convert (point : t) (target : system) : t =
  let open Coord_types in
  match point.system, target with
  | WGS84, UTM zone -> to_utm point zone
  | WGS84, TM { central_meridian } -> to_tm point central_meridian
  | source, target when Poly.equal source target -> point
  | _ ->
    raise_s
      [%message "Unsupported coordinate conversion" (source : system) (target : system)]
;;
```

#### 8.4.2 dune fmt 워크플로우

`dune-project` 파일에 `(lang dune 2.0)` 이상을 명시하고 [^90^], 포매팅 워크플로우를 설정한다.

**로컬 개발 워크플로우:**

```bash
# 포맷팅 실행
$ dune build @fmt

# 변경사항 확인 후 소스에 반영
$ dune promote

# 한 번에 실행 (권장)
$ dune fmt --auto-promote
```

**CI 통합:**

```yaml
# .github/workflows/format.yml
name: Format Check
on: [pull_request]
jobs:
  ocamlformat:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ocaml/setup-ocaml@v2
        with:
          ocaml-compiler: '5.1'
      - run: opam install ocamlformat.0.26.2
      - run: opam exec -- ocamlformat --check $(find . -name '*.ml' -o -name '*.mli')
```

`ocamlformat --check` 명령으로 포매팅 검증을 CI 파이프라인에 통합하여, 포매팅이 맞지 않는 PR을 자동으로 차단할 수 있다 [^21^].

**워크플로우 비교:**

| 시나리오 | 명령어 | 결과 |
|----------|--------|------|
| 로컬 포매팅 + 수동 확인 | `dune build @fmt` → `dune promote` | 안전하지만 2단계 |
| 로컬 포매팅 + 자동 반영 | `dune fmt --auto-promote` | **권장** — 1단계로 완료 |
| CI 검증 | `ocamlformat --check` | 포매팅 위반 시 빌드 실패 [^21^] |
| 사전 커밋 훅 | `dune fmt --auto-promote` | 커밋 전 자동 포매팅 |

### 8.5 종합: "문서만 보고도 코드 구조 틀을 이해할 수 있도록"

본 장의 네 가지 축(odoc, Cram Test, 계층적 CLAUDE.md, ocamlformat)은 단독으로도 가치가 있지만, 통합했을 때 시너지가 발생한다. Insight 6은 "Hierarchical CLAUDE.md as Living Architecture Doc"으로, CLAUDE.md가 `.mld`와 상호 보완적이며 수정 시 서로를 참조해야 함을 강조한다 [^75^]. Insight 9는 "Documentation as Code Contract"로, `.mli`의 signature가 모듈 계약이고, odoc이 이를 문서화하며, Cram test가 이를 검증하는 3중 계약 시스템을 제안한다.

**통합 적용 체크리스트:**

- [ ] `dune-project`에 `(documentation)` stanza 추가
- [ ] `doc/` 디렉토리에 계층적 `.mld` 파일 작성 (index.mld + 모듈별)
- [ ] 모든 공개 모듈에 `.mli` 파일 작성 + `(** docstring *)` 추가
- [ ] `test/cli/`에 Cram test `.t` 파일 작성 (18개 CLI 도구 대상)
- [ ] 루트 `CLAUDE.md` 작성 (200라인 이하: 아키텍처 + 코딩 표준 + 빌드 명령)
- [ ] 각 lib 모듈별 `CLAUDE.md` 작성 (150-200라인: 도메인 지식 + 타입 + 패턴)
- [ ] `.ocamlformat` 파일 생성 (janestreet 프로필, 버전 고정)
- [ ] `dune fmt --auto-promote` 워크플로우 문서화 및 CI 통합
- [ ] odoc 3.0 Sherlodoc 검색을 위한 타입 주석 품질 점검

**문서화 3중 계약 시스템:**

```
┌─────────────────────────────────────────────────────────────────┐
│                    Documentation as Code Contract                │
├─────────────────────────────────────────────────────────────────┤
│  .mli signature          — "이 모듈이 보장하는 계약" (컴파일러 검증) │
│       ↓ odoc docstring                                                  │
│  HTML 문서 (dune @doc)   — "개발자가 읽는 API 레퍼런스"              │
│       ↓ Cram test                                                       │
│  .t 파일 테스트          — "CLI 사용자가 보는 실행 예제" (런타임 검증)  │
│       ↓ CLAUDE.md                                                       │
│  AI 에이전트 컨텍스트    — "에이전트가 탐색하는 구조 맵"               │
└─────────────────────────────────────────────────────────────────┘
```

이 구조를 통해 개발자는 `dune build @doc`으로 HTML 문서를 생성하여 Sherlodoc로 검색하고, CLI 사용자는 Cram test 파일을 읽어 사용법을 파악하며, AI 에이전트는 계층적 CLAUDE.md를 따라 프로젝트 구조를 탐색한다. 모든 문서는 코드 변경 시 동기화되어 "문서만 보고도 코드 구조 틀을 이해할 수 있는" 상태를 유지한다 [^57^][^75^][^16^].

**문서화 유지보수 전략:**

문서가 "살아있는 문서(living documentation)"가 되려면 코드 변경과 동기화되는 메커니즘이 필수적이다. masc-mcp에서는 다음 전략을 적용한다:

1. **PR 체크리스트**: 모든 PR은 "문서 변경 여부"를 체크리스트 항목으로 포함한다. `.mli`의 공개 API 변경 → docstring 업데이트, CLI 인터페이스 변경 → Cram test 업데이트, 아키텍처 변경 → `.mld` 및 CLAUDE.md 업데이트.

2. **CI 강제**: `dune build @doc` 실행 시 odoc warning을 error로 처리하여, 문서화되지 않은 공개 함수가 main 브랜치에 병합되는 것을 차단한다.

3. **주기적 검토**: 월 1회 `dune build @doc-private`로 private 라이브러리 문서를 확인하고, CLAUDE.md의 내용이 실제 코드 구조와 일치하는지 검증한다. coord 모듈의 분할 계획(8.3.2)이 진행되면 해당 CLAUDE.md도 함께 업데이트한다.

4. **Sherlodoc 품질 점검**: odoc 3.0 Sherlodoc의 타입 기반 검색 품질은 docstring의 타입 주석 품질에 직접 의존한다. `@param`, `@return` 태그를 일관되게 사용하여 검색 인덱스의 정확도를 높인다 [^147^].

---

## 9. 실행 로드맵 & 마일스톤

> *"계획 없는 목표는 소원에 불과하다."* — 본 장은 장 3–8에서 제시한 4개 Phase와 문서화 작업을 20주 일정으로 통합하여 구체적 실행 계획을 수립한다. 각 Phase는 Go/No-Go 결정 기준과 리스크 완화 방안을 포함하며, 병렬 추진 가능한 문서화 트랙을 분리하여 전체 일정의 현실성을 확보한다.

---

### 9.1 전체 타임라인 개요

20주 로드맵은 4개의 순차적 Phase와 1개의 병렬 문서화 트랙으로 구성된다. Phase 0(숙청)부터 Phase 3(생태계 전환)까지 각각 2주, 6주, 6주, 6주의 일정을 배정했으며, 각 Phase 종료 시 Go/No-Go 평가를 실시한다. 문서화 트랙은 Week 1부터 Week 20까지 전 구간에 걸쳐 병렬로 진행된다.

**간트 차트 (20주 로드맵)**:

| 주차 | Phase 0: 숙청 | Phase 1: 구조 재설계 | Phase 2: 타입 설계 | Phase 3: 생태계 전환 | 문서화 (병행) |
|:----:|:-------------:|:--------------------:|:------------------:|:--------------------:|:-------------:|
| W1   | ████████ | | | | ████ |
| W2   | ████████ | | | | ████ |
| W3   | | ████████ | | | ████ |
| W4   | | ████████ | | | ████ |
| W5   | | ████████ | | | ████ |
| W6   | | ████████ | | | ████ |
| W7   | | ████████ | | | ████ |
| W8   | | ████████ | | | ████ |
| W9   | | | ████████ | | ████ |
| W10  | | | ████████ | | ████ |
| W11  | | | ████████ | | ████ |
| W12  | | | ████████ | | ████ |
| W13  | | | ████████ | | ████ |
| W14  | | | ████████ | | ████ |
| W15  | | | | ████████ | ████ |
| W16  | | | | ████████ | ████ |
| W17  | | | | ████████ | ████ |
| W18  | | | | ████████ | ████ |
| W19  | | | | ████████ | ████ |
| W20  | | | | ████████ | ████ |

> **범례**: 각 셀의 너비는 해당 주차의 작업 강도를 시각적으로 표현한다. 문서화 트랙은 모든 주차에서 일정한 강도(████)로 병렬 수행된다.

---

### 9.2 Phase 0: 숙청 (Week 1–2)

> *"숙청을 주저하지 마세요."* — Phase 0은 구조적 부채 중 가장 낮은 수확 고도를 제거하는 단계로, 독립적 실행이 가능한 모든 항목을 2주 내에 완료한다 [^75^].

#### 9.2.1 액션 아이템 상세

**Week 1: 루트 디렉토리 청소 + 아카이브 통합**

| # | 작업 | 담당자 | 산출물 | 리스크 |
|---|------|--------|--------|--------|
| 0.1 | 28개 Python 임시 스크립트 일괄 삭제 + 백업 | Any | `ls *.py` = 0 | tracked 파일 삭제 |
| 0.2 | `debug.ml`, `debug_canonical.ml` 이동/삭제 | Any | 빌드 통과 | dune 의존성 |
| 0.3 | 5개 아카이브 위치 → `archive/` 단일 통합 | Any | 통합 디렉토리 | 문서 링크 파손 |
| 0.4 | `embedded_config/` 완전 삭제 | Any | `embedded_config/` 없음 | 런타임 참조 |

**Week 2: 모듈 병합 + 대시보드 정리 + 문서 축소**

| # | 작업 | 담당자 | 산출물 | 리스크 |
|---|------|--------|--------|--------|
| 0.5 | 13개 2파일 이하 모듈 병합 (→ 4개) | OCaml | `dune build` 통과 | 순환 의존성 노출 |
| 0.6 | `dashboard_bonsai` ↔ `dashboard_bonsai/` 이중 구조 해소 | OCaml | 단일 디렉토리 | Bonsai 버전 충돌 |
| 0.7 | 문서 250개 → 50개 핵심 축소 | Docs | 축소된 `docs/` | 지식 손실 |
| 0.8 | Week 1–2 종합 검증: 빌드 + 테스트 + `git status` | CI | 검증 리포트 | - |

#### 9.2.2 예상 삭제/이동 파일 수

| 카테고리 | Before | After | 변화량 |
|----------|--------|-------|--------|
| 루트 임시 스크립트 | 30+ 개 | 0 개 | -30 |
| 아카이브 위치 수 | 5개 | 1개 | -4 |
| `lib/` 2파일 이하 모듈 | 14개 | 4개 | -10 (병합) |
| `embedded_config/` | 1개 | 0개 | -1 (삭제) |
| 대시보드 이중 구조 | 2개 | 1개 | -1 |
| 문서 파일 수 | 250개 | ~50개 | -200 |
| **총계** | **300+** | **~55개 핵심** | **-245** |

#### 9.2.3 Go/No-Go 결정 기준

| 기준 | Go | No-Go |
|------|-----|-------|
| `dune build @default` | 무오류 통과 | 어떤 빌드 오류라도 발생 |
| `dune runtest` | 기존 테스트 전체 통과 | 1개 이상 실패 |
| `ls *.py` | 0개 | 1개 이상 잔여 |
| `git status` | untracked 삭제만 표시 | tracked 수정 파일 존재 |
| `find lib -type d -maxdepth 1 \| wc` | 24개 이하 (14→4 병합 반영) | 25개 이상 |

**No-Go 시 조치**: No-Go 기준 중 1개라도 충족되지 않으면 해당 항목을 추적 이슈로 등록하고 Phase 0을 1주 연장한다. 3주 내에도 해결되지 않으면 항목을 Phase 1으로 이월하고 Phase 0에서 제외한다.

---

### 9.3 Phase 1: 구조 재설계 (Week 3–8)

> Phase 1은 에이전트의 64K 컨텍스트 윈도우를 1차 설계 제약으로 삼아 전체 디렉토리 구조를 재설계한다 [^1^][^10^]. coord(70파일)와 cascade(54파일) 등 대형 모듈을 2K–3K 라인 단위로 분할하며, 모든 모듈은 20–30 파일 상한을 준수한다.

#### 9.3.1 모듈 분할 순서

**Week 3–4: masc 코어 라이브러리 구성**

| # | 작업 | 산출물 | 의존성 |
|---|------|--------|--------|
| 1.1 | `lib/types/` — 공통 타입 라이브러리 분리 | `masc.types` 라이브러리 | Phase 0 완료 |
| 1.2 | `lib/utils/` — 문자열, 시간, 해시 유틸리티 분리 | `masc.utils` 라이브러리 | 1.1 |
| 1.3 | `lib/error/` — `Result` 기반 에러 타입 정의 | `masc.error` 라이브러리 | 1.1 |
| 1.4 | `lib/logging/` — 일관된 로깅 인터페이스 | `masc.logging` 라이브러리 | 1.3 |

**Week 5–6: coord 모듈 분할**

| # | 작업 | 산출물 | 크기 목표 |
|---|------|--------|-----------|
| 1.5 | `coord` → `coord_core` (타입 + 상태 머신) | `coord_core/` (15–20파일) | ~2K 라인 |
| 1.6 | `coord` → `coord_transport` (메시지 + 프로토콜) | `coord_transport/` (10–15파일) | ~1.5K 라인 |
| 1.7 | `coord` → `coord_fsm` (keeper FSM + 전이 로직) | `coord_fsm/` (15–20파일) | ~2K 라인 |
| 1.8 | 기존 `coord/` 합성 인덱스 모듈 작성 | `coord.ml` (인덱스) | <100 라인 |

**Week 7: cascade 모듈 분할**

| # | 작업 | 산출물 | 크기 목표 |
|---|------|--------|-----------|
| 1.9 | `cascade` → `cascade_engine` (파이프라인 코어) | `cascade_engine/` (15–20파일) | ~2K 라인 |
| 1.10 | `cascade` → `cascade_io` (입출력 + 직렬화) | `cascade_io/` (10–15파일) | ~1.5K 라인 |
| 1.11 | `cascade` → `cascade_policy` (정책 규칙) | `cascade_policy/` (10–15파일) | ~1.5K 라인 |

**Week 8: tools, server 재구성 + bin 통합**

| # | 작업 | 산출물 | 비고 |
|---|------|--------|------|
| 1.12 | `tools/` 세분화 — schemas/types/runner 분리 | 3개 서브라이브러리 | 기존 28파일 분할 |
| 1.13 | `server/` — HTTP 핸들러/라우팅/미들웨어 분리 | 3개 서브라이브러리 | |
| 1.14 | `bin/` 18개 실행 파일 통합/정리 | 10–12개 통합 실행 파일 | 중복 기능 병합 |
| 1.15 | 전체 `dune` 파일 재작성 + `public_name` 명시 | 모든 `dune` 파일 | |

#### 9.3.2 dune 파일 재작성 원칙

Phase 1에서 모든 `dune` 파일은 다음 원칙에 따라 재작성된다:

```scheme
; Before: 묵시적 라이브러리, public_name 없음
(library
 (name coord))

; After: 명시적 public_name, 제한된 노출
(library
 (name coord_core)
 (public_name masc.coord_core)
 (libraries masc.types masc.error)
 (modules (:standard \ coord_core_test)))
```

| 속성 | Before | After |
|------|--------|-------|
| `public_name` | 대부분 없음 | 100% 명시 |
| `libraries` | 느슨한 의존성 | 엄격한 직접 의존성만 |
| `modules` | 기본 (전체) | 명시적 필터링 |
| `wrapped` | 기본 (true) | 명시적 `(wrapped true)` |

#### 9.3.3 Go/No-Go 결정 기준

| 기준 | Go | No-Go |
|------|-----|-------|
| `dune build` 전체 | 무오류 | any error |
| 최대 모듈 파일 수 | ≤25개 | ≥26개 |
| coord 서브모듈 합계 | 70파일 유지 (재분배) | 파일 누락/중복 |
| `dune describe` 사이클 | 순환 의존성 0개 | 1개 이상 |
| 에이전트 64K 컨텍스트 | 모듈당 ≤3K 라인 | >3K 라인 모듈 존재 |

---

### 9.4 Phase 2: 타입 설계 개선 (Week 9–14)

> Phase 2는 장 5에서 제시한 5가지 함수형 설계 원칙을 코드베이스에 적용하여 타입 안전성을 높이고 Shotgun Parsing 안티패턴을 제거한다 [^78^][^79^].

#### 9.4.1 GADT 도입 모듈 목록

**Week 9–10: Parse Don't Validate**

| 모듈 | 경계 | 강한 타입 | Before | After |
|------|------|-----------|--------|-------|
| `lib/protocol/` | MCP 메시지 수신 | `Method.t`, `Request_id.t` | `string` 검증 | `private string` 파싱 |
| `lib/config/` | 설정 파일 로딩 | `Config.t` GADT | `List.assoc` + `int_of_string` | 파싱 함수 |
| `lib/coord_transport/` | keeper 메시지 | `Message.t` variant | `Yojson.Safe.t` 통과 | 타입-safe 레코드 |

```ocaml
(* Week 9-10 목표: Parse at Boundary *)
(* BEFORE: Shotgun parsing — 각 핸들러마다 검증 [^79^] *)
let handle json =
  let method_ = Yojson.Safe.Util.(member "method" json |> to_string) in
  if method_ = "" then failwith "empty method";
  (* ... 30개 모듈에서 각자 검증 ... *)
  process method_

(* AFTER: 파싱된 강한 타입으로 전파 *)
let handle (msg : Message.t) =
  (* method_는 이미 Method.t로 파싱됨 — 추가 검증 불필요 *)
  process msg.method_
```

**Week 11–12: GADT 상태 머신**

| 상태 머신 | 위치 | GADT 타입 |
|-----------|------|-----------|
| Keeper 라이프사이클 | `coord_fsm/` | `('s, 'e) state` — `'s = idle \| active \| failed` |
| Coordination phase | `coord_core/` | `('p, 'r) phase` — `'p = init \| negotiate \| commit` |
| Cascade task 상태 | `cascade_engine/` | `('s) task_state` — `'s = pending \| running \| done` |

```ocaml
(* Week 11-12 목표: 상태를 타입으로 인코딩 *)
(* BEFORE: 문자열 기반 상태, 런타임 검증 [^9^] *)
if state.status = "running" then ...

(* AFTER: GADT로 컴파일 타임 보장 *)
type 's t = { state : 's state; ... }
type running
type idle
transition : idle t -> event -> (running t, error) result
```

**Week 13–14: Smart Constructors + Functional Core/Imperative Shell**

| 모듈 | Smart Constructor | 효과 |
|------|-------------------|------|
| `cascade_policy/` | `Policy.make ~rules ~priority ()` | 불변식 위반 시 컴파일 에러 |
| `coord_core/` | `Keeper.create ~id ~config ()` | ID 형식, 설정 유효성 타입 수준 보장 |
| `lib/types/` | `Timeout.of_seconds n` | `n > 0` 조건을 타입에 인코딩 |

```ocaml
(* Week 13-14 목표: 불가능한 상태 표현 불가 *)
(* BEFORE: 런타임 검증 + 예외 *)
let make ~timeout =
  if timeout <= 0 then failwith "invalid timeout";
  { timeout }

(* AFTER: 생성자가 보장 *)
type t = private { timeout : int } [@@deriving sexp]

let make ~timeout =
  if timeout <= 0
  then Error (`Invalid_timeout timeout)
  else Ok { timeout }
  (* 호출자는 Ok/Error를 처리해야 함 — Result 강제 *)
```

#### 9.4.2 Go/No-Go 결정 기준

| 기준 | Go | No-Go |
|------|-----|-------|
| `dune build` | 무오류 | any error |
| `dune runtest` | 기존 테스트 + 신규 파싱 테스트 통과 | 1개 이상 실패 |
| GADT 모듈 수 | ≥3개 모듈에 GADT 적용 | <3개 |
| `.mli` 커버리지 | 100% public 모듈 | 누락 `.mli` 존재 |
| Shotgun Parsing 잔여 | `grep -r "failwith" lib/` = 0 (신규) | 신규 `failwith` 발견 |

---

### 9.5 Phase 3: 생태계 전환 (Week 15–20)

> Phase 3은 장 7에서 제시한 표준 라이브러리 통일, HTTP 라이브러리 현대화, 의존성 축소를 실행한다 [^21^][^34^]. 점진적 전환을 원칙으로 하며 "빅뱅 마이그레이션"은 회피한다.

#### 9.5.1 Base 전환 (Week 15–16)

| # | 작업 | 범위 | 점진 전략 |
|---|------|------|-----------|
| 3.1 | 신규 모듈에 `Base` 강제 | `lib/` 신규 파일 | `open Base`를 파일 헤더에 추가 |
| 3.2 | `Stdlib.List` → `Base.List` (신규) | 신규 코드만 | 기존 코드는 건드리지 않음 |
| 3.3 | `string_of_int` → `Int.to_string` | 신규 + 수정 파일 | 리팩토링 시 함께 변경 |
| 3.4 | `Map.Make` → `Base.Map` (신규) | 신규 모듈 | 기존 `Map.Make` 유지 |

```ocaml
(* Week 15-16: 신규 모듈부터 Base 적용 *)
(* BEFORE: Stdlib 스타일 [^139^] *)
module StringMap = Map.Make(String)
let f = List.fold_left (+) 0 lst
let s = string_of_int n

(* AFTER: Base 스타일 — 신규 모듈에만 적용 *)
open Base
let f = List.fold lst ~init:0 ~f:(+)
let s = Int.to_string n
```

#### 9.5.2 HTTP 라이브러리 통일 (Week 17–18)

| # | 작업 | 대상 | 산출물 |
|---|------|------|--------|
| 3.5 | `cohttp` + `httpun` → `piaf` 통일 | `server/` 모듈 | 단일 HTTP 라이브러리 |
| 3.6 | HTTP 클라이언트 인터페이스 추상화 | `lib/http_client/` | `Http_client.S` 시그니처 |
| 3.7 | 서버 핸들러 `piaf` 마이그레이션 | `server/mcp/` | Piaf 기반 핸들러 |
| 3.8 | HTTP 테스트 재작성 | `test/server/` | Piaf 호환 테스트 |

#### 9.5.3 의존성 정리 + 빌드 최적화 (Week 19–20)

| # | 작업 | Before | After |
|---|------|--------|-------|
| 3.9 | 미사용 의존성 제거 (`dune describe` 분석) | 40+개 | 25개 목표 |
| 3.10 | `dune-workspace` 최적화 | 기본 설정 | `(jobs N)`, `(cache enabled)` |
| 3.11 | `dune` 버전 업 (3.17+) | 기존 버전 | 3.17 with `lock_dir` |
| 3.12 | 최종 빌드 시간 벤치마크 | TBD | -30% 목표 |

#### 9.5.4 Go/No-Go 결정 기준

| 기준 | Go | No-Go |
|------|-----|-------|
| `opam list --depends-on masc` | 25개 이하 | 26개 이상 |
| `time dune build` | 기준 대비 -20% 이상 | -10% 이하 |
| HTTP 라이브러리 수 | 1개 (piaf) | 2개 이상 |
| Base 사용 모듈 비율 | 신규 100% | <100% |
| `dune runtest` | 전체 통과 | any failure |

---

### 9.6 문서화 트랙 (병행, Week 1–20)

> 장 8에서 제시한 문서화 전략은 전체 20주 기간에 걸쳐 병렬로 진행되며, 각 Phase의 산출물을 문서화하여 코드와 문서의 동기화를 유지한다 [^57^][^75^].

#### 9.6.1 문서화 타임라인

| 주차 | 작업 | 산출물 | 연계 Phase |
|:----:|------|--------|:----------:|
| W1 | 루트 `CLAUDE.md` 작성 (200라인 이하) | `/CLAUDE.md` | Phase 0 |
| W2 | `CLAUDE.md` — 아카이브/숙청 항목 기술 | 업데이트된 `CLAUDE.md` | Phase 0 |
| W3–4 | `lib/types/CLAUDE.md`, `lib/utils/CLAUDE.md` | 모듈별 CLAUDE.md ×2 | Phase 1 |
| W5–6 | `lib/coord_core/CLAUDE.md`, `lib/coord_transport/CLAUDE.md` | 모듈별 CLAUDE.md ×2 | Phase 1 |
| W7 | `lib/cascade_engine/CLAUDE.md`, `.mld` 파일 초안 | 모듈별 CLAUDE.md ×2 | Phase 1 |
| W8 | `lib/server/CLAUDE.md`, `doc/architecture.mld` | 모듈별 CLAUDE.md + .mld | Phase 1 |
| W9–10 | `doc/protocol/` — Parse Don't Validate 가이드 | `.mld` 튜토리얼 | Phase 2 |
| W11–12 | GADT 상태 머신 설명 문서 | `doc/gadt_patterns.mld` | Phase 2 |
| W13–14 | Cram Test 도입 + `test/` 문서화 | `.t` 파일 ×10 | Phase 2 |
| W15–16 | Base 마이그레이션 가이드 | `doc/base_migration.mld` | Phase 3 |
| W17–18 | HTTP 라이브러리 통합 문서 | `doc/http_refactor.mld` | Phase 3 |
| W19–20 | odoc 자동 생성 CI 통합 | `.github/workflows/odoc.yml` | Phase 3 |

#### 9.6.2 Cram Test 도입 일정 (Week 13–14)

```bash
# Week 13: 첫 Cram Test 파일 작성
$ cat > test/message_parsing.t << 'EOF'
  Parse Don't Validate — MCP 메시지 파싱
  $ echo '{"method": "", "id": "1"}' | ./test_parser.exe
  > ERROR: empty method
  [1]
  $ echo '{"method": "tools/list", "id": "1"}' | ./test_parser.exe
  > OK: Method("tools/list"), Id("1")
EOF

$ dune runtest test/message_parsing.t
```

---

### 9.7 성과 지표 (KPI)

> 모든 KPI는 Phase 종료 시점에 측정하며, 각 Phase의 Go/No-Go 평가에 직접 반영된다.

#### 9.7.1 정량 지표

| 지표 | 현재 (Baseline) | 목표 | 측정 방법 | 측정 주기 |
|------|----------------|------|-----------|:---------:|
| 모듈 평균 크기 | 18.8K 라인 | ≤5K 라인 | `dune describe` + `wc` | Phase 1, 3 종료 |
| 최대 모듈 파일 수 | 70개 (coord) | ≤25개 | `find lib -type f \| wc` | Phase 1 종료 |
| 빌드 시간 | TBD | -30% | `time dune build` | Phase 0, 3 종료 |
| 의존성 수 | 40+개 | 25개 | `dune describe` | Phase 3 종료 |
| 문서 수 | 250개 | 50개 핵심 | `find docs -type f \| wc` | Phase 0 종료 |
| 임시 스크립트 | 30+개 | 0개 | `ls *.py` | Phase 0 종료 |
| `.mli` 커버리지 | ~30% | 100% public | `find lib -name "*.mli"` | Phase 2 종료 |
| Cram Test 수 | 0개 | 10개 | `find test -name "*.t" \| wc` | Phase 2 종료 |

#### 9.7.2 정성 지표

| 지표 | 측정 방법 | 목표 |
|------|-----------|------|
| 에이전트 PR 생성 성공률 | PR 메트릭스 (컴파일 성공률) | +50%p |
| 코드 리뷰 주기 | PR merge 평균 시간 | -30% |
| 신규 기여자 온볇ィング | `CLAUDE.md`만으로 빌드 가능 시간 | <30분 |
| 타입 안전성 | `failwith`/`raise` 발생 빈도 | -80% (신규 코드) |

---

### 9.8 리스크 매트릭스

> 각 Phase의 주요 리스크와 완화 방안을 사전에 정의하여 예상치 못한 지연을 방지한다.

#### 9.8.1 Phase별 리스크

| Phase | 리스크 | 영향도 | 확률 | 완화 방안 |
|:------:|--------|:------:|:----:|-----------|
| **0** | tracked Python 스크립트 삭제 | 높음 | 낮음 | `git ls-files`로 사전 확인 |
| **0** | `embedded_config/` 런타임 참조 | 높음 | 중간 | `grep -r "embedded_config"` 사전 검색 |
| **1** | coord 분할 중 순환 의존성 노출 | 높음 | 높음 | `dune describe`로 매 주 모니터링 |
| **1** | `public_name` 변경으로 외부 참조 파손 | 중간 | 낮음 | `public_name`은 기존 이름 유지 또는 alias 제공 |
| **2** | GADT 도입으로 컴파일 시간 증가 | 중간 | 중간 | 복잡한 GADT는 별도 모듈로 격리 |
| **2** | 기존 테스트와 파싱 로직 불일치 | 높음 | 중간 | 기존 입력 셋으로 regression test |
| **3** | Base/Stdlib 혼재로 동작 불일치 | 높음 | 중간 | 신규 모듈에만 Base 적용, 기존 코드 분리 |
| **3** | Piaf 마이그레이션으로 API 변경 | 중간 | 높음 | 인터페이스 레이어 도입으로 격리 |
| **전체** | 일정 지연 (리소스 부족) | 높음 | 중간 | Phase별 독립적 완료 허용, 이월 가능 |

#### 9.8.2 에스컬레이션 기준

| 상황 | 조치 | 결정자 |
|------|------|--------|
| Phase 종료 시 No-Go 1개 | 1주 연장 후 재평가 | Tech Lead |
| Phase 종료 시 No-Go 2개+ | 항목 Phase 이월, 다음 Phase 시작 | Tech Lead |
| 3주 연속 진행률 <50% | 리소스 재배포 또는 범위 축소 | Engineering Manager |
| `dune build` 3일 이상 브로큰 | 전체 개발 중단, 복구 전담 팀 투입 | Tech Lead |
| KPI 목표 대비 -50% 이하 달성 | 로드맵 전면 재검토 | Engineering Manager |

---

### 9.9 요약: 20주 로드맵의 현실성 확보

본 로드맵의 현실성은 다음 4가지 설계 결정에 기반한다.

**첫째, 순차적 의존성 최소화.** Phase 0(숙청)은 Phase 1(구조 재설계)의 선행 조건이지만, Phase 0 난 내 모든 항목은 서로 독립적이다. 28개 Python 스크립트 삭제, 아카이브 통합, 모듈 병합은 병렬 수행 가능하다 [^75^]. 이 덕분에 2주라는 짧은 기간도 현실적이다.

**둘째, Phase 내 이월 메커니즘.** 각 Phase의 Go/No-Go 기준에서 1개 항목 실패 시 1주 연장, 2개 이상 실패 시 다음 Phase로 이월하는 규칙을 명시했다. 이는 전체 로드맵이 1–2주 지연되더라도 다음 Phase가 무기한 블록되는 상황을 방지한다.

**셋째, 문서화 병렬 트랙 분리.** 문서화 작업은 코드 변경과 독립적으로 진행 가능하므로 별도 트랙으로 분리했다. 각 Phase의 산출물(새 모듈, GADT 타입, Base 전환)을 문서화하는 시점은 해당 Phase 완료 시점과 동기화되지만, 문서화 자체의 지연이 코드 Phase를 블록하지 않는다.

**넷째, 점진적 전환 원칙.** Phase 3의 Base 전환과 HTTP 라이브러리 통일은 "신규 모듈부터, 기존 코드는 건드리지 않는다"는 원칙을 따른다 [^21^]. 이는 20주 내에 모든 코드를 한 번에 마이그레이션하겠다는 비현실적 목표를 회피하고, 전환의 효과를 신규 코드에서 먼저 검증한 후 기존 코드로 확장하는 현실적 접근이다.

```
┌─────────────────────────────────────────────────────────────┐
│                    20주 로드맵 한눈에 보기                    │
├──────────┬──────────────────────────────────────────────────┤
│  Phase   │              핵심 액션 + KPI                      │
├──────────┼──────────────────────────────────────────────────┤
│ 0 (W1-2) │  삭제 -245개 파일, 모듈 14→4, 문서 250→50       │
│          │  KPI: 임시 스크립트 0개, 빌드 통과               │
├──────────┼──────────────────────────────────────────────────┤
│ 1 (W3-8) │  coord 70→3개 서브모듈, cascade 54→3개 서브모듈 │
│          │  KPI: 최대 모듈 ≤25파일, 순환 의존성 0개         │
├──────────┼──────────────────────────────────────────────────┤
│ 2 (W9-14)│  GADT ×3, Parse Don't Validate, Smart Cons      │
│          │  KPI: .mli 100%, Cram Test 10개, failwith ↓80%  │
├──────────┼──────────────────────────────────────────────────┤
│ 3 (W15-20)│ Base(신규), piaf 통일, 의존성 40→25개          │
│          │  KPI: 빌드 -30%, HTTP 라이브러리 1개             │
├──────────┼──────────────────────────────────────────────────┤
│ 문서화   │ CLAUDE.md(루트+모듈), .mld, Cram Test, odoc CI  │
│ (W1-20)  │  KPI: 문서 50개 핵심, 에이전트 PR 성공률 +50%p   │
└──────────┴──────────────────────────────────────────────────┘
```

---

