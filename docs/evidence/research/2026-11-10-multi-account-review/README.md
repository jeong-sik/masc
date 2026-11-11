# 다계정 로그인 구현 적대적 검토와 바깥 조사 기록, 2026-11-10

[분석 문서](../../../research/2026-11-10-multi-account-review-and-agent-platform-landscape.md)가 이 기록을 해석한다.
이 묶음의 보고서 13개는 조사 에이전트가 쓴 원본을 손질한 파생본이다.
원본과 바이트가 다르다. 무엇을 바꿨는지는 「손질한 것」에 있다.

## 판정 대상과 환경

| 항목 | 값 |
| --- | --- |
| 판정 대상 head | `85b8af5b0453`, 브랜치 `feat/authz-f3a-off-command-20261110`. 코드 검토 보고서의 줄 번호는 이 트리 기준이다. 예외가 둘이다. rev-exec-boundary 는 2026-11-10 18시 작업 트리 기준이다. research-landscape-terms 는 코드를 `9424cc7b5394` 에서 읽었다 |
| 진행률 기준 | `main` `b32d3a09e102` |
| 확인 시각 | 2026-11-10 KST. 코드 보고서 넷은 16:48~16:53 KST 를 확인 시각으로 적었다. rev-exec-boundary 는 18:02 KST 의 작업 트리 상태를 적었다. 웹 페이지는 같은 날 열었다 |
| 조사한 쪽 | 읽기 전용 조사 에이전트. 보고서는 코드 7개, 웹 6개다. 저장소 파일을 고치지 않았다 |
| 빌드와 실행 | 없다. dune 빌드, 시험, 서버 실행, 브라우저 실행을 하지 않았다 |
| 코드를 읽은 방법 | `rg` 와 파일 읽기. 보고서마다 쓴 명령을 적어 두었다 |
| 웹을 읽은 방법 | WebSearch 와 WebFetch. Hacker News 는 공개 검색 API 로, GitHub 이슈는 공개 API 로 읽었다. research-landscape-terms 는 원문을 받아 사본으로 저장해 읽었다 |
| 웹 읽기의 한계 | WebFetch 는 대부분 요약 모델을 거친 글을 돌려준다. 보고서의 출처 표가 건마다 원문·요약·2차·snippet 을 구분한다 |

## 파일과 관찰한 결과

| 파일 | 종류 | 관찰한 결과 |
| --- | --- | --- |
| [rev-server-doors.md](rev-server-doors.md) | 코드 검토 | `Auth_gate.decide` 를 부르는 곳은 미리보기 핸들러뿐이다. 실제 서버의 경로 등록 호출 385곳은 계정 모드를 보지 않는다. 발견은 P1 5건, P2 4건, P3 1건이다 |
| [rev-store-boot.md](rev-store-boot.md) | 코드 검토 | 오늘 도는 경로에서 P0 는 찾지 못했다. P1 2건, P2 2건, P3 4건이다. 설계 §5.1 표 11행은 입력이 맞으면 코드와 같다 |
| [rev-login-session.md](rev-login-session.md) | 코드 검토 | P0 확정 0건, P1 1건, P2 4건, P3 4건이다. P2 한 건은 GitHub 의 token 교환 동작에 달려 있다 |
| [rev-exec-boundary.md](rev-exec-boundary.md) | 코드 검토 | P0 확정 0건, P0 후보 1건, P2 3건, P3 4건이다. P0 후보는 Claude Code 의 동작에 달려 있고 재지 않았다. 공식 클라이언트 프로세스를 띄우는 곳 12곳과 호스트 key 를 쓰는 곳 17곳을 셌다 |
| [rev-rules-census.md](rev-rules-census.md) | 코드 집계 | 다계정 `.ml` 79개 15,144줄을 봤다. 위반으로 센 것은 문자열 판정 3, 기본값 접기 3, SSOT 중복 14, 하드코딩 4, 환경 변수 3, 전역 가변 상태 1, 박힌 문구 2, 가변 데이터 1, 레거시 흔적 1 이다 |
| [census-lifecycle-scale.md](census-lifecycle-scale.md) | 코드 집계 | Keeper phase 8개와 이벤트 13개가 닫힌 합타입이다. base path 하나에 서버 하나다. 환경 변수 이름은 약 284개다. sandbox 종류는 Docker, microVM, SSH 셋이다 |
| [audit-mcp-spec.md](audit-mcp-spec.md) | 코드와 명세 대조 | 최신 명세는 2026-07-28 이다. 구현은 대부분 맞고 틈은 10개다 |
| [research-agent-security.md](research-agent-security.md) | 웹 조사 | 출처 76건. 앞선 제품은 자격 증명과 harness 를 sandbox 밖에 두고 egress 를 guest 밖에서 막는다 |
| [research-identity-authz.md](research-identity-authz.md) | 웹 조사 | 출처 74행. 앞선 지점 12개, 기준선 10개, 함의 10개를 적었다 |
| [research-landscape-terms.md](research-landscape-terms.md) | 웹 조사 | 벤더 셋의 구독 로그인 약관과 문서를 읽었다. 판정은 Anthropic 조건부 허용, OpenAI 문서로는 허용이고 자동화에는 권하지 않음, Google 소비자 플랜은 지원하지 않음이다. 출처 30행 |
| [landscape-vendor-platforms.md](landscape-vendor-platforms.md) | 웹 조사 | 벤더 제품 10개의 배포·팀·수명·격리·프로토콜과 공통 설계 8개. 출처 78행 |
| [landscape-oss-orchestrators.md](landscape-oss-orchestrators.md) | 웹 조사 | 오픈소스 orchestrator 9개와 durable runtime 6개, 가져올 모양 10개, 빈 자리 6개. 출처 48행 |
| [community-signal.md](community-signal.md) | 웹 조사 | Hacker News 와 GitHub 이슈에서 읽은 주제 10개. Reddit 과 X 는 읽지 못했다 |

보고서는 보고를 받아 묶은 세션을 team-lead 라고 부른다. 분석 문서는 종합 세션이라고 부른다. 그 세션의 종합과 직접 확인 메모는 이 묶음에 없다. 그 내용은 분석 문서에 옮겼다.

## 손질한 것

파생본마다 맨 위에 파생본 표시 한 줄을 더했다. 그 밖에 바꾼 것은 여섯이다.

1. 절대 경로를 지웠다. worktree 경로는 저장소 상대 경로 `.worktrees/authz-d1-1-20261108` 로 바꿨다. 사용자 이름이 든 홈 경로, 세션 임시 폴더 경로, 도구 출력 파일 경로는 지웠다. 이메일, 호스트 이름, 토큰은 원본에도 없었다.
2. 남의 글을 그대로 옮긴 문장을 뜻만 풀어 썼다. 대상은 Hacker News 글과 댓글, 벤더 문서와 약관 문장, 기사와 포럼 글, GitHub 이슈 문장이다. 링크, 날짜, 점수, 수치는 그대로다. 출처 표의 글 제목은 제목이라 그대로 뒀다. 이 저장소의 코드·주석·설계 문서에서 옮긴 문장도 그대로 뒀다.
3. 조사하다 만난 AI 에이전트용 지시문 두 건은 내용을 지웠다. 지시문이 있었고 따르지 않았다는 사실만 남겼다.
4. 운영 규모가 드러나는 예시 하나를 일반식으로 바꿨다.
5. 재현 절차를 지웠다. 코드 검토 보고서 넷의 「시나리오」와 「깨지는 입력」 문단을 「무엇이 틀렸나」로 줄였다. 무엇이 틀렸는지와 파일 좌표만 남겼다. 번호 붙은 단계, endpoint, 헤더 값, 입력 값, 요청 수, 순서는 지웠다. 좌표가 있으니 코드에서 다시 따라갈 수 있다. 재현 절차가 든 원본은 공개 저장소에 넣지 않았다.
6. rev-exec-boundary 에 실린 안전장치 알림의 원문을 지웠다. 알림에 있던 요청 id 둘과 안내 링크 셋도 같이 지웠다. 알림이 있었고 리뷰가 그 안내를 따랐다는 사실만 남겼다.

| 파일 | 바꾼 곳 |
| --- | --- |
| audit-mcp-spec.md | worktree 절대 경로 1곳 |
| rev-server-doors.md | worktree 절대 경로 1곳. 시나리오 문단 7개. 3개는 다시 썼고 4개는 이름만 바꿨다 |
| rev-store-boot.md | worktree 절대 경로 1곳. 깨지는 입력 문단 6개와 발견 8 의 입력 줄을 다시 썼다. 번호 붙은 단계 19줄과 발견 8 의 결과 줄을 지웠다. 머리말 1줄을 고쳤다. 원본보다 20줄 짧다 |
| rev-rules-census.md | worktree 절대 경로 1곳 |
| rev-login-session.md | 시나리오 문단 9개. 6개는 다시 썼고 3개는 이름만 바꿨다. 발견 2 의 확인 줄 1곳 |
| rev-exec-boundary.md | 원본과 다른 줄은 23줄이다. worktree 절대 경로 1줄. 발견 1 의 입력 표기를 적은 8줄. 시나리오 1줄과 닫는 방법 1줄이 여기에 든다. 그 밖의 시나리오 문단 8개. 1개는 다시 썼고 7개는 이름만 바꿨다. 재현 조건 1줄, 경로 철자의 예 1줄. 안전장치 알림을 적은 4줄. 그중 알림 원문 2줄은 지웠다 |
| census-lifecycle-scale.md | 홈 아래 runtime 디렉터리 경로 1곳, Keeper 수 예시 1곳 |
| research-agent-security.md | 인용과 따옴표 표기 12곳, 「저장된 원문」 절의 안내 1줄, 도구 출력 파일 경로 5개 |
| research-identity-authz.md | 인용 4곳 |
| research-landscape-terms.md | 원본과 다른 줄은 94줄이다. 영어 인용을 풀어 쓴 줄이 대부분이다. 임시 폴더 경로 2곳을 지웠다. 「읽은 방법」 절의 검사 설명과 신뢰도 줄을 파생본에 맞게 고쳤다. 「사용자 몫」을 「운영자 몫」으로 바꿨다 |
| landscape-vendor-platforms.md | 인용 15곳, 지시문 내용 1건, 임시 폴더 경로 2개 |
| landscape-oss-orchestrators.md | 인용 30곳, 지시문 내용 1건 |
| community-signal.md | 주제 문단 10개와 표 11칸의 인용, 읽은 방법 설명 2곳 |

손질한 뒤 원본과 파생본을 스크립트로 비교했다.

- URL 은 두 파일을 빼고 원본과 같다. rev-exec-boundary 는 알림 원문의 링크 셋이 빠졌다. rev-login-session 은 시나리오에 있던 예시 주소 셋이 빠졌다.
- 숫자는 지운 것에 들어 있던 것만 빠졌다. 지운 경로, Keeper 수 예시의 `30`·`60`, 재현 절차의 단계 번호와 요청 수와 예시 값, 알림 원문의 값이다.
- 늘어난 숫자는 두 파일에 있다. census-lifecycle-scale 은 Keeper 수 예시를 일반식으로 바꾸면서 `2N` 이 들어갔다. research-landscape-terms 는 아홉 줄이다. 영어로 적힌 날짜를 숫자로 옮긴 줄이 여섯이다. 그중 한 줄은 `7` 이 `07` 이 됐다. one-year 와 five-hour 를 숫자로 적은 줄이 둘이다. 신뢰도 줄에 더한 문장이 하나다. 날짜와 값은 같다.
- research-landscape-terms 의 풀어 쓴 줄은 독립 검토가 원본과 줄 단위로 한 번 대조했다. 문제 5줄과 의심 6줄을 받았다. 영어 원문을 사본에서 다시 확인하고 11줄을 고쳤다.
- 절대 경로, 이메일 주소, 사용자 이름을 찾는 `rg` 검색은 이 폴더에서 0줄이다.

아래는 손질하기 전 원본의 크기와 SHA-256 이다. 이 폴더의 파일에 대한 값이 아니다.

| 원본 파일 | 바이트 | SHA-256 |
| --- | --- | --- |
| audit-mcp-spec.md | 14,768 | `a8010feee110d3901f7c5d7dee48abc661ac81a4ca097ac273007fd178e351e5` |
| census-lifecycle-scale.md | 33,154 | `e0566502173bd5f585b7d283ecf23a86ee60cf1e4f0e22c9cbdab18f3d773a36` |
| community-signal.md | 17,304 | `632adb0a22ed18c1f36a0079e77fafcbdfd0891f0f60ac93eea2c68ac3136b2c` |
| landscape-oss-orchestrators.md | 33,014 | `4596c4f1d1539aa2d69a8c2601c4d83bbe55d6a2d025a76708efa0af33e8d1fd` |
| landscape-vendor-platforms.md | 26,744 | `6dfc9af66da934e7d126f0e2a4422aabd486279387d9cef6d386d9215ab6d782` |
| research-agent-security.md | 29,612 | `368e57f5ea8755efb9c715de3e9c5c7fed5cac7e950b09e2b4c059f3607def62` |
| research-identity-authz.md | 25,036 | `6f3da655c3daf7337124f9e959c6faa5418680f9f76785c82406dbcacf8bdd9e` |
| research-landscape-terms.md | 35,308 | `1274863213ce2362b8b03de53045dbd62cbafdbba0f85c7dc30033e6406ce539` |
| rev-exec-boundary.md | 32,594 | `f1e5200e1ac749be19cbd9d3dc96746e733d067ff585cf32f268f8c868509f6a` |
| rev-login-session.md | 12,035 | `bc21542361c5f8d62bfb40f66de641a1ceb9976a1c635b3f26afc6815208c5a9` |
| rev-rules-census.md | 27,082 | `0cff5647759e0c457e42707125370062326a97b7db69d7fd2108b2df3d3d95c1` |
| rev-server-doors.md | 30,427 | `4d1bfd4a7b55665b0fed21d7466abb5da7ab45c70484f6b3d1c6c8ecc4ae7fa5` |
| rev-store-boot.md | 30,012 | `29fd3e2e70c6229b8624f7a9717165374b5d9ea356eac95b5b06f41bdbd5b482` |

## 좌표 점검

이 묶음을 만들면서 먼저 온 코드 보고서 6개의 좌표를 판정 대상 head 와 대조했다.
`git ls-tree -r 85b8af5b0453` 으로 파일이 있는지 봤다. `git show 85b8af5b0453:<path>` 로 줄 수를 셌다.

- `.ml`·`.mli` 좌표는 752개다. 그중 줄 번호가 붙은 것은 593개다.
- 없는 파일을 가리키는 좌표는 없다. `server_*_in_process_gateway.ml` 한 곳은 와일드카드 표기다.
- 줄 범위가 파일 끝을 넘는 좌표는 하나다. rev-rules-census 의 `lib/keeper_runtime/keeper_runtime_config.ml:690-720` 이고 그 파일은 719줄이다.
- 뒤에 온 rev-exec-boundary 는 따로 봤다. `.ml`·`.mli` 좌표는 200개이고 줄 번호가 붙은 것은 173개다. `85b8af5b0453` 과 `9424cc7b5394` 양쪽에 대조했다. 줄 범위가 파일 끝을 넘는 좌표는 없다. 두 커밋에 없는 파일은 `lib/server/server_accounts.ml` 하나다. 보고서가 커밋 전 파일이라고 적은 것이다.
- rev-exec-boundary 의 줄 번호는 18시 작업 트리 기준이다. 보고서가 기준 head 와 다르다고 적은 파일에서는 줄이 밀릴 수 있다.
- research-landscape-terms 의 코드 좌표 10개는 두 커밋 모두에서 파일과 줄 범위가 맞는다.
- 이 점검은 파일과 줄 범위만 본다. 그 줄에 보고서가 말한 코드가 있는지는 보지 않는다. 그 대조는 분석 문서 §7 에 따로 적었다.
- 점검 스크립트는 이 묶음에 넣지 않았다.

## 확인 못 한 범위

- 실행해서 재현한 발견은 하나도 없다. 모든 발견은 코드를 읽고 따라간 결과다.
- 보고서마다 「읽지 않은 것」이나 「Did not read」 절이 있다. 그 범위는 판정에 들어 있지 않다.
- 수를 센 값은 `rg` 정적 집계다. 서버에서 잰 값이 아니다. 경로 인벤토리 도구(`tools/auth_route_inventory`)는 빌드가 필요해서 돌리지 않았다.
- GitHub 가 token 교환의 `redirect_uri` 를 authorize 때 값과 비교하는지는 확인하지 못했다. 시험용 OAuth App 이 있어야 한다(rev-login-session 발견 2).
- Claude Code 가 사람이 보낸 글 안의 표기를 입력 단계에서 처리하는지는 재지 않았다(rev-exec-boundary 발견 1).
- rev-exec-boundary 의 하위 감사 하나는 하지 못했다. Keeper 에게 보이는 도구, sandbox 마운트, 브라우저가 계정 홈에 닿는지 보는 감사다. 맡은 서브에이전트가 안전장치에 멈췄고, 리뷰는 안내에 따라 그 일을 직접 하지 않았다.
- OpenAI 의 Terms of Use 와 help.openai.com 글은 403 이라 읽지 못했다(research-landscape-terms).
- Reddit 과 X 는 읽지 못했다. 두 곳의 글은 Hacker News 에 올라온 링크와 제목으로만 나온다.
- 웹 조사의 수치 가운데 출처가 하나뿐인 것은 보고서가 그렇게 표시했다.
- 영어로 쓴 보고서 셋은 옮기지 않고 영어로 뒀다.

## 표기

- P0 는 지금 `masc auth preview` 에서 통하는 결함이다. P1 은 실제 서버나 공개 hostname 에 달면 통하는 결함이다. P2 는 영향이 좁거나 보강이 빠진 자리다. P3 는 정리 거리다(rev-login-session 의 정의). rev-store-boot 는 P0 를 오늘 도는 경로에서 틀린 것으로 쓴다.
- rev-exec-boundary 는 P0 를 오늘 도는 경로에서 틀린 것으로 쓴다. P1 은 실제 서버가 다계정을 서빙할 때 다른 계정 것을 쓰거나 읽거나 호스트 key 를 쓰는 것이다.
- rev-server-doors 의 `DO n` 은 그 리뷰가 받은 지시 목록의 번호다. rev-exec-boundary 의 `Q n` 은 그 리뷰가 받은 질문 목록의 번호다. 두 목록은 이 묶음에 없다.
- research-landscape-terms 의 `[An1]`, `[Oa1]`, `[Go1]` 같은 표기는 그 보고서 출처 표의 키다.
- 보고서의 「계획」과 「설계」는 `docs/superpowers/plans/2026-10-27-multi-account-oidc-runtime-authorization.md` 와 `docs/superpowers/specs/2026-10-27-multi-account-oidc-runtime-authorization-design.md` 다.
- 보고서의 「미리보기」는 `masc auth preview` 가 loopback 에 띄우는 화면과 경로다.

## 후속 정정, 2026-11-11

위 손질 내역과 좌표 점검은 2026-11-10 판본의 기록이다. 이후 `research-landscape-terms.md` 의 코드 경계와 결론 1 을 정정했다. 고정 코드 `9424cc7b5394` 에서 Codex 검증·모델 갱신은 `auth.json` 을 읽어 임시 HOME 에 복사하고, 계정 표시도 `tokens.id_token` 을 읽는다. 따라서 Claude 와 Codex 에 「서버는 토큰을 다루지 않는다」는 공통 전제를 적용하지 않는다.

이 정정은 공개 소스만 대조했다. 실제 자격증명 파일을 읽거나 실행하지 않았고, 접근하지 못했던 약관을 다시 받지 않았다. 공급자 정책의 허용·위반 판단을 새로 내리지 않는다.
