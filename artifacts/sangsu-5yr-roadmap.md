# sangsu 5-year service design capability roadmap

## Goal

**5년 목표: 서비스를 처음부터 설계할 수 있는 사람**

"처음부터 설계한다"는 것은 아이디어 단계부터 production-ready 서비스까지 기술적 의사결정을 내릴 수 있는 능력을 의미한다. 이 goal은 영화 같은 독립 프로젝트든, kidsnote 같은 운영 서비스든, 아니면 새로운 사이드 프로젝트든 설계자로서 손을 댈 수 있는 역량을 기르는 것을 목표로 한다.

---

## What "design from scratch" means

1. **Problem discovery**: 사용자/운영자의 고통을 관찰하고, 해결해야 할 문제를 정의한다.
2. **Requirement shaping**: 기능/비기능 요구사항을 구체화한다. 성능, 보안, 비용, 운영 편의성, 확장성.
3. **System architecture**: 서비스 경계, 데이터 흐름, API 계약, 배포 단위를 설계한다.
4. **Data model**: 핵심 도메인 개념과 관계를 정의한다.
5. **API / interface design**: 외부/내부 API, 이벤트, CLI, UI/UX 시나리오.
6. **Implementation strategy**: 기술 스택, 라이브러리, 테스트 전략, 배포 파이프라인.
7. **Observability / operations**: 로그, 메트릭, 알림, SLO, 장애 대응 설계.
8. **Evolution planning**: 마이그레이션, 하위호환, 단계적 rollout.

---

## Skill/knowledge milestones

### Year 1 — Foundation
- **System design basics**: CAP theorem, 일관성 모델, 부하 분산, 캐싱, 데이터베이스 기초.
- **Observability**: 로그, 메트릭, 분산 추적의 개념과 실제 도구 사용.
- **CI/CD basics**: Git workflow, 자동화된 빌드/테스트/배포 파이프라인 이해.
- **Practice project**: 작은 개인 서비스 하나(예: 영화 제작 일정 관리 툴)를 설계/구현/배포.

### Year 2 — Intermediate
- **Domain modeling**: DDD, 이벤트 스토밍, CQRS/ES 개념.
- **API design**: RESTful API, gRPC, GraphQL, OpenAPI. MASC의 MCP tool schema 설계 경험 연결.
- **Testing strategy**: 단위/통합/E2E, contract testing, chaos engineering 입문.
- **Production incident handling**: 장애 복구, rollback, runbook 작성.
- **Practice project**: kidsnote 서비스 중 하나의 작은 기능을 개선하면서 architecture decision record(ADR) 작성.

### Year 3 — Advanced
- **Distributed systems**: consensus, eventual consistency, saga, idempotency, backpressure.
- **Security / reliability**: 인증/인가, secret management, DDoS, 장애 격리.
- **Cost / performance engineering**: 병목 분석, 비용 모델링, capacity planning.
- **Cross-service design**: 여러 서비스가 어울리는 플랫폼 설계.
- **Practice project**: 작지만 실제 사용자가 있는 서비스 하나를 end-to-end 설계/런칭.

### Year 5 — Independent designer
- **Trade-off mastery**: 제약 조건(비용, 인력, 시간, 법규) 하에서 설계 결정을 방어할 수 있음.
- **Technical writing**: RFC, ADR, 설계 문서를 명확하게 작성하고 리뷰받을 수 있음.
- **Mentoring**: 다른 keeper/개발자와 설계 리뷰를 주고받으며 품질을 높임.
- **Practice project**: kidsnote 또는 새로운 서비스의 핵심 모듈을 처음부터 설계/검증/배포.

---

## Concrete study / practice projects

| Timeline | Project | Skills |
|----------|---------|--------|
| 6개월 | Personal movie project tracker (CLI → web) | API, DB, CI/CD |
| 12개월 | kidsnote small feature refactor with ADR | Domain modeling, testing |
| 18개월 | MASC tool schema mini-proposal | API design, backward compatibility |
| 24개월 | kidsnote observability dashboard design | Metrics, alerting, SLO |
| 36개월 | Small side service launch | End-to-end design, deployment |
| 48~60개월 | Lead design of a real feature/service | Full system design, review, rollout |

---

## Connection to current work

- **MASC**: MCP tool schema, verification gate, provenance design(task-214) → API design, 시스템 신뢰성, 장애 분석 능력.
- **kidsnote**: production-ready goal(task-215) → CI/CD, 모니터링, 운영 설계 실전 경험.
- **Independent workspace goal**: 2년 goal(task-215) → 설계한 서비스를 직접 운영할 환경 구축.

---

## Open questions

1. 현재 kidsnote 서비스들의 실제 기술 스택/아키텍처 문서는 어디에 있는가?
2. kidsnote/benefit/cn-erp/store-attendance backlog가 MASC workspace에 안 보이는 이유가 무엇인가? 다른 workspace에서 관리되는가?
3. "처음부터 설계" 연습을 위해 MASC 내부의 어떤 작은 서비스/모듈부터 시뮬레이션할 수 있는가?
4. 5년 후의 목표 서비스는 kidsnote 연관이어야 하는가, 아니면 완전히 새로운 도메인이어도 되는가?

---

## Next concrete task

1. Map current kidsnote service architecture docs and repositories.
2. Pick one service and write an ADR for a small, safe improvement.
3. Use that ADR as the first practice project for Year 1-2.
