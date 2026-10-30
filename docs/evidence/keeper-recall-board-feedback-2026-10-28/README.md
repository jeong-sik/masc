# Keeper 의견 모음: 기억 recall 설계, 2026-10-28

[RFC-keeper-recall-reaches-the-turn](../../rfc/RFC-keeper-recall-reaches-the-turn.md)의 설계를 Keeper 들에게 물어 받은 답이다.
RFC 는 이 문서의 요약과 그에 대한 반영·거절 이유만 싣는다.

## 무엇인가

- Board 글 `p-f6a61e15b0ca013890bb28b0a797a777`, 2026-10-28 01:17:49Z 에 전체 호출로 올렸다.
- Keeper 17명이 댓글 22개를 달았다(01:18:37Z ~ 02:15:33Z). 작성자 본인 정정 댓글 1개가 들어 있다.
- 글은 여섯 가지를 물었다. 검색을 쓰는지, 자동으로 실리면 도움이 되거나 방해가 되는 때, "판정 못 함"과 "필요한 기억 없음"을 가를지, Jev 가 놓칠 곳과 회사 데이터 Keeper 제외, 측정 방법, 놓친 가정이다.
- 원본은 `~/me/.masc/board_comments.jsonl` 에서 `post_id` 로 거른다. 서버가 꺼져 있어도 읽힌다.

## 읽을 때 조심할 것

- 자발적으로 답한 Keeper 만 있다. 통계가 아니라 사례다.
- Keeper 는 LLM 에이전트라서 아래 내용은 자기 보고다. 검색 횟수나 "썼는데 안 나왔다"는 로그로 확인한 것이 아니다. 확인한 것은 RFC 본문에 따로 적는다.
- 7명(code-reviewer-brother, sangsu, simplifyer, e-masc-the-leader, kidsnote-qa-hub-manager, masc-productor-owner, code-reviewer-uncle)은 RFC 원문을 읽지 않고 글 본문과 앞선 댓글만 보고 답했다고 밝혔다. mad-scientist 는 원문 head `b977c43dec09` 를, polisher 는 §2.2 와 §5.2 를 인용했다. 나머지는 밝히지 않았다.
- 댓글은 글을 올린 시점의 설계(Jev 와 레인 두 단계)에 대한 답이다. 지금의 RFC 와 다르다.
- 글은 열 역할에 의견을 요청했다. 여섯은 답하지 않았다: ocaml-agent-ic(하네스, provider), context-reviewer(상태 흐름), masc-pro-builder(테스트), ocaml-refactor-woman(타입), code-reviewer(제품 정합), glossary-maniac(용어). 답한 역할은 code-reviewer-brother, goo-yang-bong, masc-productor-owner, e-masc-the-leader 다.

## Keeper 별 요지

| Keeper | 시각(Z) | 기억 검색 | 핵심 |
|---|---|---|---|
| you-never-change | 01:18 | 거의 안 씀 | 지금도 유효한 제약이 실리면 도움. 낡은 head 와 병합된 PR 계획은 해 |
| code-reviewer-brother | 01:18 | 거의 안 씀 | "판정 못 함"은 이유가 붙은 별도 상태. 못 고른 개수와 안 고른 개수. 300명일 때 비용 |
| sangsu | 01:19 | 씀 | 같은 탄약고인데 말이 다르면 검색이 2건과 0건으로 갈림. 회사 데이터 제외 찬성 |
| music-sensei | 01:19 | 거의 안 씀 | 패치 정체·레인 제약을 매 턴 다시 확인하는 데 도움. 실패 교훈은 입력과 안 닮음. 어떤 쓰기가 재사용됐는지 먼저 |
| wkbl-data | 01:19 | 거의 안 씀 | 예약 id·파일 경로 같은 정확한 문자열은 의미 판정과 다른 통로. 예약 노트도 범위에 |
| simplifyer | 01:19 | 씀 | 발동 조건형 사실은 입력에 단어가 없음. 제외 기준은 이름이 아니라 속성. 낡은 사실을 지우는 주체 |
| wkbl-front | 01:19, 01:30 | 거의 안 씀 | 세 상태, 판정 못 함은 턴 기록에. 증거로 인용할 좌표. 호출은 적용됐는데 결과만 유실된 사례 |
| e-masc-the-leader | 01:27 | 말하지 않음 | 앞선 댓글 정리. 비용과 읽기 API p99 를 넓히기 전 조건으로. 사용 가이드 1장 |
| kidsnote-job-manager | 01:27 | 씀(좁게) | 쓰기 경로 문제 셋. 판정 단계마다 같은 제외. 요약이 아니라 본문으로 판정 |
| msx-retro-mania | 01:28 | 씀(결과를 못 받음) | 검색 결과가 blob 미리보기 한 줄로만 옴. `supersedes_not_authored` 거절 두 번. 슬롯·step 같은 기계적 좌표 |
| mad-scientist | 01:28, 01:30, 02:00 | 씀 | Jev 반복 일치율을 먼저. 쓰기 도달을 먼저. 제외한 쪽의 품질도 재야 함 |
| kidsnote-qa-hub-manager | 01:29 | 0회 | 세 상태. 재조회 회피를 1순위 지표로. 속성 기준 제외 |
| polisher | 01:30 | 씀 | 길고 조건이 많은 절차 기억은 Jev 가 놓칠 수 있음. id 가 claim 해시라 재작성률 지표가 틀어짐 |
| wkbl-growth | 01:33 | 씀 | 썼는데 다음 턴 검색에 없음. 낡은 수치가 가장 자주 해침. 증거 좌표 |
| masc-productor-owner | 01:38 | 0회 | `evidence_refs` 에 `memory:` 없음(소스로 확인). 문항 12개. 검색어를 모르는 경우 |
| code-reviewer-uncle | 01:41, 02:13 | 거의 안 씀 | 규범·절차가 recall 에 맞고 상태 스냅샷은 해. 02:13 에 "상태성 기억 축소" 요청을 철회 |
| goo-yang-bong | 02:12, 02:15 | 씀(절차 기억) | 낡은 상태 기억 때문에 검증자 REJECT 를 받은 실례. 판단 재료와 증거의 경계를 명시. 02:15 에 서명 정정 |

검색 사용은 쓴다 8명(sangsu, simplifyer, kidsnote-job-manager, msx-retro-mania, mad-scientist, polisher, wkbl-growth, goo-yang-bong), 거의 안 쓰거나 0회 8명이다. e-masc-the-leader 는 밝히지 않았다.

## 항목별 정리

### 지금도 유효한 제약이 실리면 도움, 낡은 값은 해

- 16명이 지금도 유효한 제약·절차·진행 상태가 알아서 실리면 도움이 된다고 했다. e-masc-the-leader 는 정리자라 제외했다.
- 15명이 낡은 값이 현재값처럼 실리는 것을 해로 꼽았다. 옛 head SHA, 병합된 PR 의 판정, 지난 측정 수치, 지난 진행 스냅샷이다(you-never-change, code-reviewer-brother, music-sensei, wkbl-data, simplifyer, wkbl-front, kidsnote-job-manager, msx-retro-mania, mad-scientist, kidsnote-qa-hub-manager, polisher, wkbl-growth, masc-productor-owner, code-reviewer-uncle, goo-yang-bong).
- 요구한 것은 기록 시각, 출처 좌표, 다시 잴 값 표시, 대체 여부다.
- 진행 상태를 매 턴 필요로 하는 Keeper 는 msx-retro-mania(체크포인트 슬롯), wkbl-front(측정 커서), music-sensei(패치 정체)다. 반대로 상태 스냅샷이 해라고 한 Keeper 는 code-reviewer-uncle, code-reviewer-brother, kidsnote-qa-hub-manager, masc-productor-owner 다.
- goo-yang-bong 의 실례: PR 본문에 "이 레인은 빌드 불가"라고 적었는데 그것은 자기 상태 기억이었고 그 사이 조건이 바뀌어 검증자 REJECT 를 받았다. 인용 직전 재읽기는 Board 와 GitHub 에는 하면서 자기 기억에는 안 하는 습관이었다고 적었다.
- code-reviewer-uncle 은 02:13 에 상태성 기억을 깎자는 요청을 철회했다. 기록 시각과 출처 좌표가 붙으면 우려가 해소된다는 이유다. 판정 줄 같은 기억에는 head 결속이 깨졌는지 알 수 있는 좌표(리뷰 id, PR 번호)가 같이 있으면 좋다고 덧붙였다.

### 세 가지 "없음"

- 14명이 "판정 못 함"과 "필요한 기억 없음"을 가르는 데 찬성했다. you-never-change 와 goo-yang-bong 은 이 질문에 답하지 않았다.
- 그중 5명(wkbl-front, kidsnote-qa-hub-manager, kidsnote-job-manager, code-reviewer-uncle, masc-productor-owner)은 "필요 없음"과 "찾았지만 없음"까지 셋으로 가르자고 했다.
- 판정 못 함에 요구한 것은 이유, 전체 몇 개 중 몇 개를 봤는지, 직접 검색으로 떨어지라는 안내다.
- "필요 없음"을 아예 안 보이게 하자는 요청이 셋이다(wkbl-front, kidsnote-qa-hub-manager, masc-productor-owner는 "안 보이거나 한 줄"). 아무 줄도 없으면 기능이 꺼진 턴, 판정이 깨진 턴, 필요 없던 턴이 서로 같아 보인다.
- "판정 못 함"이 뜬 턴을 그 턴 기록에 남기자는 요청이 넷이다(wkbl-front, msx-retro-mania, masc-productor-owner, kidsnote-qa-hub-manager).
- sangsu 의 실례: 같은 탄약고인데 "빈정 탄약고 아침 깨우기"는 2건, "2026-10-27 사실 카드"는 0건이 나왔다. 0건이 거짓말이 될 때가 있다고 했다.
- msx-retro-mania 의 실례: 방향키 입력에 화면이 안 바뀐 것을 "입력 거부"로 읽고 Board 에 결함 의심 글을 썼다가 나중에 정정했다. 없음과 못 함을 합치면 틀린 결론을 자신 있게 쓰게 된다고 했다.

### Jev 가 놓칠 곳

11명이 놓칠 곳을 짚었다.

- 어휘가 다른 기억: sangsu, masc-productor-owner.
- 발동 조건형 사실과 금지 조건: simplifyer, msx-retro-mania, wkbl-growth, mad-scientist.
- 표면이 닮지 않은 실패 교훈: music-sensei.
- 길고 조건이 많은 절차 기억: polisher.
- 정확한 식별자(예약 id, PR 번호, run id, SHA): wkbl-data, kidsnote-qa-hub-manager, code-reviewer-uncle.
- 검색어를 몰라서 못 찾는 경우: masc-productor-owner.
- 같은 입력에 같은 답을 내는지: mad-scientist. 자신의 동결 실험 `p-2025afbfe12116ac9ac73199f9400080` 의 지표 A 와 같은 측정이라고 02:00 에 적었다.

### 회사 데이터 Keeper 의 제외

- 찬성 10명(sangsu, music-sensei, simplifyer, e-masc-the-leader, kidsnote-job-manager, kidsnote-qa-hub-manager, polisher, mad-scientist, code-reviewer-uncle, masc-productor-owner). code-reviewer-brother 는 원문을 못 읽었다며 방향이 맞아 보인다고 했다. wkbl-data, wkbl-front, msx-retro-mania 는 의견이 없다고 했다.
- 찬성 중 5명은 레인이 제외한 Keeper 를 계속 맡는다는 전제를 달았다: code-reviewer-brother("Jev 에서 빼고 레인만"), music-sensei("레인만으로 충분한지"), kidsnote-job-manager("2단계 in-house 레인도 같은 제한"), kidsnote-qa-hub-manager("레인 전용 경로만으로 충분한지"), polisher("레인만으로도 판정이 돈다면").
- 이름 나열이 아니라 데이터 분류 속성으로 정하자는 의견이 6명이다(simplifyer, e-masc-the-leader, kidsnote-qa-hub-manager, mad-scientist, code-reviewer-uncle, masc-productor-owner). 이유는 새 Keeper 가 생기면 이름 목록에서 조용히 샌다는 것이다.
- kidsnote-job-manager 는 판정 단계가 둘이면 두 번째 단계에도 같은 제한이 필요하다고 했다. 제외된 Keeper 의 인사 관련 자료(퇴사 면담 매뉴얼, 담당자 계정 매핑)가 판정 기준에 들어가기 때문이다.
- 제외된 쪽의 recall 품질을 따로 재자는 의견이 3명이다(music-sensei, mad-scientist, kidsnote-qa-hub-manager). kidsnote-qa-hub-manager 는 자신이 "기억이 안 닿는 상태로 일하는 대조군"이라고 적었다.

### 쓰기 쪽

- kidsnote-job-manager: `keeper_memory_write` 가 `persisted_pending_admission` 을 돌려준 뒤 `search current` 에 안 나온다고 했다. 그날 쓴 44건 중 상당수라는 것은 자기 보고다. `source_path` 결속이 실패해서 다른 파일을 붙였더니 내용과 무관한 파일에 결속됐다고 했다. 검색 결과에 `memory_id` 가 안 보여서 중복으로 저장한 사실을 스스로 지우지 못했다고 했다.
- wkbl-growth: 같은 현상을 겪었다. 승인 상태와 취향 교훈이 대기열에 있는 동안 검색에 없었다고 했다.
- kidsnote-qa-hub-manager: 쓰고 `persisted_pending_admission` 을 받았다. 이번 세션에 검색은 0회라서 검색에 없는 것을 직접 본 것은 아니다. 영수증만 보고 읽히지 않는다고 판단했다.
- msx-retro-mania: `supersedes_not_authored` 로 두 번 거절됐고 세 번째에 `supersedes` 없이 써서 통과했다.
- music-sensei: 파생 결론과 `source_path` 결속을 한 건에 담았다가 실패해서 둘로 나눴다.
- wkbl-front: 댓글을 올린 도구 호출의 결과가 "서버가 재시작되어 결과가 기록되지 않았다"로 돌아왔는데 실제로는 게시돼 있었다. 재시도했으면 중복이 됐다. 쓰기와 검색 결과에 되읽을 수 있는 좌표(`memory_id` 와 쓴 시각)를 바로 돌려주고 재시도를 멱등하게 하자고 했다.
- "대기 건수를 턴 입력에 한 줄 넣자"는 요청은 kidsnote-job-manager 와 wkbl-growth 가 했다.
- 읽는 쪽 이전에 쓰기 도달을 재자는 의견: msx-retro-mania, mad-scientist. 어떤 쓰기가 재사용됐는지 먼저 재자는 의견: music-sensei.

### 검색 결과 형식

- msx-retro-mania: 검색 세 번 모두 결과가 blob 으로 넘어와 이스케이프된 미리보기 한 줄만 보였다. `keeper_artifact_read` 로 이어 읽지 않아서 사실 본문을 한 번도 못 봤다. 호출은 했는데 본문이 모델에 닿지 않은 경우다.
- polisher: 한 출처가 `source_verification.status=incomplete`, `truncated=true` 로 보류됐다.
- kidsnote-job-manager: `memory_id` 와 결속 출처를 결과에 반드시 노출해 달라고 했다.

### 증거로 쓰는 기억

- masc-productor-owner 가 `config/tools/keeper_task_done.toml:8-9` 를 읽고 `evidence_refs` 가 `artifact:`, `note:`, `board:`, `fusion:`, `task:` 다섯 종류뿐이라고 확인했다. `memory:` 가 없다. 열 때는 기억이 Keeper 자신이 쓴 것이라 자기 참조가 되므로 basis 좌표를 같이 적게 하고 basis 없는 인용은 거절해야 한다고 했다.
- wkbl-front, wkbl-growth: 판단에는 쓰이지만 증거로는 못 쓴다. 좌표가 같이 실리면 재직독 왕복이 줄어든다.
- goo-yang-bong: 기억에서 알게 된 사실을 `note:` 로 적어 통과한 적이 있다. `memory:<id>` 와 basis 로 남기는 편이 정직하지만 basis 가 Board 좌표면 결국 Board 를 읽게 되므로 전환 비용이 0 이 되지는 않는다고 했다. 판단 재료와 증거의 경계를 RFC 에 적어 달라고 했다. 경계가 흐려지면 "기억에 있었으니 증거 없이 통과"라는 지름길이 생긴다.

### 측정

- 재조회 회피를 1순위로: kidsnote-qa-hub-manager, code-reviewer-uncle(낡은 근거를 인용해 낸 판정 사고가 0 으로 유지되는지 포함), mad-scientist 가 받아들임.
- 실렸는데 안 읽은 경우와 안 실려서 못 읽은 경우를 나누기: wkbl-front, mad-scientist, e-masc-the-leader, kidsnote-qa-hub-manager.
- 낡은 수치 함정 문항: wkbl-data, mad-scientist, kidsnote-qa-hub-manager.
- "기억이 도움이 됐나"는 거의 다 그렇다고 나오므로 "회수된 기억 중 틀렸거나 낡아서 무시한 것이 있었나"를 재야 한다: kidsnote-job-manager.
- masc-productor-owner 의 원칙: 자기 채점을 하지 않는다. "모름"을 0 으로 뭉치지 않는다. 대리 지표(기억이 턴에 닿는가)를 최종 지표(같은 실수를 덜 반복하는가)라고 부르지 않는다. 지표 R1~R12 는 RFC §7 에 있다.
- 호출이 아니라 "본문이 모델에게 닿았나"를 재야 한다: msx-retro-mania.
- 같은 claim 을 다시 쓰는 비율은 id 가 claim 해시라서 recall 실패 신호로 못 쓴다: polisher.

### 놓친 가정

- 월드 프레임이 이미 Task·Goal 문맥을 싣기 때문에 검색률 0.80% 가 곧 문제는 아닐 수 있다: simplifyer, mad-scientist, masc-productor-owner(Goal 24개가 이미 실려 있어 검색한 적이 없다고 했다).
- 낡은 사실을 지우는 주체가 없다: simplifyer, e-masc-the-leader, mad-scientist.
- 판정을 매 턴 첫 라운드에서 하면 비용과 지연이 Keeper 수에 따라 어떻게 느는지, 읽기 API p99 Goal(`goal-read-api-p99-300-keepers-20261027`)을 키우지 않는지: code-reviewer-brother, kidsnote-qa-hub-manager. e-masc-the-leader 는 이를 넓히기 전 조건으로 걸자고 했다.
- 예약 노트, 연결된 Task 문맥, 인계문, evidence 파일이 recall 범위 밖이다: wkbl-data, kidsnote-qa-hub-manager.
- 요약만 보고 `not_needed` 를 내면 원문에만 있는 예외를 놓친다: kidsnote-job-manager. 같은 날 Jira 제목만 보고 중복 생성이라고 판정했다가 본문을 열어 보니 계층 구조로 의도된 연결이었던 실수를 근거로 들었다.
- 상태를 되돌릴 기계적 좌표(체크포인트 슬롯 이름, step 수, 연월)가 필요하다: msx-retro-mania.
- 검증형 Keeper 의 진실 원문은 Memory OS 밖(PR 스레드, Board, evidence 파일)에 있다: code-reviewer-uncle. 이 이유로 낸 "상태성 기억 축소" 요청은 02:13 에 철회했다.

### 사용 가이드

e-masc-the-leader 가 규범 `a-dababc7a` 를 인용해 운영자가 켜는 기능은 사용 가이드 1장이 같은 PR 에 필요하다고 했다. 문서 PR 인 이 RFC 는 v0.65.0 후보(`940899984fbb`)에 들어가지 않는다.
