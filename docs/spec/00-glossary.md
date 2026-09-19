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

**agent core Turn**
: 하나의 agent core Agent run 내부에서 provider response와 tool 실행이 진행되는 한
  단계. Keeper turn과 동일한 단위가 아니다.

**Runtime Attempt**
: Keeper turn에서 하나의 resolved runtime 후보를 실행하는 시도.

## Collaboration State

**Board**
: 공유 발견, 질문, 답변, 의견과 결정을 게시하는 durable 협업 표면.

**Task**
: 실제 작업의 소유권과 검증 상태를 기록하는 단위. 상태는 `Todo`, `Claimed`,
  `InProgress`, `AwaitingVerification`, `Done`, `Cancelled`다.

**Goal**
: 장기 의도와 Task 연결을 기록하는 단위. phase는 `Executing`, `Blocked`,
  `Paused`, `Completed`, `Dropped`다.

**Schedule**
: 미래 시점에 Keeper를 깨우는 durable 요청. 현재 동작은 create, list, get,
  cancel이다. Schedule은 이후 외부 효과를 자동 승인하지 않는다.

**Fusion**
: 여러 독립 판단을 비동기로 수집하고 하나의 결론으로 합성하는 실행.

**Gate**
: 외부 효과를 Always Allowed, Auto Judge, HITL 중 설정된 정책으로 판정하는
  경계. pending 판정은 다른 작업을 막지 않는다.

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
