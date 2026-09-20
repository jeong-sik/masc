---
status: reference
---

# MASC Glossary

이 문서는 현재 코드와 운영 표면에 존재하는 용어만 정의한다.

## Core

**MASC**
: 다중 에이전트의 Board, Task, Goal, Schedule, Keeper와 도구 실행을 조율하는
  OCaml/Eio 서버.

**Workspace**
: 에이전트와 협업 상태가 공유되는 조율 범위.

**Agent**
: Workspace에 참여해 typed capability를 호출하는 실행 주체.

**Keeper**
: 독립된 agent core checkpoint와 MASC lifecycle을 가진 장기 실행 Agent. 현재 typed
  event와 tool schema를 관찰하고 자율 turn을 실행한다.

**Keeper Cycle**
: 현재 상태와 event를 관찰하고 Keeper turn 실행 여부를 결정하는 서버 loop의
  한 회차. 모든 cycle이 모델 호출을 실행하지는 않는다.

**Keeper Turn**
: 하나의 Keeper 작업 시도를 위해 MASC가 agent core Agent run을 실행하는 단위.

**Checkpoint Load**
: 저장된 Keeper 이력을 읽는 단계. 파일 없음은 새 이력을 뜻하지만 읽기·파싱 오류는
  새 이력을 허용하지 않는다. 명시적인 checkpoint 버전 교체만 기존 파일을 남겨 두고
  새 이력을 시작하며, 첫 저장이 받아들여진 뒤 재시작을 기록한다.

**agent core Turn**
: 하나의 agent core Agent run 내부에서 provider response와 tool 실행이 진행되는 한
  단계. Keeper turn과 동일한 단위가 아니다.

**Runtime Attempt**
: Keeper turn에서 하나의 resolved runtime 후보를 실행하는 시도.

**Parallel Tool Calls**
: 모델 응답 하나에 여러 도구 호출이 들어오는 것. 모델의 지원 여부는 카탈로그의
  `supports_parallel_tool_calls`, 실행별 억제는 runtime binding의
  `disable-parallel-tool-use`가 정한다. 억제 요청을 받아들이는 provider 계약은
  provider catalog의 `supports_parallel_tool_suppression`이며, 미선언이면 억제를
  요청할 수 없다. 이 요청 정책은 도구를 실행할 때의 동시성이나
  spawn으로 시작한 별도 에이전트의 동시 실행과 다르다.

## Collaboration State

**Board**
: 공유 발견, 질문, 답변, 의견과 결정을 게시하는 durable 협업 표면.

**Task**
: 실제 작업의 소유권과 검증 상태를 기록하는 단위. 상태는 `Todo`, `Claimed`,
  `InProgress`, `AwaitingVerification`, `Done`, `Cancelled`다.

**Goal**
: 장기 의도와 Task 연결을 기록하는 단위. phase는 `Executing`, `Verifying`,
  `Awaiting_confirmation`, `Completed`, `Dropped`다. 완료를 요청하면
  `Verifying`으로 들어가고, verifier가 증명을 통과시킨 뒤 사람이 확인해야
  `Completed`가 된다(`lib/goal/goal_phase.mli`).

**Schedule**
: 미래 시점에 Keeper를 깨우는 durable 요청. 현재 동작은 create, list, get,
  cancel이다. Schedule은 이후 외부 효과를 자동 승인하지 않는다.

**Fusion**
: 여러 독립 판단을 비동기로 수집하고 하나의 결론으로 합성하는 실행.

**Gate**
: 외부 효과를 Always Allowed, Auto Judge, HITL 중 설정된 정책으로 판정하는
  경계. pending 판정은 다른 작업을 막지 않는다.

## Task Lifecycle

**Created By**
: Task 를 만든 에이전트나 사람의 이름(`created_by`). 만들 때 한 번 적히고 바뀌지 않는다.
  Keeper 는 자기가 만든 `Todo` 를 자동 claim 대상에서 뺀다.

**Assignee**
: `Claimed`, `InProgress`, `AwaitingVerification` 에 적힌 에이전트 이름. 앞의 둘에서는
  지금 일을 맡은 쪽이고, `AwaitingVerification` 에서는 제출한 쪽이다.

**Producer**
: 판정 쪽 코드가 제출한 에이전트를 부르는 이름. 같은 에이전트가 상태에서는 `assignee`,
  verification 레코드에서는 `worker` 로 적힌다.

**Claim**
: `Todo` 인 Task 를 맡는 전이. 한 에이전트는 `Claimed` 와 `InProgress` 를 합쳐 하나만
  가질 수 있고, 이 검사는 claim 할 때만 한다. Keeper 의 claim 은 곧바로 Start 를 이어
  보낸다.

**Release**
: 맡은 쪽이 Task 를 `Todo` 로 돌려놓는 전이. Handoff Context 를 남긴다.

**Submission**
: 맡은 쪽이 증거와 함께 완료를 내는 전이(`Submit_for_verification`). 상태는
  `AwaitingVerification` 이 되고 새 Verification ID 를 받는다. 판정을 기다리는 Task 는
  claim 한도에 세지 않는다. Producer 는 기다리는 중에 다시 낼 수 있고 그때마다 id 가
  바뀐다.

**Intent**
: 판정을 기다리는 것이 완료 제출(`Complete_task`)인지 취소 요청(`Cancel_task`)인지. 맡은
  쪽의 cancel 은 취소 요청이 된다. `Todo` 의 cancel 은 요청 없이 바로 `Cancelled` 다.

**Verification ID**
: 제출 하나의 식별자. 판정은 자기가 읽은 id 가 지금 id 와 같을 때만 적용된다.

**Completion Authority**
: 판정을 내리는 쪽. 서버 안의 판정 에이전트(`System_llm_agent`)이거나 인증된 HTTP
  경로로 들어온 운영자(`Human_operator`)다. Keeper 는 판정하지 못한다. 취소 요청은
  운영자만 승인한다.

**Verdict**
: `Verdict_approved` 또는 `Verdict_rejected { reason }`. 완료 제출의 승인은 `Done`, 취소
  요청의 승인은 `Cancelled`, 반려는 어느 쪽이든 Producer 의 `InProgress` 다.

**Handoff Context**
: Task 에 붙어 다니는 인계 메모. summary, reason, next_step, evidence_refs, updated_by
  를 담는다. Release, Submission, cancel 이 쓰고 Claim 과 Start 는 지우지 않는다. 반려
  판정은 이 메모를 판정 사유로 덮어쓴다.

**Evidence Reference**
: 제출에 다는 증거 참조. `artifact:`, `note:`, `board:`, `fusion:` 네 형식만 열린다.

**Operator Attention**
: 운영자만 풀 수 있는 Task 의 목록(`Operator_task_attention.item`). 종류는 `Cancel_claim`,
  `Held_without_actor`, `Producer_record_unreadable` 이다.

**Current Task**
: 에이전트 기록의 `current_task`, Keeper meta 의 `current_task_id`, planning 의 current
  task. 기준은 backlog 이고 이 셋은 거기서 다시 계산되는 표시다.

## Skills

**Skill**
: 선언된 source의 `<package>/SKILL.md`로 발행하는 재사용 지식 또는 도구 합성.
  Memory OS의 Fact와 별개다. `validated_approach`나 `lesson`을 기억했다고 Skill이
  생성되지는 않는다. 현재 발행·사용 경로는 [Skills](../SKILLS.md)를 따른다.

**Instruction Skill**
: Keeper가 `keeper_skill`로 본문과 참조 파일을 읽고 적용할 방법을 판단하는 Skill.
  본문을 읽었다는 사실은 그 절차를 실행했거나 성공했다는 증거가 아니다.

**Composition Skill**
: 본문의 `toml composition` fence가 도구 노드와 입력 연결을 선언하는 Skill.
  검증된 계획이 `keeper_compose_<name>` 도구가 된다. 실행기는 선언된 입력과
  의존 관계를 따르며, 노드 사이의 새 모델 판단을 대신하지 않는다. 필요한 노드
  도구가 Keeper의 현재 표면에 없으면 합성 도구도 그 턴에 제공하지 않는다.

**Skill Reference**
: source, package, name으로 이뤄진 신원과 content revision의 조합
  (`Skill_reference.t`). 이름 하나가 아닌 이 참조로 읽을 내용을 지정한다.

**Skill Snapshot**
: `Skill_catalog_snapshot_service`가 발행한 source 관측과 원문 bytes의 불변 묶음.
  Keeper는 턴 경계에서 고정한 snapshot으로 Skill을 선택한다. 원문이 바뀌어도
  이미 시작한 턴의 참조를 새 내용으로 바꾸지 않는다.

**Skill Activation**
: 정확한 Skill 참조의 본문·리소스 읽기 또는 합성 호출을 기록한 사건.
  `Keeper_skill_activation_ledger`는 결과 전달(`delivery`)과 이후 모델이 고른
  도구 호출(`actions`)을 별도로 붙인다. 이후 호출이 있다는 사실만으로 Skill이
  그 행동의 원인이었거나 작업을 성공시켰다고 판정하지 않는다.

## Repository Execution

**Repository Catalog**
: repository ID, remote URL, default branch를 소유하는 identity SSOT.

**Repository Checkout**
: Keeper가 실제로 읽고 수정할 수 있는 Git checkout. Catalog 등록만으로
  checkout 존재를 보장하지 않는다.

**Checkout Freshness**
: checkout HEAD와 명시된 local tracking ref의 ahead/behind 관계. 이 값은
  네트워크 fetch 시각이 아니라 로컬 tracking ref를 기준으로 한다.

**Sandbox**
: Keeper tool이 접근할 수 있는 writable filesystem 경계. 도구에는 반환된
  sandbox-relative path를 사용한다.

**Worktree**
: 한 repository 안에서 branch 작업을 격리하는 Git worktree.

## Continuity

**Checkpoint**
: agent core conversation과 Keeper working context의 durable 저장점. trace당 파일
  하나(`<trace 디렉터리>/<trace id>.json`)다.

**History**
: Checkpoint의 `messages`. 그 trace에서 오간 message가 시간순으로 쌓인 목록이다.
  Keeper turn은 이 목록 끝에 message를 덧붙인다. 목록 안에는 어느 message가 어느
  Keeper turn의 것인지 표시가 없다.
  운영자의 `masc_keeper_clear`는 Keeper Owner의 배타적 유지보수 구간에서 비운다.
  진행 중인 turn이 있으면 거절하며, paused Keeper는 다시 실행하지 않고 비울 수 있다.

**Message**
: History의 한 항목. role(`System`, `User`, `Assistant`, `Tool`) 하나와 content
  조각(`Text`, `Thinking`, `ToolUse`, `ToolResult`, `Image`)의 목록으로 이뤄진다.

**Atom**
: History를 자를 때 쓰는 가장 작은 단위. `User` message 하나, 또는 `Assistant`
  message 하나와 그것에 답한 `Tool` message들이다. 따로 저장되지 않고 History를
  앞에서부터 세면 나온다(`Runtime_model_input_tail_window`). tool 호출과 결과가
  갈라지면 provider가 요청을 거절하므로 자르는 자리는 Atom 경계에만 온다. Atom의
  크기는 고르지 않아서 Atom 개수는 위치를 말할 뿐 요청 크기를 말하지 않는다.

**Carried Front (실어 보낼 이력의 시작 위치)**
: 요청에 실리는 가장 오래된 Atom의 번호와 그 Atom을 여는 Message의 digest.
  후보별 usage 원장에서 읽되, 같은 Keeper turn의 거절이 더 뒤로 옮긴 위치가 있으면
  그 위치를 쓴다. 반 자르기와 묶음 비우기 모두 다음 후보로 이 위치를 전달한다.
  다른 History의 위치는 digest가 맞지 않으므로 쓰지 않는다.

**Model Input Ledger (모델 입력 원장)**
: Keeper·runtime·trace별로 공급자 usage와 실린 Atom 범위를 기록한 프로세스 내 원장.
  원장이 아직 세지 않은 위치까지 거절이 앞을 옮길 수 있다. 이때 다음 요청은 턴이
  보관한 Carried Front를 쓰고, 공급자 응답이 온 뒤 원장을 갱신한다.

**Turn Boundary**
: 끝난 Keeper turn이 남기는 한 줄(`<keeper>.turn-boundaries.jsonl`). 그 turn이
  끝났을 때 저장된 History가 몇 Atom인지와 마지막 Atom의 digest를 적는다.
  History 안에는 turn의 경계가 없으므로, turn이라는 사건을 History 안의 위치로
  옮겨 적는 유일한 기록이다. turn이 Atom이 없는 History에서 시작했는지
  (`fresh`/`continued`)도 같이 적는다. Checkpoint 파일이 있었는지가 아니라 Atom이
  있었는지로 정한다. Keeper는 빈 Checkpoint를 갖고 만들어지기 때문이다. 읽는 쪽은
  줄이 파일에 쌓인 순서가 아니라 Atom 수로 줄을 세운다.
  같은 파일에 `history_restarted` 줄도 쌓인다. "이 trace의 Atom 번호가 이 줄부터
  0에서 다시 시작한다"를 말하는 줄이고, History를 다시 시작하게 만든 쪽이 쓴다.
  `masc_keeper_clear`는 비운 Checkpoint가 저장된 뒤에 쓴다. Atom이 없는 History에서
  시작하는 turn은, 저장된 History에 Atom이 없는 것을 알면 시작할 때 쓰고,
  Checkpoint를 못 읽어서 모르면 처음 받아들여진 저장 뒤에 쓴다. 읽는 쪽은 이 줄을
  보는 즉시 0부터 읽어도 되므로, 어느 쪽도 다시 시작하기 전에 쓰지 않는다. `fresh`
  줄과 `history_restarted` 줄은 읽는 쪽에 같은 말을 한다.

**Read Position**
: Librarian이 History를 어디까지 읽었는지 적은 값(`<keeper>.librarian-progress.json`).
  Turn Boundary 파일의 줄 번호가 아니라 값이다: trace, 읽은 Atom 수, 마지막으로
  읽은 Atom을 여는 Message의 digest. 그 파일에는 지난 History의 줄도 남아 있어서
  줄 번호로는 지금 History 안의 자리를 말할 수 없다. 파일이 없으면 아직 읽은 적이 없다는 뜻이다. 못
  읽는 파일은 "읽은 적 없음"으로 치지 않고 오류로 다룬다. 그렇게 치면 History
  전체가 안 읽은 것으로 보인다.

**Generation**
: 같은 Keeper가 새 trace로 이어진 횟수. 초기값은 0이다.

**Trace ID**
: 현재 Keeper generation의 실행 식별자. Checkpoint의 `session_id` 필드와
  `Turn_ref`의 trace id가 이 값이다.

**Memory OS**
: Keeper의 durable personal facts와 recall을 소유하는 typed memory store.

**Fact**
: Memory OS의 기억 하나. 문장(`claim`), `category`, 처음·마지막으로 본 시각,
  `origin`, `basis`로 이뤄진다. id 필드는 없고 Memory ID는 `claim` 글자의
  SHA-256이다. 글자가 하나라도 다르면 다른 Fact다.

**Origin**
: Fact를 누가 적었나. `authored`는 Keeper가 `memory_write`로 직접 적은 것,
  `injected`는 Librarian이 대화에서 뽑아 넣은 것이다.

**Basis**
: Fact가 무엇에 근거하나. `observed`는 읽은 곳(자기 대화 또는 Board 글)을 갖고,
  `derived`는 근거가 된 다른 Fact의 Memory ID를 갖는다. 근거가 사라지면 `derived`
  Fact도 무효가 된다.

**Dropped / Supersedes / Absorbs**
: Librarian이 기억을 바꾸는 세 가지 말. `dropped`는 이유를 적고 버린다.
  `supersedes`는 옛 Fact 하나를 새 claim 하나로 고쳐 쓰며(1:1) 옛 id는 `dropped`
  에도 있어야 한다. `absorbs`는 Fact 여러 개를 새 claim 하나가 대신 말하며(N:1)
  그 id들은 `dropped`에 없어야 한다. 흡수된 원문은
  `<keeper>.memory-absorbed.jsonl`에 남는다. Librarian이 말하지 않은 Fact는
  그대로 남고, 규칙을 어긴 답은 통째로 거절된다.

**Memory Event**
: Fact에 일어난 일의 기록(`<keeper>.memory-events.jsonl`). `retrieved`는
  `keeper_memory_search` 결과에 나온 것, `revised`는 `supersedes`로 고쳐 써진
  것이다. `cited`는 Keeper가 `keeper_memory_retract`로 그 Fact를 id로 지목해
  철회한 것이다. 기록하는 곳이 그 하나뿐이라 살아 있는 Fact의 `cited`는 0이다.

**Librarian**
: Keeper마다 따로 도는 기억 정리자. Keeper의 History와 현재 facts를 읽고 LLM을
  한 번 불러, 더할 fact와 버릴 fact와 합칠 fact를 정해 Memory OS에 적는다. 같은
  호출에서 Keeper가 받은 요청을 묶어 working context로 정리한다. Keeper의 판단을
  대신하지 않는다.
