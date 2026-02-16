# 집현전 (Jiphyeonjeon) - Second Brain 내부 AI 의회

> 조선 집현전에서 영감받은 AI 에이전트 협업/토론 시스템

## 비전

```
┌─────────────────────────────────────────────────────────────┐
│                      집현전 (殿)                             │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐       │
│  │ 정언    │  │ 직제학   │  │ 응교    │  │ 부제학   │       │
│  │(Claude) │  │(Codex)  │  │(Gemini) │  │(Ollama) │       │
│  └────┬────┘  └────┬────┘  └────┬────┘  └────┬────┘       │
│       │            │            │            │             │
│       └────────────┴────────────┴────────────┘             │
│                        │                                   │
│                        ▼                                   │
│   ┌─────────────────────────────────────────────────────┐ │
│   │                  경연 (經筵)                         │ │
│   │  토론장 - 안건 제출, 논쟁, 합의                      │ │
│   └─────────────────────────────────────────────────────┘ │
│                        │                                   │
│          ┌─────────────┼─────────────┐                    │
│          ▼             ▼             ▼                    │
│   ┌──────────┐  ┌──────────┐  ┌──────────┐               │
│   │  상소    │  │  품의    │  │  실록    │               │
│   │ (제안)   │  │ (투표)   │  │ (기록)   │               │
│   └──────────┘  └──────────┘  └──────────┘               │
└─────────────────────────────────────────────────────────────┘
```

## 핵심 개념

### 1. 관직 체계 (Agent Roles)

| 관직 | 역할 | 모델 예시 |
|------|------|----------|
| 영의정 | 최종 결정권, 긴급 상황 대응 | Claude Opus |
| 직제학 | 코드 구현, 기술 검증 | Codex |
| 응교 | 정보 수집, 요약 | Gemini |
| 부제학 | 빠른 초안, 브레인스토밍 | Ollama/Qwen |
| 사관 | 모든 논의 기록 | 자동화 |

### 2. 경연 (Debate Protocol)

```ocaml
type gyeongyeon = {
  id: string;
  topic: string;
  proposer: agent_id;
  status: [ `Open | `Voting | `Concluded ];
  arguments: argument list;
  votes: vote list;
  conclusion: conclusion option;
}

type argument = {
  agent: agent_id;
  position: [ `Support | `Oppose | `Neutral ];
  content: string;
  evidence: string list;  (* 근거 *)
  timestamp: float;
}
```

### 3. 품의 시스템 (Consensus)

MAGI 삼두정치 확장:

```ocaml
type pumui_result =
  | Unanimous of conclusion      (* 만장일치 *)
  | Majority of conclusion * int (* 다수결 *)
  | Deadlock                     (* 교착 *)
  | Escalate of agent_id         (* 상위 결재 *)

let pumui ~quorum votes =
  let support = List.filter is_support votes |> List.length in
  let oppose = List.filter is_oppose votes |> List.length in
  let total = List.length votes in
  if support = total then Unanimous (conclude votes)
  else if support * 2 > total then Majority (conclude votes, support)
  else if oppose * 2 > total then Majority (conclude votes, oppose)
  else if total >= quorum then Deadlock
  else Escalate yeongeuijeong
```

### 4. 실록 (Immutable Archive)

모든 결정을 3중 저장:

```
PostgreSQL (정형 데이터)
    │
    ├── decisions: 최종 결정
    ├── debates: 토론 전문
    └── votes: 투표 기록

Neo4j (관계)
    │
    ├── (Agent)-[:PROPOSED]->(Topic)
    ├── (Agent)-[:ARGUED {position}]->(Topic)
    └── (Topic)-[:RESULTED_IN]->(Decision)

pgvector (검색)
    │
    └── 토론 내용 벡터 임베딩
```

## 독창적 메커니즘

### 1. 탕평책 (Balancing Policy)

특정 에이전트가 지배하지 않도록 균형:

```ocaml
type tangpyeong = {
  max_consecutive_wins: int;      (* 연속 채택 제한 *)
  min_participation: float;       (* 최소 참여율 *)
  rotation_policy: rotation;      (* 순환 발언 *)
  minority_protection: bool;      (* 소수 의견 보호 *)
}

let check_balance stats =
  if stats.consecutive_wins > config.max_consecutive_wins then
    Some `ForcedRotation
  else if stats.participation < config.min_participation then
    Some `MandatoryParticipation
  else
    None
```

### 2. 언관 시스템 (Critic Role)

전문 비판 에이전트:

```ocaml
type eongan = {
  target: proposal;
  critique_type: [ `Logic | `Feasibility | `Ethics | `Security ];
  severity: [ `Minor | `Major | `Blocking ];
  suggestion: string option;
}

(* 모든 중요 결정은 언관 검토 필수 *)
let require_review proposal =
  if proposal.impact >= High then
    spawn_critic ~type_:`All proposal
  else
    Ok proposal
```

### 3. 과거제 (Qualification)

에이전트 능력 검증:

```ocaml
type gwageo = {
  agent: agent_id;
  domain: string;          (* "code", "analysis", "creativity" *)
  score: float;
  rank: [ `Janggwon | `Banggan | `Tamhwa | `Byeongwa ];
  valid_until: float;
}

let can_participate agent topic =
  match find_qualification agent topic.domain with
  | Some q when q.valid_until > now () -> true
  | _ -> false  (* 자격 미달 *)
```

### 4. 상피제 (Conflict of Interest)

이해충돌 방지:

```ocaml
let check_sangpi agent topic =
  let history = get_agent_history agent in
  if proposed_similar topic history then
    `Recuse "자기 제안 투표 금지"
  else if recent_conflict agent topic.proposer then
    `Recuse "최근 충돌 이력"
  else
    `Clear
```

## OCaml 모듈 구조

```
lib/
├── jiphyeon/
│   ├── agent_role.ml      (* 관직 체계 *)
│   ├── gyeongyeon.ml      (* 경연/토론 *)
│   ├── pumui.ml           (* 품의/투표 *)
│   ├── tangpyeong.ml      (* 탕평책/균형 *)
│   ├── eongan.ml          (* 언관/비판 *)
│   ├── gwageo.ml          (* 과거제/자격 *)
│   ├── sangpi.ml          (* 상피제/충돌방지 *)
│   ├── sillok.ml          (* 실록/아카이브 *)
│   └── jiphyeon.ml        (* 통합 API *)
```

## 워크플로우 예시

```
1. 상소 (Proposal)
   └─> Claude: "spawn.ml에서 shell 제거 제안"

2. 경연 소집 (Debate Start)
   └─> 자동으로 관련 에이전트 소환

3. 논쟁 (Arguments)
   ├─> Codex: "동의, Eio.Process.spawn 직접 사용"
   ├─> Gemini: "보안 관점에서 필수"
   └─> Ollama: "기존 테스트 호환성 확인 필요"

4. 언관 검토 (Critic Review)
   └─> "Command Injection 위험 확인됨, CRITICAL"

5. 품의 (Vote)
   ├─> Claude: 찬성
   ├─> Codex: 찬성
   ├─> Gemini: 찬성
   └─> Ollama: 조건부 찬성

6. 결론 (Conclusion)
   └─> "만장일치 가결, 구현 진행"

7. 실록 기록 (Archive)
   └─> Neo4j + PostgreSQL + pgvector 저장
```

## 구현 우선순위

| Phase | 기능 | 예상 시간 |
|-------|------|----------|
| 0 | 기본 구조 (`agent_role.ml`, `gyeongyeon.ml`) | 1일 |
| 1 | 품의 시스템 (`pumui.ml`) | 1일 |
| 2 | 실록 연동 (`sillok.ml`) | 1일 |
| 3 | 탕평책 (`tangpyeong.ml`) | 0.5일 |
| 4 | 언관 시스템 (`eongan.ml`) | 1일 |
| 5 | 통합 + 테스트 | 1일 |

**총 예상: 5-6일**

## 기존 MASC 연동

```ocaml
(* MASC room에서 집현전 모드 활성화 *)
let config = {
  room_config with
  mode = Jiphyeonjeon {
    min_agents = 3;
    quorum = 0.6;
    require_critic = true;
  }
}
```

---

*"집현전은 단순한 토론장이 아니라, 지혜가 모여 결정되는 곳이다."*
