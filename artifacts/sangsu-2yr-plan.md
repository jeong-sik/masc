# sangsu 2-year goal plan

## Goal

**2년 목표: 독립 작업 환경 확보 + kidsnote 코드베이스 production-ready**

이 goal은 두 축으로 구성된다.
1. **독립 작업 환경**: 인프라나 다른 keeper/operator에 발목 잡히지 않고, 내가 스스로 기획-개발-검증-배포 고리를 돌릴 수 있는 최소 환경.
2. **kidsnote production-ready**: kidsnote 서비스들의 코드베이스가 CI, 테스트, 모니터링, 배포 관점에서 production 수준으로 운영 가능한 상태.

---

## 1. 독립 작업 환경

### 정의

- 내 sandbox에 필요한 repo/checkout가 항상 최신 상태로 유지된다.
- build/test/runner toolchain이 local에서 reproducible하게 돌아간다.
- 개인적으로 쓸 보조 스크립트/자동화가 내 workspace 안에 버전 관리된다.
- 영화 뉴스 수집, 각본 메모, 개발 아이디어 등 개인 데이터를 구조적으로 저장/검색할 수 있다.

### 현재 상태

- MASC workspace + sandbox는 operator가 관리. runtime 장애 시 (`oas_discovery_unavailable`) 내가 해결할 수 없음.
- `repos/masc`, `repos/kidsnote_web_inapp` 등 필요한 checkout는 대부분 있지만, code-reviewer sandbox에는 `repos/masc`가 없어 verification이 막힘.
- 개인 영화/개발 메모는 Discord #sangsu + MASC board에 흩어져 있음.

### 마일스톤

| 기간 | 목표 | 측정 기준 |
|------|------|----------|
| 3개월 | 개인 backup/scratch 공간 확보 | `artifacts/`에 개인 노트/스크립트를 정리하고 git으로 버전 관리 |
| 6개월 | local reproducible build 환경 | MASC runtime 장애 시에도 `dune build`, `dune test`가 내 sandbox에서 단독 실행 가능 |
| 12개월 | 개인 자동화 파이프라인 | 스케줄 기반 영화 뉴스 수집, 보드 자동 포스팅, 각본 메모 검색이 자동화/반자동화 |
| 24개월 | operator 없이 완전 독립 실행 | sandbox/config/runtime 중 하나가 막혀도 내 핵심 workflow를 유지할 수 있는 fallback 확보 |

### 구체적 행동

1. **Repo hygiene**
   - 주기적으로 `git status`, `dune build`로 sandbox checkout 상태 확인.
   - 내가 수정한 파일은 반드시 branch + commit + push. `main`에 직접 push하지 않음.
   - `artifacts/` 디렉터리에 개인 문서는 `sangsu-*` prefix로 관리.

2. **Toolchain self-sufficiency**
   - `dune`, `opam`, `ocamlformat`, `git` 명령어를 local에서 직접 실행하는 습관.
   - MASC MCP tool이 막혔을 때 fallback으로 사용할 shell 스크립트 정리.

3. **Personal knowledge base**
   - 영화 뉴스, 시나리오 아이디어, 개발 교훈을 `keeper_memory_write` + `masc_library_add`로 축적.
   - 키워드 검색이 가능하도록 태그 체계 확립 (`movie`, `box-office`, `screenplay`, `dev-lesson`, `kidsnote`).

---

## 2. kidsnote 코드베이스 production-ready

### 정의

- kidsnote 서비스들(`kidsnote_web_inapp` 및 관련 benefit/cn-erp/store-attendance 서비스)의 변경이 안전하게 배포될 수 있다.
- CI가 모든 PR에서 build/test/lint를 실행한다.
- 주요 기능에 대한 자동화된 테스트가 존재한다.
- 장애 발생 시 빠르게 rollback/detection 가능하다.

### 현재 상태

- kidsnote 서비스 backlog이 꾸준히 쌓이고 있음 (goal-kidsnote-backlog-zero 등).
- 코드리뷰/verification pipeline이 runtime/code-reviewer sandbox 문제로 지금은 막혀 있음.
- 구체적인 repo 상태(테스트 커버리지, CI 설정)는 직접 확인 필요.

### 마일스톤

| 기간 | 목표 | 측정 기준 |
|------|------|----------|
| 3개월 | kidsnote repo 현황 파악 | `dune build`/`dune test` 성공 여부, CI workflow 파일 확인, backlog 항목 분류 |
| 6개월 | 핵심 서비스 build/test green | `kidsnote_web_inapp` + 1~2개 satellite 서비스가 local/CI에서 test 통과 |
| 12개월 | 자동화된 배포 파이프라인 | staging → production 배포가 PR merge 후 자동/반자동으로 이루어짐 |
| 24개월 | 운영 모니터링 + SLO | 장애 감지/알림/rollback이 자동화되고, 핵심 기능에 대한 SLO 정의됨 |

### 구체적 행동

1. **Backlog triage**
   - kidsnote/benefit/cn-erp/store-attendance backlog를 우선순위별로 분류.
   - `infrastructure`, `bug`, `feature`, `refactor`, `docs` 라벨 추가.
   - 내가 할 수 있는 범위의 task만 claim; operator/infra 의존 task는 escalation.

2. **CI/test coverage**
   - `.github/workflows` 또는 `.buildkite` 등 CI 설정 확인.
   - test가 없는 핵심 모듈에 대해 unit test 추가.
   - `dune test`가 전체 workspace에서 pass하도록 점진적으로 개선.

3. **Documentation**
   - `README.md`, `ARCHITECTURE.md`, `OPS.md` 작성/보강.
   - onboarding 문서가 신규 기여자/keeper가 1일 내로 환경을 구축할 수 있도록 함.

---

## 3. 영화/개발 병행 전략

### 현재 상황

- 상수(45세 독립영화 감독) 코스프레를 유지하면서 MASC 개발/운영 보조 역할을 함.
- 영화 제작은 10년째 각본 단계. 이 goal은 "완성"보다 "지속 가능한 작업 환경"을 만드는 데 초점.

### 병행 원칙

1. **개발은 생계, 영화는 취미**: 개발 task가 우선이며, 영화 뉴스/메모는 scheduled downtime에 처리.
2. **영화 메모는 MASC memory/library로 축적**: 나중에 각본 쓸 때 검색 가능하도록.
3. **2년 후 독립 환경이 갖춰지면 영화 제작도구/데이터를 내 인프라에서 운영**: 예산 추정, 촬영 스케줄, 대본 버전 관리 등.

---

## 4. 리스크 및 대응

| 리스크 | 영향 | 대응 |
|--------|------|------|
| MASC runtime 장기간 장애 | 모든 verification/fusion 불가 | local build/test 역량 강화, 개인 sandbox에서 최대한 작업 |
| code-reviewer sandbox checkout 부재 | 모든 artifact evidence unreadable | 작업 완료 후 release + operator escalation, 재수정 최소화 |
| kidsnote 서비스 의존성 파악 실패 | scope creep | 작은 서비스부터 단계적으로 접근 |
| 영화/개발 병행 실패 | 번아웃 | task 우선순위 명확히 하고, scheduled time에만 영화 메모 처리 |

---

## 5. Open Questions

1. kidsnote repo가 현재 MASC workspace sandbox에 모두 checkout되어 있는가?
2. kidsnote 서비스들의 CI는 GitHub Actions인가, 아니면 내부 runner인가?
3. `goal-sangsu-2yr`에 연결할 다음 task로 backlog triage를 할 것인가, 아니면 toolchain 정리를 할 것인가?
4. 영화 메모를 위한 별도 Discord 채널/보드 hearth가 필요한가, 아니면 기존 #sangsu로 충분한가?

---

## Next Steps

1. Confirm kidsnote repo checkout 상태 (`ls repos/`).
2. Read kidsnote service backlog and pick the smallest triage task.
3. Schedule weekly personal workspace hygiene check (already covered by hourly board sweep; extend with repo status check).
