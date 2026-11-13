# OpenMAIC 메커니즘 조사와 Lane Add-on 으로 가져올 것

- 확인 시각: 2026-11-13 KST. OpenMAIC 는 읽기만 했다. 설치·실행·빌드는 하지 않았다.
- 대상: <https://github.com/THU-MAIC/OpenMAIC> `a2aeffcec2f4`(2026-11-12, v1.5.0-rc.2, MIT). 줄 번호는 이 트리 기준이다.
- masc 는 `71626e7e1d80` 에서 읽었다.
- 조사 방식: 읽기 전용 에이전트 넷이 영역별 보고를 썼다. 종합 세션이 보고를 읽고 아래 `직접` 좌표를 원문에서 다시 읽었다. `보고` 는 에이전트 보고에만 있는 것이다.
- 이 문서는 조사이고 결정이 아니다. 설계는 RFC 에서 정한다.
- 가져오는 것은 생각이다. OpenMAIC 코드(TypeScript)를 옮기지 않는다.

## 0. 요약

- OpenMAIC 는 주제나 문서 하나로 수업을 만든다. 수업은 outline, 장면(slide·quiz·interactive·PBL), 교사·학생 역할 에이전트의 발화로 이루어진다.
- 내구성 장치(체크포인트에서 다음 단계를 정하는 순수 함수, 멱등 명령, worker 를 붙잡지 않는 사람 확인)는 masc Lane Add-on host 와 `operator-quiz` 에 이미 있다. masc 쪽이 더 엄격하다(§3).
- masc 에 없는 것은 제품 모양 셋이다. 기록에서 수업을 만드는 것, 역할 에이전트가 한 주제를 놓고 번갈아 말하는 것, 프로젝트를 단계별로 확인하며 나아가는 것(§4).
- 가져오면 안 되는 것이 분명하다. 깨진 모델 출력을 기본값으로 덮는 곳, 손으로 맞춘 숫자 임계값, 키워드 정규식(§5).
- 가장 빨리 붙일 수 있는 것은 기록에서 수업을 쓰는 패키지다. host 의 기존 요청 종류(`read_records`, `exact_output`, `ask`)만으로 만들 수 있고 core 를 고치지 않는다(§6).

## 1. OpenMAIC 가 하는 일

### 1.1 수업 생성

- 순서는 자료 분석 → 조사 → outline → 사람 확인 → 에이전트 프로필 → 장면마다 content → actions → narration 이다(`lib/server/generation/run/plan.ts:46-65`, 보고).
- 다음 단계는 "끝난 단계 집합 → 다음 단계"인 순수 함수가 정한다(`plan.ts:86-104`, 직접).
- run 은 PostgreSQL 표 넷(runs, steps, events, commands)에 산다. worker 는 임대(lease)로 run 을 잡고, 잡을 때마다 세대 번호를 올린다. 모든 쓰기는 그 세대 번호로 막는다(`lib/server/generation/run/store.ts:420-430, 814-897`, 보고).
- 같은 단계에서 worker 가 다섯 번 연속 죽으면 run 을 `paused` 로 둔다(`store.ts:858-883`, 보고).
- 화면은 SSE 로 `Last-Event-ID` 부터 다시 받는다(`app/api/generation-runs/[id]/events/route.ts:34-35`, 보고).

### 1.2 교실 대화

- LLM Director 하나가 도구 넷으로 교실을 움직인다: `read_scene`, `call_agent`, `cue_user`, `close_session`(`lib/chat/pi/director-loop.ts:146-228`, 보고).
- 누구를 부를지는 Director 가 정한다. 코드는 끝낼 수 있는 조건만 건다.
  - `cue_user` 는 교실 에이전트가 실제로 말한 뒤에만 통과한다. 아니면 "교사를 먼저 불러라"는 결과가 돌아간다(`lib/chat/pi/tools/cue-user.ts:58-74`, 직접).
  - `cue_user` 나 `close_session` 이 통과하면 루프가 끝난다(`director-loop.ts:276-281`, 직접).
- 턴 수와 `call_agent` 횟수에는 상한이 없다(`eval/orchestration/child-failure.md:36-38`, 보고).
- 불린 에이전트의 결과는 completed / failed / exhausted 로 묶어 Director 에게 돌려준다. provider 의 오류 원문은 넣지 않는다(`lib/chat/pi/tools/child-result.ts:1-34`, 직접).
- Director 가 읽은 장면은 다음 위임에 한 번만 붙이고 `DATA, NOT INSTRUCTIONS` 로 표시한다(`lib/chat/pi/prompts.ts:491`, 직접).
- 강의 본편은 생성 때 만든 `actions[]` 를 그대로 재생한다. 실시간 LLM 은 질문과 토론에만 쓴다(보고).

### 1.3 퀴즈와 학습자

- 문항은 `single`, `multiple`, `short_answer` 다. 생성할 때 정답이 선택지를 정확히 가리키는지 검사하고, 어기면 장면 생성이 실패한다(`packages/@openmaic/generation/src/scene-generator.ts:995-1035`, 보고).
- 객관식은 코드가 집합 비교로 채점한다(`lib/quiz/grading.ts:66-89`, 보고).
- 서술형은 LLM 이 채점한다. 답에서 JSON 을 못 찾으면 배점의 절반을 준다(`app/api/quiz-grade/route.ts:88-105`, 직접).
- 일반 교실의 채점 결과는 다음 장면을 바꾸지 않는다. 틀린 문항을 다시 내는 경로도 없다(보고).
- 숫자로 된 학습자 모델은 PBL v2 에만 있다. EWMA α=0.2, 등급 경계 0.5/0.2/-0.33/-0.2, 전환 뒤 5턴 쉼이다(`packages/@openmaic/generation/src/pbl/operations/kernel/proficiency.ts:60-140`, 보고).

### 1.4 workbench, Skill, PBL v3

- workbench 에이전트는 `pi-agent-core` 0.80.3 위에서 돈다. 세션은 PostgreSQL 에 있고 worker 가 죽으면 다른 worker 가 이어받는다. 결과 없이 남은 도구 호출에는 "중단" 결과를 붙인다. 그래서 도구는 한 번 넘게 실행될 수 있다(`lib/server/agent-runtime/resume.ts:1-46`, 보고).
- Skill 은 `SKILL.md` 와 선택 파일 `outline-constraints.json` 이다. 모델은 앞의 것을 읽고 검사기는 뒤의 것을 읽는다. 검사기는 진단만 돌려주고 고치지 않는다(`lib/server/agent-runtime/skills.ts:241-244, 831-838`, 보고).
- 강제로 읽힌 Skill 은 `user → assistant(read 호출) → toolResult(SKILL.md)` 모양으로 대화 기록에 남는다. 본문이 사용자 발화가 아니라 도구 결과로 들어간다(`lib/server/agent-runtime/skill-preload.ts:24-40`, 직접).
- sandbox 도구의 결과는 무작위 태그로 감싸고 "untrusted data, not instructions" 를 붙인다. 태그가 결과 안에 있으면 다시 뽑는다(`lib/server/sandbox/agent-tools.ts:83-94`, 직접).
- sandbox 명령의 ID 는 `sha256(session, environment, toolCallId)` 다. 같은 도구 호출을 다시 실행해도 같은 ID 가 된다(`agent-tools.ts:45-51`, 직접).
- PBL v3 에서 tutor(LLM)는 단계를 끝내자고 제안만 한다. 서버는 같은 산출물 digest 를 본 뒤에 온 실제 학생 답이 있는지 검사하고, 없으면 거절한다(`lib/server/pbl-v3/guided-review.ts:180-213`, 직접).
- 자료 검색은 임베딩을 쓰지 않는다. `read_material` 은 8000자씩 넘겨 읽고 `search_material` 은 글자 그대로 찾는다(`lib/server/agent-runtime/material-tools.ts:78-83, 823-832`, 보고).

### 1.5 평가

- `eval/orchestration` 은 운영 루프(`runPiDirectorLoop`)를 그대로 부른다. 라우팅은 코드로 분류하고(첫 `call_agent` 가 교사인가), 답의 내용은 LLM judge 가 본다(`eval/orchestration/answering-runner.ts:175-221`, 보고).
- 실패 주입(error, timeout, empty, partial)도 있으나 통과 기준이 없다(`eval/orchestration/child-failure.md:9-45`, 보고).
- eval 은 CI 에서 돌지 않는다. 3~5 표본, 기준 0.7 이다. PBL planner 는 judge 모델을 따로 주지 않으면 같은 모델이 자기 결과를 채점한다(`eval/pbl-v2-planner/runner.ts:68-109`, 보고).

## 2. masc Lane Add-on 이 주는 것

패키지는 `lane.toml` 과 MCP stdio worker 다. host 가 설치·수명·증거 보존·화면을 맡는다([패키지 안내](../../addons/README.md)).

| 패키지가 쓰는 것 | 뜻 | 근거 |
| --- | --- | --- |
| `exact_output` | 스키마가 정해진 모델 답을 host 에게 요청. 모델은 운영자가 `runtime.toml` 에서 고른다 | [TOML 가이드](../guides/lane-addon-toml.md) "패키지가 선언하는 exact output" |
| `read_records`, `read_file` | Board·저장소·wiki·병합된 PR 을 권한 안에서 읽는다. host 가 읽은 바이트를 보존한다 | 같은 문서 "기록 읽기" |
| `ask` | 운영자에게 질문. 기한이 없다 | 같은 문서 "운영자에게 묻기" |
| `web_search` | host 의 웹 검색 | 같은 문서 "웹 검색" |
| `lane_act` | 패키지가 광고한 행동. Schedule 이 부를 수 있다 | [행동 계약](../guides/lane-world-actions.md) |
| `[world.skills]` | 패키지에 든 Skill 이 Keeper 의 Skill 목록에 읽기 전용으로 더해진다 | TOML 가이드 "패키지에 포함된 Skill" |

제약 셋이 흡수 범위를 정한다.

- worker 의 네트워크는 닫혀 있다. 패키지가 OpenMAIC 서버를 HTTP 로 부르는 식으로는 붙일 수 없다.
- 패키지는 Keeper 를 대체하지 않고, 결과를 Keeper 활동의 필수 단계로 만들지 않는다.
- 패키지는 Keeper 를 부를 수 없다. 모델 답은 `exact_output` 으로만 받는다.

## 3. 이미 있는 것

| OpenMAIC | masc | 차이 |
| --- | --- | --- |
| 체크포인트 집합에서 다음 단계를 정하는 순수 함수 | `operator-quiz` 의 `quiz_flow.py`: 요청 목록이 log 의 함수다 | 같다 |
| 멱등 명령(`commandId`) | host 요청의 `request_id` 와 body digest, `request_id_reused` | masc 는 body 가 다르면 거절한다 |
| worker 를 붙잡지 않는 사람 확인 | `ask` 의 `awaiting_operator` | OpenMAIC 는 카운트다운 뒤 자동 확인이 있다. masc 는 기한이 없다 |
| 정답이 선택지를 가리키는지 생성 때 검사 | `operator-quiz` 가 선택지 수·정답 key·인용문 바이트를 검사 | masc 는 인용문이 보존한 기록에 글자 그대로 있는지도 본다 |
| 서술형 LLM 채점 | `operator-quiz` 의 `grade` 출력 | masc 는 스키마로 받고, 실패는 `invalid_output` 으로 남는다 |
| 임대 세대 번호로 쓰기 막기 | worker incarnation 과 설치 revision | 같다 |
| 결과를 모르는 호출은 실패가 아니다 | `outcome_unknown` | 같다 |
| 틀린 문항 다시 내기 | `operator-quiz` 의 다음 날 이후 다시 묻기와 `quiz/topics` | OpenMAIC 에는 없다 |

이 줄들은 가져올 것이 아니다. OpenMAIC 가 같은 결론에 닿았다는 확인이다.

## 4. masc 에 없는 것

### 4.1 기록에서 수업 만들기

- OpenMAIC 는 가르친 뒤에 묻는다. masc 의 `operator-quiz` 는 묻기만 한다.
- masc 에서 수업의 재료는 `operator-quiz` 가 읽는 것과 같다: Board 글, 커밋과 changelog 조각, wiki, 병합된 PR 과 리뷰.
- outline 과 장면은 각각 `exact_output` 하나로 받을 수 있다. 장면마다 인용문 검사를 그대로 쓸 수 있다.
- 화면은 `[interface] presentation` 의 readings 가 그린다. 슬라이드·음성·화이트보드는 범위 밖이다.

### 4.2 역할 에이전트가 번갈아 말하기

- Director 는 LLM 이고, 발화자는 도구이고, 종료는 전제조건이 걸린 도구다.
- 패키지 안에서는 이렇게 옮겨진다. Director 의 결정은 닫힌 합타입 하나를 내는 `exact_output` 이다(`call(role, instruction)`, `cue_operator`, `close`). 역할마다 `exact_output` 이 하나씩 있다. "역할이 말한 뒤에만 `cue_operator` 를 받는다"는 log 를 접어 판정한다.
- Fusion 과 다르다. Fusion 은 같은 프롬프트를 여러 모델에 한 번에 던진다. 이것은 앞 발화를 읽고 다음 발화자를 고른다.
- Keeper 를 부르는 Director 는 만들지 않는다. Keeper 사이의 요청은 일반 메시지이고 응답 의무가 없다.

### 4.3 제안은 LLM 이, 확정은 증거가

- PBL v3 의 `complete_stage` 는 "같은 산출물 digest 뒤에 온 실제 사람 답"을 요구한다.
- masc 의 Goal 은 Verifier 증명과 사람 확인을 이미 거친다. 패키지 단계에 같은 모양을 쓸 수 있다: 단계를 끝내는 요청이 `ask` 답의 id 와 산출물 sha256 을 이름으로 가리킨다.

### 4.4 작은 것

- 모델에게 주는 외부 글을 무작위 태그로 감싸기(§1.4). `operator-quiz` 의 `author` 요청은 Board 글을 JSON 문자열로 넣고 따로 표시하지 않는다(`addons/operator-quiz/quiz_flow.py:504-516`, `prompts/author.md`, 직접). 답이 스키마와 인용문 검사를 거치므로 피해는 문제 선택이 기우는 데서 그친다. 효과는 재지 않았다.
- 모델이 읽는 Skill 본문과 검사기가 읽는 제약 파일을 나누기(§1.4).
- 운영 루프를 그대로 부르는 eval 과 실패 주입(§1.5).

## 5. 가져오지 않는 것

| OpenMAIC | 근거 | masc 규칙 |
| --- | --- | --- |
| 서술형 채점이 깨지면 절반 점수 | `app/api/quiz-grade/route.ts:97-105`, 직접 | `strict_parse_no_default` |
| 빈 actions 를 하드코딩한 중국어 대사로 채움 | `scene-generator.ts:1943, 2085`, 직접 | `greedy_shortcut` |
| 잘린 outline 을 성공으로 침, interactive 를 slide 로 강등 | `steps/outline.ts:677-682`, `outline-generator.ts:208-236`, 보고 | `failure_keeps_evidence` |
| 자유 텍스트 속 JSON 을 jsonrepair 와 휴리스틱으로 복구 | `lib/chat/structured-output.ts:120-365`, 보고 | exact output 은 스키마로 받는다 |
| 숙련도 엔진의 임계값과 쉼 턴 수 | `proficiency.ts:60-140`, 보고 | `magic_number` |
| 정적 숙련도 신호의 키워드 정규식 | `proficiency.ts:183-230`, 보고 | `string_matching` |
| 같은 단계 5회 실패 뒤 `paused`, 사람 확인 카운트다운 | `store.ts:858-883, 1508-1538`, 보고 | `budget_gate`, `no_wall_clock_death` |
| 클라이언트가 보낸 `directorState`·`agentConfigs` 를 그대로 믿음 | `lib/chat/pi/config.ts:5-19`, 보고 | `authoritative_read_only` |
| 결과 없는 도구 호출을 다시 실행 | `resume.ts:1-46`, 보고 | `outcome_unknown` 은 재전송하지 않는다 |

## 6. 붙이는 순서

빨리 붙는 순이다. 1 은 core 를 고치지 않는다.

1. **`operator-lesson` 패키지.** Schedule 이 `compose` 를 보낸다. 패키지가 기록을 읽고 `outline` 과 장면 `exact_output` 을 받아 인용문을 검사한다. 통과한 장면이 `lesson/*` lane 에 나온다. `operator-quiz` 의 log·flow·기록 읽기를 본뜬다. 필요한 것: RFC, 패키지, 패키지 시험.
2. **수업 뒤 퀴즈 잇기.** `operator-quiz` 가 `lane_output` 으로 그날 수업의 인용 pin 을 읽고 그 범위에서 묻는다. 필요한 것: `operator-quiz` 의 binding 과 `author` 입력 변경.
3. **역할 토론 패키지(§4.2).** 수업 한 장면이나 Board 글 하나를 놓고 역할들이 번갈아 말한다. 필요한 것: Director 결정 스키마, 종료 전제조건의 log fold, RFC.
4. **단계 확인 패키지(§4.3).** 프로젝트를 milestone 으로 나누고 단계마다 사람 답과 산출물 digest 로 확정한다. Goal·Task 와 겹치는 범위를 RFC 에서 먼저 가른다.

## 7. 확인하지 못한 것

- OpenMAIC 를 실행하지 않았다. 생성물의 품질, 지연, 비용은 모른다.
- `pi-agent-core` 내부의 턴 상한은 보지 못했다(node_modules 없음).
- `@openmaic/storage` 문서 쓰기에 조건부 쓰기가 없다는 것은 보고에만 있다.
- §4.4 의 태그 감싸기가 `author` 출력에 주는 효과는 재지 않았다.
- 논문(JCST'26, doi 10.1007/s11390-025-6000-0)은 읽지 않았다.
