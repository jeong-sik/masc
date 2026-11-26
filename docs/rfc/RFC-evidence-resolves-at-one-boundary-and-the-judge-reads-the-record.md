# RFC evidence-resolves-at-one-boundary: 인용한 증거는 경계 하나에서 풀리고 판정은 그 기록만 읽는다

상태: 제안 (2026-11-26). 측정과 지난 작업의 지도는 이슈 #54918 에 있다. 설계는 새 문맥의 Opus 와 세 턴 반박과 초안 검토를 거쳐 정했다. 구현 PR: #54965(합계 상한에 밀린 artifact 를 기록에서 읽는다), #54981(긴 웹 페이지의 저장본을 리더로 읽고 검색한다).

## 0. 요약

- 검증자가 증거를 못 읽는 문제는 2026-05 부터 이슈 약 20건으로 따로 고쳐졌다. 매번 한 층에 덧붙였고, 같은 질문 「이 증거를 읽을 수 있는가」 를 지금 다섯 군데서 따로 정한다(§1.2).
- 정한다. Task 판정에서 참조는 경계 하나에서 모델 호출 전에 풀린다. 판정자의 입력은 읽힌 참조의 기록과 서사다. 판정자의 도구는 기록을 페이지로 읽는 리더 하나다.
- 읽기 실패의 주인이 제출자면 제출을 거절한다. 하네스 몫이면 모델을 부르지 않고 다시 읽고, 끝내 안 읽히면 운영자 목록에 싣는다. 판정자는 읽지 못한 참조를 보지 않는다.
- 참조의 경로 형태를 지운다. `artifact:` 는 하네스가 만든 sha256 만 받는다.
- 첫 층은 상한에 밀린 artifact 를 기록에서 읽게 하는 것이다. lookup 표면은 문법이 live 조회를 다 덮인 뒤 5층에서 지운다.
- Goal 판정은 7층과 별도 결정까지 두 층으로 남는다(§3.6).

## 1. 지금 값으로는 안 되는 이유

### 1.1 관찰 (2026-11-20~11-26)

출처는 `<base-path>/.masc/activity-events/2026-11/` 의 `task.submit_for_verification`·`task.approved`·`task.rejected` 사건과 `<base-path>/.masc/verification-runs.jsonl` 다. 집계 방법과 사본 위치는 #54918 에 적었다.

- 승인이 못 본 채로 나온다. 11-26 11:23Z 부근에 실행 기록 65건을 읽은 값으로, 승인 39건 중 12건이 자기 도구 결과에 로그인 벽을 만나고도 승인됐다. task-4031 의 승인은 「Actions 로그 상세는 sign-in 필요로 … 직접 확인하지 못했고」 라고 적었다. 실행 기록 파일는 끝난 판정 64건만 남는다(`lib/verification_run_registry.ml:159`). 같은 날 12:15Z 에 다시 세면 38건 중 11건이다.
- 판정 사건에는 승인 사유가 없다(`config/prompts/verification.md:37`). 실행 기록이 남은 승인에는 사유가 있다. 승인 175건 가운데 기록이 없는 검증자 승인은 131건이고 사람 승인이 6건이다. 그 131건은 읽었는지 알 수 없다.
- 거절의 주원인은 못 읽음이 아니다. 거절 89건을 사유 원문으로 나누면 읽기 실패만 7건, 읽은 것과 상충 4건, 일 미충족이거나 실행 증거를 내지 않음 56건, 혼합 18건, 계약 문구가 현실과 어긋남 4건이다. 읽기 실패가 원인인 것은 25건(28%) 까지다. 이 분류는 검증자가 쓴 사유 원문을 읽은 것이다. 실제와 대조한 것은 task-3891 한 건이고, 제출자가 미충족을 스스로 적은 24건은 뒷받침된다.
- Keeper 가 아닌 생산자의 거절 9건 중 생산자가 답한 것은 1건이다. 거절 사유는 Task 의 handoff 에 실린다(`lib/workspace/workspace_task.ml:487-508`). 생산자를 향한 표면은 없다. Task 는 「Any agent may claim this task」 로 `todo` 에 놓인다.
- Goal 판정 17건 중 `refuted` 5건 가운데 4건의 사유가 「읽을 수 없었다」 다. 네 건 모두 검증 제출 항목이 `[]` 였다. Goal 은 `refuted` 가 되면 `executing` 으로 돌아간다.
- 검증자가 실제로 연 것은 넓다. 실행 기록 65건의 web 조회 272건을 URL 종류로 나누면 PR 페이지 70여 건, run 페이지와 그 API 70여 건, raw 파일 47건, commit 과 check-runs·job 의 API 30여 건, PR reviews·files 의 API 37건, commit 페이지 9건이고 나머지는 contents·branches·workflow·issues·compare 같은 GitHub API 의 긴 꼬리다. 몇 건 단위의 나눔은 분류기마다 다르다. 로그인 벽은 run 페이지의 로그에서 났다.

### 1.2 같은 질문을 다섯 번 정한다

| 층 | 어디 | 무엇을 다시 정하나 |
|---|---|---|
| 제출 | `lib/verification_protocol.ml:126` `create_submit_request`, `Workspace_verification_store.snapshot_submitted_evidence*` | `artifact:` 와 board·fusion·task 만 푼다. URL 은 `note:` 안에 풀리지 않은 채 남는다 |
| 검증 시작 | `lib/verification_authority_tools.ml` `create_task_review`, `root_layout` | producer root 의 유무를 다시 정하고 lookup 문단 세 종류 중 하나를 프롬프트에 넣는다 |
| 검증 중 | `Read_file`·`Search_files`·`Web_fetch` | 판정자가 같은 증거를 다시 읽는다. 결과는 발췌만 남는다 |
| 프롬프트 | `config/prompts/verification.md:12` | 「스냅샷은 제출 시점, 조회 결과는 조회 시점의 상태입니다」. 둘이 다를 때를 LLM 에게 맡긴다. lookup 절과 posture 절이 그 차이를 설명한다 |
| 거절 뒤 | `lib/completion_authority_wakeup.ml:116`, `lib/workspace/workspace_task.ml:483` | lock 안에서 돌려갈 Keeper 가 있는지 다시 묻는다. 처분은 판정 행에 없다(`lib/types/types_core.ml:852`) |

그 위에 생산자 규약(2026-10-06, 실행 로그를 Board 글에 옮겨 적기)과 수동 우회가 있다. 로그인 벽은 코드로 못 넘으므로 우회는 규약이 된다.

### 1.3 기록이 설계부터 다 실리지 않는다

- 판정자 입력에 실리는 artifact 내용은 합계 200,000바이트다(`lib/workspace/workspace_verification_snapshot.ml:306`, `lib/tool_types/tool_shard_limits.ml:14-15`).
- 넘는 항목은 내용을 빼고 「read ranges of the actual file with the listed verification tools」 를 싣는다(`:252-261`, 320-328). live 조회가 그 빈자리를 메운다. 그래서 lookup 표면을 지우면 큰 증거를 볼 수 없다.
- 잘림 사유 거절 9건, 승인 제출의 잘린 항목 19개다(Opus 표지 집계).

### 1.4 경로 참조는 기준이 애매하다

- `artifact:<경로>` 는 producer root 기준으로 풀린다. Keeper 는 저장소 기준 경로를 낸다. #27552(2026-08-08, 아직 열림)의 `artifact_unreadable` 이 그 것이다. 「어느 root 인가」 는 샌드박스 profile 마다 다시 정해졌다(#31561, #33792, #35262, #45524, #45614).
- 2026-09-30 재검토는 「자동 path guess 로 해결하지 않는다」 고 적었다. 잘못된 경로를 지금 live Read 가 구해 준다(`workspace_verification_store.ml:209-215`).
- MCP 로 참여한 생산자의 root 는 `<base-path>/.masc/playground/<agent>/` 다. 그 디렉터리를 만드는 곳이 없고 도구 설명은 경로를 알려 주지 않는다(#35262). Worker 역할은 `masc_start` 도 거절된다.
- 같은 참조 문법을 Goal 측정(`lib/goal/goal_measurement.ml:48-62`)과 운영자 증거 내려받기(`lib/workspace/workspace_verification_operator_evidence.ml:134`)도 쓴다.

### 1.5 제출 정책이 다섯 개다

| 입력 | 지금 | 어디 |
|---|---|---|
| 참조 형태 오류 | 거절 | `lib/task/tool_task_args.ml:189-203` |
| board·fusion capture 실패 | 거절 | #35536 |
| producer meta 를 못 읽음 | 거절 | #38583, `lib/verification_protocol.ml:144-176` |
| artifact 없음·잘림 | 기록하고 판정자에게 | `:106-124` |
| URL | 참조가 아니다. 「note 로 감싸라」 | `lib/task/tool_task_args.ml:194`, `lib/keeper/keeper_tool_task_runtime.ml:276-281` |

## 2. 결정

### D1. 참조는 경계 하나에서 모델 호출 전에 풀린다

- 경계는 `Verification_protocol.create_submit_request` 하나다. 들어오는 길은 둘이다. Keeper 의 `keeper_task_done` 과 MCP 의 `masc_transition submit_for_verification` 다. Goal 의 증명 요청은 7층에서 같은 resolver 를 부른다.
- 입력은 생산자가 낸 참조 목록이다. 모두 `classify_evidence_reference` 하나로 가른다.
- 출력은 기록이다. 참조 하나가 `Read` 아니면 `Unreadable` 이다. 모델을 부르기 전에 정해지고 요청과 함께 영속된다(`docs/constitution.xml` 의 `persist_before_model_call`).

```ocaml
type source = Artifact | Collaboration of collaboration_kind | External

type item =
  | Note of string
  | Read of
      { source : source
      ; reference : string
      ; bytes : int
      ; sha256 : string
      ; captured_at : string
      ; provenance : provenance }
  | Unreadable of { source : source; reference : string; reason : unreadable }
```

- 영속 모양은 hard cut 이다. decoder 는 모르는 필드를 거절하고 기존 생성자의 필드 목록이 정해져 있다(`lib/workspace/workspace_verification_snapshot.ml:496-607`). 유일한 선택 필드는 `artifact_binary` 의 `body` 다. 그래서 기존 생성자의 모양을 바꾸면 옛 요청 기록 4,000여 개는 읽히지 않는다. 옛 모양의 reader 도 converter 도 만들지 않는다. 옛 요청의 증거는 이미 있는 typed 갈래인 `Evidence_unavailable` 로 읽힌다. 배포 전에 판정을 기다리는 요청을 비운다.
- 본문은 blob 하나다. 판정자 입력에 실는지는 입력을 만들 때 정하고 저장 상태가 아니다. 합계 예산 안에 드는 것만 실고 나머지는 리더로 읽는다(D4). 잘림이란 상태가 없다.
- 기존 board·fusion·task 캡처(#35536)가 이 모양의 앞부분이다. 그 코드를 넓힌다.

### D2. 참조의 문자열 형태

| 형태 | 뜻 |
|---|---|
| `artifact:sha256:<64 hex>` | blob store 의 주소. export 나 `masc_evidence_put` 이 돌려준 그대로 |
| `board:<post-id>` · `fusion:<run-id>` · `task:<task-id>` | 지금과 같다 |
| `gh:<github url>` | 첫 버전에서 받는 것: pull request(상태·reviews·files), commit(check-run 포함), compare, workflow run(모든 job 의 결론·step 결론·로그), job 로그, 고정 ref 의 파일과 디렉터리 목록 |
| `note:<text>` | 서사. 확인할 주장이지 증거가 아니다 |

- `gh:` 의 URL 은 경계에서 typed locator 로 파싱된다. 파싱이 안 되면 `Invalid_reference` 다. pull request 의 선례는 PR #28995 의 `parse_pull_request_url` 이다.
- run 은 모든 job 의 로그를 담는다. 통과 영수증도 증거다. 실패한 step 만 남기지 않는다. run 의 artifact 는 첫 버전에서 목록만 담는다.
- 문법은 재어서 넓힌다. 종류는 §1.1 의 live 조회 집계에서 온다. 5층에서 `Web_fetch` 를 지우기 전에 2주간의 live 조회 성공 건수를 종류로 세어 문법이 덮지 않는 것이 0건인지 본다.
- 나머지 URL 은 참조가 아니다. note 안의 URL 을 전부 참조로 바꾸면 언급만 된 링크까지 제출 조건이 된다.

### D3. 읽기 실패의 주인이 정책을 정한다

```ocaml
type owner = Submitter | Harness

type unreadable =
  (* Submitter *)
  | Invalid_reference                         (* 형태가 아니다 *)
  | Source_not_found                          (* 없는 board·fusion·task·GitHub 객체 *)
  | Source_access_denied                      (* 생산자가 읽을 수 없는 글 *)
  | Not_public                                (* 비공개 저장소 *)
  | Blob_absent                               (* 지워진 export *)
  | Not_yet_available of { detail : string }  (* 실행이 끝나지 않았다 *)
  | Too_large of { bytes : int; cap : int }
  (* Harness *)
  | Storage_failed of string                  (* 원장이나 저장소를 못 읽는다 *)
  | Forbidden                                 (* 공개 저장소에 403: 자격의 범위 *)
  | Reader_unavailable of string
  | Rate_limited of { reset_at : string }
  | Transport_failed of string
  | Timeout

val owner_of_reason : unreadable -> owner
```

- `owner` 는 `reason` 에서 정해지는 파생값이다. 따로 저장하지 않는다.
- 공개 여부는 인증된 요청의 응답 코드로 가르지 않는다. 같은 현실이 404 냐 403 이냐에 따라 주인이 갈리면 같은 질문이 두 번 정해진다. resolver 는 요청 앞에서 저장소의 공개 여부를 따로 읽어 비공개면 `Not_public` 으로 적는다. 공개 저장소의 404 는 `Source_not_found`(제출자)이고 403 은 `Forbidden`(하네스)이다.
- `Submitter` 소유가 하나라도 있으면 요청은 만들어지지 않는다. 제출 도구는 참조와 사유 목록을 돌려주고 Task 의 상태는 그대로다. 판정 행도 검증 요청 행도 생기지 않는다. 이것은 완료 전이가 아니라 요청 형태 오류와 같은 급이다.
- `Harness` 소유면 요청은 기록되고 모델을 부르지 않는다. 검증 준비에서 그 항목만 같은 resolver 로 다시 읽는다. `Rate_limited` 는 `reset_at` 까지 기다린다. 읽히면 그 자리에서 `Unreadable` 을 `Read` 로 바꾼다. 덧붙이지 않는다. 못 읽은 항목이 남으면 original 을 보존하지 않고 준비 단계에서 보류한다. 다 읽히면 original 을 보존하고 그 때 `create_task_review` 가 요청 파일에서 질문을 계산한다(`lib/verification_authority_tools.ml:807-813`). 제출 때 계산하지 않는다. 기록은 그 뒤에 바뀌지 않는다. maintenance pulse 마다 다시 시도하고 끝내 안 읽히면 판정 없이 멈춘 것으로 운영자 목록에 싣는다(L2b, `docs/rfc/RFC-a-stalled-handoff-reaches-the-one-who-can-move-it.md:455`). 지금 있는 보류 기계를 쓰고 새 상태를 만들지 않는다.
- 판정자는 `Unreadable` 을 보지 않는다. 판정자의 입력은 `Read` 와 `Note` 다.
- 이 정책이 §1.5 의 다섯을 하나로 맞춘다. 제출을 거절하는 경우는 `Submitter` 소유뿐이다. board·fusion capture 실패의 사유(`lib/verification_collaboration_evidence.ml:5-7`)도 같은 규칙으로 갈린다. 없는 글과 읽을 수 없는 글은 제출자 몫이고 저장고 장애는 하네스 몫이다. #38583 의 meta 거절은 D5 가 지운다. artifact 없음은 없는 blob 이 되어 거절이고 잘림은 없어진다.
- 이 정책은 이전 기록 넷과 다르다. #44713(2026-10-21) 은 artifact 에 게이트를 두지 않았다. `docs/RELIABLE-CHANGE-ROADMAP.md:67`·119·122 의 경계 suite 문구는 기록을 적었다. RFC-0222 는 「빠지거나 실패한 증거는 그 판단의 입력」 이라고 적었다. 이 정책은 그 입력을 판정자에게 넘기지 않는다. LLM 이 판정한다는 것은 그대로다. 헌법 `<gates>` 의 `<order>` 는 게이트 추가를 success_bar 뒤로 붙잡는다(`docs/constitution.xml:526`). 운영자가 2026-11-26 에 이 정책을 골랐다(§6).

### D4. 판정자는 기록만 읽는다

- 판정자의 입력은 Task, 계약, 기록이다. 판정자의 도구는 기록 리더 하나다. #35536 의 sha 고정 페이지 읽기(`lib/verification_collaboration_evidence.ml:54-93`)를 blob 본문으로 넓히고 검색을 더한다. 리더는 읽은 범위를 typed 로 돌려주고 판정 행에 `evidence_reads` 로 남는다. 5층 전까지는 live 조회도 같이 센다(`lib/task/anti_rationalization.ml:822-832`).
- 5층에서 지운다. Task 검토의 `Read_file`·`Search_files`·`Web_fetch`, `root_layout`(`lib/verification_authority_tools.ml:341-369`), 권한 binding(752-833), `config/prompts/verification.md` 의 lookup 절 세 개와 posture 절 두 개, 12행과 14행의 조회 규정. 36행의 「확인할 수 없는 요구 항목이 남았을 때」 는 남는다. 계약 항목에 인용이 없는 경우가 그 경우다.
- L2d(#51801) 의 권한 절반은 필요 없어진다. 되돌리는 것이 아니다. 다음 시도는 같은 질문을 조회 권한이 아니라 기록을 기준으로 묻는다.
- 미디어 검사(pdf·presentation·mp4)는 live 샌드박스 대신 blob 본문에서 읽는다. 이미지는 이미 그렇다(`lib/workspace/workspace_verification_store.ml:290-321`). Task 조회 표면의 호출자는 하나다(`lib/completion_authority_agent.ml:1128`).
- 2026-10-06 규약 중 CI 로그를 Board 글에 옮겨 적는 부분은 D2 의 `gh:` 가 대신한다.

### D5. 참조는 하네스가 만든다

- `keeper_artifact_transfer export` 가 파일을 읽어 sha256 으로 blob store 에 넣는다(`lib/keeper/keeper_peer_artifact.ml:138-168`). store 는 sha256 을 대조하고 그 밖에 아무것도 싣지 않는다(`lib/keeper/keeper_peer_artifact.mli:22-24`). export 의 결과에 그대로 복사할 `artifact:sha256:<hex>` 를 실어 준다.
- MCP 세션에는 blob 에 넣는 수단이 없다. `masc_file_upload` 는 공급자 Files API 용 이미지 도구다. `masc_evidence_put` 을 더한다. 호출에 바이트를 실으면 export 와 같은 영수증을 돌려준다. 경로를 받아 서버가 읽는 모양은 쓰지 않는다. 세션 파일은 bundle root 밖에 있어 path jail 을 깨거나 터널 클라이언트에서 성립하지 않는다.
- 요청 기록이 살아 있는 동안 blob 이 살아 있어야 한다. blob GC 는 참조를 세지 않는다(`lib/keeper/keeper_peer_artifact.mli:8-11`).
- 지운다. `artifact:` 의 경로 형태, `valid_producer_relative_path`, `Keeper_tool_task_runtime.evidence_artifact_reader`, `host_root_abs_of_producer`, checkout 접두어 안내(#44713). 생산 호출처는 증거 쪽 두 곳뿐이다. 참조 문법이 한 곳이므로 Goal 측정과 운영자 증거 내려받기가 같이 따라간다. #27552 가 닫힌다. #35262 가 남긴 「생산자에게 root 경로를 알려 주는 후속」 은 증거에 root 가 없어지면서 필요 없어진다.

### D6. 거절의 처분은 판정과 같은 쓰기에서 정한다

- 판정 커밋에서 producer 의 Keeper meta 를 한 번 읽어 처분을 판정 행에 적는다. `To_keeper_queue of string` 또는 `To_session of string` 이고 책임자를 함께 적는다.
- 전달은 그 뒤의 이펙트다. Keeper 는 queue 로 간다. 세션의 Task 는 지금처럼 `todo` 로 바로 풀려 누구나 잡을 수 있다. 돌아오지 않는 세션의 Task 가 붙박이가 되지 않게 하는 것이다. 판정 행의 책임자는 그 세션의 agent 다. 세션이 돌아오지 않으면 Task 생성자가, 생성자도 없으면 운영자가 맡는다(`docs/RELIABLE-CHANGE-ROADMAP.md:123`). 그 agent 의 미답변 거절은 판정 행에서 projection 으로 `masc_status` 와 `masc_tasks` 에 보인다. 가시성은 projection 이다.
- 지운다. `still_unroutable`, `Producer_became_routable`, `Producer_route_unread`. lock 안의 재질문은 다른 결정이 아니라 경쟁 검사였고, 판정 커밋에서 한 번 읽으면 필요 없다.

### D7. GitHub 객체는 store 밖에서 읽는다

- `External` 은 store 에 불투명한 참조와 범용 전송 사유로만 남는다. URL 문법과 reader 는 `Verification_collaboration_evidence` 옆에 두고 composition root 에서 설치한다.
- 이것이 PR #28995 철회(2026-08-18)의 사유에 대한 답이다. 철회는 「workspace store 에 GitHub 모양 타입과 URL 파서를 1급 개념으로 박았다」 는 결합이었다(#24332). 「PR 은 capture 하지 않는다」 는 문장은 없고, 역할은 운영자가 2026-10-06 에 바꿨다. 인용된 GitHub 객체에 한해 #29001 의 기제를 다시 연다. LLM 판정(RFC-0222)과 코어의 제품 의미 금지는 그대로다.
- 서버가 typed 값으로 API URL 을 조립한다. 생산자가 준 URL 에 인증을 붙이지 않는다. 자격은 `[repositories] pr_reader` 다. reader 는 `lib/server/server_github_run_reader.ml` 의 것을 넓힌다.
- 로그와 artifact 는 302 로 간다. `Location` 의 host 를 허용 목록으로 걸러 Authorization 없이 다시 읽는다.
- 첫 버전은 공개 저장소만 읽는다. 등록만으로는 안 된다. `wkbl` 은 등록된 비공개 저장소다(task-3780·3817·3909 의 404). 공개 여부는 등록 항목에 적히지 않는다. resolver 가 인증 없이 저장소 메타를 한 번 읽어 정한다. 비공개 저장소의 `gh:` 인용은 `Not_public` 로 제출에서 거절된다. 그 저장소의 Keeper 는 `board:` 를 쓴다. 항목에 `visibility` 를 두되 첫 버전에는 `Public` 만 있다.
- 기록에 `{ reader; token_digest; fetched_at; http_status; sha256 }` 를 남긴다. resolver 에 총 시간 상한을 두고 넘으면 `Timeout` 이다.

## 3. 고르지 않은 길

### 3.1 검증자의 web fetch 에 인증만 실은다

store 를 바꾸지 않아도 되고 2026-08 의 철회와 충돌하지 않는다. 그러나 판정자가 로그를 직접 열어 비교해야 하므로 §1.2 의 세 번째와 네 번째 층이 남는다. 승인 39건 중 12건이 그 층에서 났다.

### 3.2 판정에 셋째 값을 더한다

`Unverified` 를 더하면 「읽지 못함」 과 「거짓」 이 갈라진다. RFC-0279(2026-07-13) 는 완료 결과의 타입 계층을 「휴리스틱 계층을 타입으로 굳히면 잘못된 권위를 지킨다」 고 철회했다. D3 의 `owner` 는 판정 값이 아니라 사유의 성격이다.

### 3.3 승인에 항목마다 근거를 의무로 요구한다

RFC-0224(2026-07-13) 는 같은 모양의 체크리스트를 「빠뜨림은 기계적으로 보이지만 진실은 세우지 못한다」 고 철회했다. 모델이 눈앞의 사실을 쓰게 만드는 게이트 아닌 수단은 없다. 되는 것은 입력의 완전성(D3) 과 읽은 페이지의 기록(D4) 이다.

### 3.4 계약 문구에서 참조를 긁어온다

계약의 `required_evidence` 는 자유 문자열이다. 거기서 `task:` 를 찾는 것은 문자열 비교로 로직을 정하는 것이다. 계약이 source 를 묶으려면 제출자가 그 참조를 내야 한다. typed 계약 source 필드는 Task 레코드의 모양을 바꾸는 일이라 따로 묻는다.

### 3.5 증거 하한을 되살린다

#25911(2026-09-25) 은 빈 `evidence_refs` 도 판정자가 본다고 정했다. 빈 목록은 그대로 제출된다. 판정자는 사실 0개를 보고 판정한다.

### 3.6 Goal 의 공유 playground 조회를 지운다

#45637(2026-10-24) 이 그 조회 권한을 묶었다. 지우는 것은 되돌림이므로 7층에서 따로 묻는다.

### 3.7 하네스 몫 실패를 판정자에게 넘긴다

`Unreadable` 을 판정자에게 보이면 「읽지 못해 REJECT」 가 남는다. `Rate_limited` 는 `reset_at` 전에 다시 읽혀 실패하고 `Forbidden`·`Reader_unavailable` 은 매회 실패한다. 그 REJECT 은 제출자에게 간다. 판정 없이 멈추고 운영자 목록에 싣는 선례는 `docs/RELIABLE-CHANGE-ROADMAP.md:120` 의 「판정 없음」 이다.

### 3.8 문법이 덮기 전에 `Web_fetch` 를 지운다

검증자가 읽는 것의 절반가량이 raw 파일·check-runs·PR reviews 같은 긴 꼬리다. 문법이 그것을 덮기 전에 지우면 퇴행이다.

## 4. 층

1층부터 4층까지는 하나의 stack 이다. 5층은 4층 배포 뒤 2주 측정이 끝나야 올라온다. 공존 구간이 지금의 병이므로 5층에서 lookup 표면을 한 번에 지운다.

| 층 | 더하는 것 | 지우는 것 | 재는 것 |
|---|---|---|---|
| 1 기록 리더 | 합계 상한에 밀린 artifact 를 기록에서 읽는다. 긴 웹 페이지의 저장본을 리더로 읽고 검색한다. 판정자 표면 자기의 `masc_web_fetch` 가 돌려준 sha256 만 읽는다. 판정 사건의 `evidence_reads`(기록 읽기와 live 조회). 지금은 도구 관측이 64건만 남는 실행 기록에만 있다 | 「read ranges of the actual file」 문구(`lib/workspace/workspace_verification_snapshot.ml:308-329`) | 읽은 페이지가 판정 사건에 남은 판정의 비율 |
| 2 `truncated` 삭제 | 텍스트 본문을 통째로 blob 으로 두고 리더로 읽는다 | `truncated`, `warn_oversized_evidence`(`lib/verification_protocol.ml:106-124`), posture 절 | 잘림 사유 거절 9건, 잘린 항목을 가진 승인 19건 |
| 3 sha256 참조 | `artifact:sha256:` 와 export 결과의 참조, `masc_evidence_put`, 기록의 blob 붙잡기 | checkout 접두어 안내 | 경로 사유 거절. #27552 |
| 4 경계 하나 | resolver 하나, `Unreadable(reason)`, `Submitter` 거절, Harness 보류와 운영자 목록, `gh:`(공개 저장소) | 정책 다섯을 하나로. #38583 의 meta 거절. `evidence_capture` 진단(`lib/task/tool_task.ml:268`). 「note 로 감싸라」 두 곳을 `gh:` 안내로 | 제출에서 거절한 건수(사유별). 운영자 목록에 오른 Harness 멈춤. 문법이 덮지 않은 live 조회 건수 |
| 5 lookup 표면 삭제 | 문법을 재어 넓힌다. 미디어 검사를 blob 본문으로 | `Read_file`·`Search_files`·`Web_fetch`·`root_layout`·권한 binding, 경로 형태와 root 계산 모임, lookup 절 | 지우기 전 2주간의 live 조회 성공 건수 가운데 문법이 덮지 않는 것 0건 |
| 6 거절 처분 | 판정 행의 처분과 책임자. 세션 미답변 거절의 projection | `still_unroutable` 과 그 종류 | Keeper 아닌 생산자 거절의 응답률 1/9 |
| 7 Goal | 설계는 별도 결정이다 | — | `evidence_refs` 가 `[]` 인 증명 요청 건수 |

- 판정자의 웹 fetch 는 절반이 넘게 긴 페이지를 만난다. 11-26 12:15Z 실행 기록 사본의 끝난 판정 64건에서 272번 중 142번이 `maxChars` 를 넘어 머리·꼬리 창으로 돌아왔고, 표식이 가리키는 `keeper_artifact_read(sha256, offset)` 는 판정자 표면에 없었다. 판정자는 `maxChars` 를 2천~3만 자로 부른다.
- 1층의 `evidence_reads` 는 실행 저널에서 투영한다. 실행 기록의 도구 관측은 판정을 돌리는 process 의 메모리에서 온다(`lib/completion_authority_agent.ml` 의 `tools`), 그래서 다른 process 가 이어받은 판정에는 비어 있다. 판정을 세우는 코드는 이미 저널을 읽는다(`lib/keeper/verifier_review_execution.ml` 의 `read_call`). 거절 사건에는 `reason` 만 실리므로 자리를 새로 만들어야 한다.
- 3층이 4층보다 먼저여야 한다. 아니면 지금 live 조회가 구해 주는 잘못된 경로(승인 제출의 `artifact_unreadable` 6개)가 거절로 바뀐다.
- 5층은 경로 형태와 영속 모양의 hard cut 이다. 옛 경로 형태의 참조를 내는 제출은 `Invalid_reference` 로 거절된다. 옛 모양의 reader 를 만들지 않는다. 옛 요청 기록의 증거는 `Evidence_unavailable` 로 읽힌다(D1). 배포 전에 판정을 기다리던 요청을 비운다.
- 4층과 함께 `docs/RELIABLE-CHANGE-ROADMAP.md` 의 경계 suite 문구 셋(`missing-artifact`, `producer-root-missing-mcp`, `producer-artifact-unreadable`)을 D3 대로 고친다.

## 5. 운영자에게 보이는 변화

- 제출 응답이 참조마다 `Read` 또는 `Unreadable` 과 사유를 보여 준다. `Submitter` 소유면 요청이 만들어지지 않고 목록이 돌아온다.
- Task 검사 화면이 같은 기록을 읽는다.
- Keeper 는 파일을 인용하기 전에 export 를 한 번 부른다. MCP 세션은 `masc_evidence_put` 이나 `board:` 또는 `gh:` 를 쓴다.
- CI 실행 로그를 Board 글에 옮겨 적지 않아도 된다. 실행 URL 을 `gh:` 로 낸다. 비공개 저장소의 실행은 아직 `board:` 로 낸다.
- 하네스 사유로 판정이 멈춘 제출이 운영자 목록에 보인다.
- Keeper 가 아닌 생산자는 다음 접속 때 자기 작업의 거절을 본다.
- 5층 배포 뒤 옛 요청 기록의 증거는 사용할 수 없음으로 보인다. 판정은 새 모양으로 다시 제출된 것만 본다.

## 6. 운영자가 정한 것

2026-11-26:

- 「얘들이 증거를 못 보면 안됨. 반드시 봐야함」.
- 설계 조건. 워크어라운드와 땜빵이 아니어야 한다. SSOT 를 어기지 않아야 한다. 같은 종류의 결정을 여러 층에서 다시 하는 이펙트로 뒤덮인 결정이 아니어야 한다. Result 나 Option 을 flat_map 한 결정된 사실로 판정해야 한다.
- 읽기 실패 정책은 「1 -> 추천대로」 다. `Submitter` 소유만 거절한다. 이 정책은 #44713, 경계 suite 문구, RFC-0222 의 「빠지거나 실패한 증거는 그 판단의 입력」 문장, 헌법 `<gates>` 의 `<order>` 를 넘는다.
- #29001 의 기제를 다시 여는지는 「2 -> 중요하고 ROI 높으면 하고」 에 맡겨졌다. 하는 것으로 판단했다. 근거는 §1.1 의 승인 12건이고 비용은 인증 reader 와 capture 코드를 재사용하는 것이다.
- 비공개 저장소는 「3 -> 이건 내가 판단이 잘 안서」 다. 첫 버전은 공개 저장소만 읽고 비공개 저장소의 증거가 필요해질 때 다시 묻는다.
- 「4 -> sha256 이면 현재는 충분한가? 음 export 되도록해야지...」. `artifact:` 를 sha256 으로 두고 export 가 되게 한다. Keeper 와 MCP 세션 둘 다이다. sha256 은 내용의 식별자다. export 한 blob 에는 실행 provenance 가 없고 기록에 남는 것은 누가 언제 넣었는가까지다. CI 실행의 provenance 는 `gh:` 의 run 참조에 있다.

그대로인 것: RFC-0222 의 LLM 판정, RFC-0279, #25911, #24332, PR #28995 의 결합 사유. RFC-0222·RFC-0279·RFC-0224 는 2026-08-08 커밋 `eeb3d68853595` 로 지워졌고 `git show eeb3d68853595^:docs/rfc/<이름>` 으로 읽는다.

## 7. 하지 않는 것

- 판정 값에 셋째를 더하지 않는다.
- 빈 `evidence_refs` 를 거절하지 않는다.
- note 안의 URL 을 전부 참조로 바꾸지 않는다.
- 계약 문구에서 참조를 긁지 않는다.
- 첫 버전에서 비공개 저장소를 읽지 않는다. capture 한 바이트에 가리기를 돌리는 일은 비공개를 열 때 함께 정한다.
- 첫 버전에서 run 의 artifact 본문을 읽지 않는다. 목록만 담는다. 5층 전에 실측하고 정한다.
- Goal 의 사람 최종 확인과 Goal 과 Task 의 연결을 바꾸지 않는다.
- 새 시간·횟수·비용 게이트를 만들지 않는다. resolver 의 총 시간 상한은 자원 경계다.

## 8. 검증

기준선(2026-11-20~11-26): 제출 272, 승인 175, 거절 89. 읽기 실패가 원인인 거절 25. 거절 뒤 15분 안 재제출 37(58건 중). 추적된 승인 39건 중 로그인 벽 승인 12(같은 날 12:15Z 에 38건 중 11건). Keeper 아닌 생산자 거절 9건 중 응답 1.

- 층마다 §4 의 표에서 재는 값을 전후로 비교한다. 같은 사건 파일에서 같은 방법으로 센다.
- 서버 시험. 참조 종류마다 `Read` 와 `Unreadable` 경우를 하나씩 넣는다. `owner_of_reason` 이 전체 함수인 것은 컴파일러가 잡는다.
- 서버 시험. `Submitter` 소유가 섞이면 요청이 만들어지지 않고 검증 요청 행이 없다. `Harness` 소유만 있으면 요청이 만들어지고 모델이 불리지 않는다. 다 읽히면 질문이 고정되고 판정으로 간다.
- 서버 시험. 판정 커밋이 처분을 같은 쓰기로 적는다.
- 서버 시험. 옛 모양의 요청 기록 하나가 `Evidence_unavailable` 로 읽히고 Task 검사 화면이 그렇게 그리는지 본다.
- 5층 뒤에 `rg` 로 지운 이름이 `docs`·`CHANGELOG` 밖에서 0건인지 본다.

## 9. 확인하지 못한 것

- curl 이 302 에서 헤더를 어떻게 넘기는지, 로그가 가는 blob host 의 목록.
- GitHub 이 비공개 저장소의 메타 요청에 인증 없이 무엇으로 답하는지. D3 와 D7 이 공개 여부를 그 답으로 가른다. 재지 않았다.
- MCP 클라이언트의 호출 시간 한도. 네트워크 읽기가 제출 호출 안으로 들어온다.
- Keeper 가 제출 거절을 받고 어떻게 행동하는지. 재지 않았다.
- 검증자 승인 131건은 시도별 기록이 없어 읽었는지 알 수 없다.
- 실행 기록 파일는 끝난 판정 64건만 남는다. 승인 39건 중 12건은 11-26 오전 실측의 값이고 원본은 굴러갔다. 12:15Z 의 사본은 64건(승인 38, 로그인 벽 11)이다. 1층에서 판정 사건에 읽은 기록을 싣기 전까지는 재실측이 같은 수를 재지 못한다.
- 거절 분류는 LLM 이 쓴 사유 원문을 읽은 것이다(±5건). 실제와 대조한 것은 1건이다.
- live 조회의 긴 꼬리(contents·branches·variables·issues) 가운데 어느 것이 계약 판정에 꼭 필요한지. run 의 artifact 본문도 그렇다. 5층 전에 잰다.
