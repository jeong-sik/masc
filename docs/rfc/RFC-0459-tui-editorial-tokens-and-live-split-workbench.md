---
rfc: "0459"
title: "TUI 에디토리얼 디자인 토큰 체계, 네이티브 다이어그램 엔진, 그리고 초고속 대화 워크벤치"
status: Draft
created: 2026-09-19
updated: 2026-09-19
author: dancer + antigravity
supersedes: []
superseded_by: null
related: ["0429", "tui-operator-ia", "tui-frame-budget"]
---

# RFC-0459: TUI 에디토리얼 디자인 토큰 체계, 네이티브 다이어그램 엔진, 그리고 초고속 대화 워크벤치

## 0. Summary

현재 MASC TUI(`masc-tui`)는 멀티 에이전트(Keepers)의 실행과 도구 호출을 감시하는 핵심 운영 인터페이스다.
그러나 급격한 기능 확장으로 인해 세 가지 중대한 문제에 직면해 있다.

1. **정보 구조 파편화와 과밀 (9/10 밀도)**: 18~23개에 달하는 서페이스가 평면 나열되어 조작 피로도가 높고, 불필요한 테두리 박스가 화면을 메워 핵심 상태가 눈에 띄지 않는다.
2. **Mermaid 파서의 태생적 한계**: 기존 Mermaid 텍스트 변환 파서는 가로 폭이 좁거나 복잡해지면 즉시 `Too_wide` 에러를 내며 깨지고, 에이전트 핵심 역학(순환 루프, 공유 메모리 허브, 스윔레인)을 담아내지 못한다.
3. **대화 접근 및 검증의 높은 마찰**: 키퍼와 대화하려면 로스터와 패널을 거쳐 `Meta-i`를 눌러야 하는 등 3단계를 거쳐야 하며, 도구 실행 결과 본문이 버려져 실제 에이전트 출력을 즉시 확인하기 어렵다.

이 RFC는 다음 네 가지 해결책을 확정한다:
- **Atlassian Design System(DESIGN.md) 기반 시맨틱 토큰 모델**: 단순 ANSI 열거형을 벗어나 `text`, `bg`, `border` 의도(Intent) 및 L0~L3 표고(Elevation) 계층을 확립한다.
- **Diagram Design 에디토리얼 비주얼 원칙 (밀도 4/10)**: 불필요한 박스를 지우고 단일 악센트 색상을 적용하여 가독성을 극대화한다.
- **네이티브 에디토리얼 다이어그램 엔진**: 깨지기 쉬운 Mermaid를 대체하여, 터미널 UTF-8 기반의 플라이휠(The Flywheel Loop), 스윔레인(Multi-Agent Swimlane), 파이프라인 리본, 자원/락 매트릭스를 네이티브로 렌더링한다.
- **초고속 대화 접근 및 워크벤치 아키텍처**:
  - `i` 단축키로 어디서든 호출되는 전역 스포트라이트 퀵 대화창
  - 진입 즉시 입력창에 포커스가 잡히는 Chat-First 모드
  - `Alt-1`~`Alt-4` 키퍼 다이렉트 점프
  - 안정적인 2열 분할(방향 A) 및 대화/코드 50:50 실시간 동시뷰(방향 B) 지원

---

## 1. 배경 및 실측 결함

### 1.1 실측 결함 인벤토리 (v0.28.0 실측)

| 결함 영역 | 현상 | 원인 및 문제 위치 |
|---|---|---|
| **도구 결과 증발** | 도구 호출 성공/실패 여부만 표시되고 반환 본문이 보이지 않음 | `Live.Tool_result`가 `{occurrence; execution_id}`만 나르고 결과 페이로드를 디코드하지 않음 |
| **줄바꿈 제어문자 노출** | 변경 목록의 WHAT 열에 `\x0A` 여섯 글자가 그대로 출력됨 | `Terminal_text.single_line`이 줄바꿈을 제어문자로 일괄 치환 |
| **Mermaid 폭 초과 에러** | 조금만 복잡한 도표도 터미널 폭을 넘어 깨짐 | `Too_wide of {cells; cols}` 발생 후 에러 문자열만 출력 |
| **대화 진입 마찰** | 키퍼 대화창에 포커스를 주려면 최소 3회 키 입력 필요 | 로스터와 상세창이 분리되어 있고 기본 포커스가 로스터에 머묾 |
| **컨텍스트 토큰 은닉** | 모델 컨텍스트 윈도우 잔여량을 보려면 모달(`Ctrl-X`)을 띄워야 함 | 상시 모니터링 게이지 부재로 토큰 오버플로우 사전 감지 불가 |

---

## 2. 디자인 토큰 및 표고 체계 (Atlassian Design System 적용)

단순 ANSI 색상 코드를 걷어내고 `Masc_tui_token` 모듈로 시맨틱 토큰을 정의한다.

### 2.1 시맨틱 컬러 토큰
- `text.default`: 기본 읽기 텍스트
- `text.subtle`: 타임스탬프, 부가 설명 (명암비 4.5:1 준수)
- `text.brand`: 현재 활성 탭, 선택된 키퍼 식별자 (Blue)
- `text.danger`: 실패한 검증, 게이트 거절, 치명적 에러 (Red)
- `text.warning`: 승인 대기, 타임아웃 임박, 컨텍스트 80% 도달 (Yellow/Orange)
- `text.success`: 도구 성공, 검증 통과, 변경 적용 완료 (Green)
- `text.discovery`: 에이전트 자율 추론, 계획, 지식 탐색 (Purple/Magenta)

### 2.2 표고(Elevation) 및 레이어 규칙
- **L0 Base Canvas**: 터미널 기본 배경, 탭 스트립 및 글로벌 상태 바.
- **L1 Card / Pane**: 좌우 분할 패널 (로스터, 대화창, 실시간 인스펙터). 미세한 테두리(`border-subtle`)만 사용.
- **L2 Floating Inspector**: 줄 메모, 호버 상세 정보. 배경 밝기 스텝업.
- **L3 Modal Blanket**: 명령 팔레트(`Ctrl-P`), 도구 결과 전체창(`Enter`), 토큰 인스펙터(`Ctrl-X`). 뒤 배경을 Dim 처리하여 시각적 계층 분리.

---

## 3. 에디토리얼 다이어그램 엔진 (Mermaid 대체)

Cathryn Lavery의 Diagram Design 철학에 따라 불필요한 박스를 지우고, 에이전트 핵심 역학을 표현하는 네이티브 렌더러를 도입한다.

### 3.1 4대 네이티브 에디토리얼 패턴

#### 1) The Agent Flywheel Loop (순환 루프와 공유 메모리 허브)
에이전트의 자기 개선 루프(Prompt → Tool Exec → Verify → Memory OS)를 표현하며, 중앙 메모리 허브에만 단일 악센트 색상을 부여한다.

```text
                      1. Context Assembly
                    ┌─────────────────────┐
                    │                     ▼
              ┌───────────┐         ┌───────────┐
              │  Memory   │         │    LLM    │
              │ OS (Hub)  │         │ Execution │
              └───────────┘         └───────────┘
                    ▲                     │
                    │   4. Writeback      ▼
                    └┄┄┄┄┄┄┄┄┄┄┄┄┄┄ ┌───────────┐
                                    │   Tool    │
                         3. Verify  │ Execution │
                                    └───────────┘
                                          │
                                          ▼ 2. Run
```

#### 2) Continuous Execution Pipeline Ribbon (수평 파이프라인 리본)
터미널 세로 공간을 절약하는 1열 컨베이어 벨트형 흐름도.
```text
 ──▶ [1. CONTEXT] ──▶ [2. PROMPT] ──▶ [3. LLM INFER] ──▶ [4. TOOL EXEC] ──▶ [5. VERIFY] ──▶ [APPLIED]
        ▲                                                                        │
        └─────────────────── [FEEDBACK: Memory OS Writeback (+14 lessons)] ──────┘
```

#### 3) Multi-Agent Coordination Swimlane (협업 스윔레인)
운영자, 게이트, 주 키퍼, 워커 간의 메시지 흐름과 블로킹 지점을 명확히 보여준다.
```text
  TIME   OPERATOR          GATEKEEPER        LEAD (keeper-03)   WORKER (keeper-01)
 ───────────────────────────────────────────────────────────────────────────────────
  13:10  Plan "Refactor" ──▶ Policy check
  13:11                        │ (Approved) ──▶  Split AST tasks ──▶ Run AST test
  13:12                                             │                │ (pass 1.2s)
  13:13  [Pending Approval] ◀────────────────────── ┴──────────────◀ Commit changes
```

#### 4) Multi-Agent Resource & Lock Matrix (동시성 락 감시 매트릭스)
동시에 여러 키퍼가 구동될 때 파일 락 경합 및 메모리 동기화 지연을 감시한다.

---

## 4. 초고속 대화 접근 및 워크벤치 아키텍처

### 4.1 대화 접근 초고속화 3대 메커니즘
1. **전역 퀵 대화창 (`i` 단축키)**: 어느 화면에 있든 `i` 입력 시 상단 스포트라이트 대화 바가 열려 활성 키퍼에게 즉시 발화 가능.
2. **Chat-First 자동 포커스**: 워크벤치 진입 시 하단 입력창에 커서가 기본 위치하여 추가 조작 없이 타이핑 시작.
3. **키퍼 다이렉트 점프 (`Alt-1`~`Alt-4`)**: 로스터 화살표 스크롤 없이 0.1초 만에 특정 키퍼 대화로 전환.

### 4.2 두 가지 워크벤치 레이아웃 방향 (방향 A vs 방향 B)

- **방향 A (Atlassian Enterprise Cockpit)**:
  - 좌측 로스터(25%) + 우측 4렌즈 탭(75%: Chat, Diff, Context, Memory).
  - 안정적이고 체계적인 정보 분리.
- **방향 B (Agent IDE Live-Split & Triage Hub)**:
  - 상단 키퍼 칩 캐러셀 배치로 좌측 사이드바 제거 (화면 폭 100% 활용).
  - 좌측 대화 스트림(50%)과 우측 실시간 코드 Diff/도구창(50%) 상시 병렬 배치.
  - 대화하면서 키퍼가 변경하는 코드를 실시간으로 확인.

### 4.3 도구 실행 결과 2단계 검사 체계
- **1단계 (인라인 요약)**: 대화창 내에 실행 상태, 경과 시간, 3줄 요약 + Head/Tail 2줄을 즉시 노출.
- **2단계 (L3 전체 모달)**: `Enter` 키 입력 시 팝업 모달을 띄워 수십 KB에 달하는 전체 원본 출력 검토.

---

## 5. 단계별 구현 로드맵 (Roadmap)

1. **Phase 1: 디자인 토큰 모듈 (`bin/masc_tui_token.ml`)**
   - 시맨틱 색상 및 L0~L3 표고 상수 정의
   - 기존 `masc_tui_theme.ml` 무중단 래핑
2. **Phase 2: 네이티브 에디토리얼 다이어그램 엔진 (`bin/masc_tui_diagram.ml`)**
   - 순환 루프(Flywheel), 스윔레인, 파이프라인 리본 렌더러 구현
   - `masc_tui_mermaid.ml` 단계적 퇴역
3. **Phase 3: 10탭 IA 및 워크벤치 레이아웃 개편**
   - `surface_ring` 10탭 압축
   - Fast-Chat(전역 `i`, Chat-First, Alt-점프) 탑재
4. **Phase 4: 백엔드 데이터 파이프라인 연동**
   - 도구 실행 본문 디코딩 및 SSE 이벤트 보강
   - Memory OS 8대 카테고리 트리 노출
5. **Phase 5: Golden Test 및 회귀 검증**
   - 전 화면 PTY 프레임 캡처 및 자동화 회귀 검증

---

## 6. 참고 자료 및 시안

- 인터랙티브 프리뷰 파일: `docs/design/tui/preview/masc-tui-preview.html`
- Atlassian Design System: `https://atlassian.design/DESIGN.md`
- Diagram Design: `https://github.com/cathrynlavery/diagram-design`
