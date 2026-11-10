> 파생본이다. 원본 조사 보고서를 [README](README.md)에 적은 대로 손질했다.

# 벤더 구독 로그인 약관: 직접 읽은 것

research-landscape-terms · 2026-11-10 KST · 하위 보고 셋의 내용은 옮기지 않았다

## 질문과 답

질문: 팀원이 각자 자기 유료 구독으로 로그인한다. self-hosted 팀 서버가 그 사람 몫으로 벤더의 공식 CLI를 subprocess로 띄운다. 벤더가 이것을 허용하는가.

| 벤더 | 판정 | 이유 |
|---|---|---|
| Anthropic (Claude Code) | 조건부 허용 | 수정하지 않은 `claude`에 본인 구독으로 로그인하는 것은 platform이 호스팅해도 막지 않는다 [An1]. 서버가 자격증명을 모으거나 보관하거나 중개하면 금지다. |
| OpenAI (Codex CLI) | 문서상 허용, 자동화에는 비권장 | 원격 기계 로그인과 `codex exec`의 로그인 재사용을 문서가 안내한다 [Oa1][Oa3]. 자동화 인증은 API 키를 권한다 [Oa2]. Terms of Use 원문은 못 읽었다. |
| Google (Antigravity CLI, 소비자 플랜) | 미지원. 쓰지 않는다 | 다른 앱이 `agy`를 감싸는 것은 소비자 플랜에서 미지원이다 [Go2]. third-party 도구로 접근하면 약관 위반이다 [Go1]. 감싸기만 따로 위반이라고 적은 문장은 없다. |

| 질문 | Anthropic | OpenAI | Google(소비자) |
|---|---|---|---|
| (a) 구독 로그인을 third-party 도구에서 | 금지 | 공식 경로가 있다(Sign in with ChatGPT의 plan usage) | 금지(약관 위반) |
| (b) 공식 CLI를 headless로 | 허용. `--bare`는 구독 로그인을 읽지 않는다 | 허용. 자동화는 API 키 권장 | `agy -p`는 본인 스크립트와 CI용 |
| (c) 공유 서버, 상시 실행 | 호스팅 허용(조건 둘). 한도는 보통의 개인 사용이 전제다. 상시 실행을 따로 다룬 문장은 없다 | 신뢰할 수 있는 사설 인프라가 조건 | 다른 앱이 감싸면 미지원 |
| (d) 한 구독을 여러 사람이 | 금지 | 못 읽음 | 계정 돌려쓰기 자동화는 미지원. 일반 약관은 안 읽음 |
| (e) 2026년 변경과 제재 | 날짜 있는 변경 넷(02-20, 04-04, 06-15, 10-07) | 읽은 범위에서 못 찾음 | 2월 차단과 해제, 6월 플랜 이전, 11-06 사용자 보고 1건 |

## 읽은 방법

- 원문을 받아 조사 세션의 임시 폴더(`research/`)에 사본으로 저장했다. 열람 시각은 사본을 저장한 시각이다. 출처 표에 있다. 그 사본은 이 묶음에 넣지 않았다.
- 원본 보고서는 영어 문장을 그대로 인용했고, 그 인용을 모두 사본과 글자 단위로 맞춰 봤다. 어긋난 것이 없었다. 공백, markup, 따옴표 모양만 무시했다. 출처별 대조도 인용 표로 따로 했고 어긋난 것이 없었다. 틀린 문장을 넣으면 두 검사 모두 불일치로 나온다. 이 파생본은 그 인용을 뜻만 풀어 썼다. 풀어 쓴 문장은 그 검사를 거치지 않았다.
- [1차]는 벤더가 낸 문서다. [2차]는 기사, HN, 포럼, 이슈다. 2차도 원문을 읽었지만 벤더의 말은 아니다.
- 문서 페이지는 대부분 날짜가 없다. 그런 곳은 확인일만 있다.
- `legal-and-compliance`는 다시 받지 않았다. 16:25:46 사본을 썼다.
- 신뢰도(원본 보고서 기준): 1차 인용은 High. "내 해석"이라고 적은 줄은 Medium. 2차만 있는 사건은 Medium, 출처가 하나면 Low. 이 파생본에는 1차 인용 자리에 풀어 쓴 문장이 있다.

## Anthropic

### 허용하는 문장 [An1]

- 호스팅: 따로 합의하지 않았다면, 자기 제품이나 서비스에 Claude Code 를 미리 설치하거나 실행하려면 Commercial Terms of Service 에 동의하고 아래 조건을 지켜야 한다. 문서는 호스팅된 sandbox 와 그 밖의 agent 인프라를 예로 든다.
- 조건 1: Claude Code binary 를 수정하지 않는다. Anthropic 이 배포한 그대로 설치하고 실행한다. 고객은 그 안에 든 인증 방법을 빼거나 끄거나 제한하지 않는다.
- 조건 2: 고객은 자기 end user 를 대신해 Claude 사용량을 내거나 되팔거나 중개하지 않는다. end user 는 저마다 자기 Anthropic API 키, 자기 Claude 구독 플랜 자격증명, 자기 3P inference provider 자격증명 가운데 하나로 인증한다.
- 과금: 그 사용량은 end user 가 Anthropic 과 맺은 자기 계약에 따라 end user 에게 직접 청구된다. third-party inference provider 를 쓰면 그 provider 와의 계약에 따른다.
- 본인 로그인: end user 가 수정하지 않은 Claude Code binary 에 자기 Claude 구독으로 로그인하는 것도 막지 않는다. platform 이 위 호스팅 절에 적힌 대로 Claude Code 를 호스팅하는 경우도 여기에 든다.

### 금지하는 문장 [An1][An6]

- 개발자 [An1]: third-party 개발자가 자기 앱에 Claude.ai 로그인을 제공하는 것을 허용하지 않는다. 사용자를 대신해 Free, Pro, Max, Ultra 플랜 자격증명으로 요청을 보내는 것도 허용하지 않는다. 개발자는 Claude.ai 자격증명이나 session token 을 모으거나 보관하거나 중개하지 않는다. Claude 계정 로그인은 Anthropic 의 flow 안에서 끝나야 한다.
- 개발자의 기본 경로 [An1]: Claude 의 기능을 쓰는 제품이나 서비스를 만드는 개발자에게 Claude Console 이나 지원하는 cloud provider 의 API 키 인증을 쓰라고 한다. Agent SDK 를 쓰는 개발자도 같다.
- 계정 공유 [An6]: 계정 로그인 정보, Anthropic API 키, 계정 자격증명을 남과 나누지 않는다. 자기 계정을 남이 쓰게 하지도 않는다.
- 자동 접근 [An6]: bot 이나 script 같은, 자동화됐거나 사람이 아닌 수단으로 서비스에 접근하는 것이 금지 행위 목록의 한 항목이다. Anthropic API 키로 접근하는 경우와 Anthropic 이 따로 명시해 허용한 경우는 예외다. 아래 headless 문장들이 그 명시 허용에 해당한다고 읽었다(내 해석).
- 요청 중개를 금지한 문장은 Free, Pro, Max, Ultra 자격증명을 지목한다. 한도 문장은 Pro, Max, Ultra를 지목한다. Team과 Enterprise는 두 문장에 없다. 이 둘은 Commercial Terms 아래다 [An1]. 자격증명을 모으거나 보관하지 말라는 문장은 플랜을 가리지 않는다.

### 한도와 집행 [An1]

- Pro, Max, Ultra 플랜이 내건 사용 한도는 Claude Code 와 Agent SDK 의 보통의 개인 사용을 전제로 한다.
- OAuth 인증은 Claude Free, Pro, Max, Ultra, Team, Enterprise 구독 플랜을 산 사람만을 위한 것이다. Claude Code 와 그 밖의 Anthropic 자체 앱을 보통으로 쓰는 것을 받치게 설계됐다.
- Anthropic 은 이 제한을 집행하는 조치를 할 권리를 가진다. 사전 통지 없이 할 수 있다.
- 문의처: 자기 use case 에 허용되는 인증 방법이 궁금하면 sales 에 문의하라고 적는다.
- API 키는 사정이 다르다. 고객이 자기 키를 자기 사용자에게 나눠 주는 것은 막지 않는다. 문서는 고객이 자기 API 키나 third-party inference provider 자격증명을 마련하고 관리하는 방식은 제한하지 않는다고 적는다. 조건이 둘 있다. 그 사용량이 키 주인과 Anthropic(또는 해당 provider)의 계약에 따라 키 주인에게 청구된다. 위에 적은 재판매나 중개가 아니다.

### headless와 자동화 [An2][An3][An4]

- 구독으로 `claude -p` [An4, 글 안 날짜 2026-10-07]: 플랜에는 바뀌는 것이 없다. Claude 플랜으로 로그인해 있으면 Claude Agent SDK 와 `claude -p` 는 여전히 구독 한도에서 쓴다.
- 장수 토큰 [An2]: CI pipeline 이나 script 처럼 브라우저 로그인을 쓸 수 없는 환경에서는 `claude setup-token` 으로 1년짜리 OAuth token 을 만들라고 안내한다.
- 그 토큰의 범위 [An2]: 이 token 은 Claude 구독으로 인증한다. Pro, Max, Ultra, Team, Enterprise 플랜 가운데 하나가 있어야 한다. 모델 요청만 할 수 있다. Remote Control 세션을 열거나 claude.ai connector 를 가져오지는 못한다.
- 그 토큰의 보관 [An2]: 명령은 token 을 어디에도 저장하지 않는다. 사람이 복사해서 인증할 곳의 환경 변수 `CLAUDE_CODE_OAUTH_TOKEN` 에 넣는다.
- bare [An2]: bare mode 는 `CLAUDE_CODE_OAUTH_TOKEN` 을 읽지 않는다. script 가 `--bare` 를 넘기면 `ANTHROPIC_API_KEY` 나 `apiKeyHelper` 로 인증해야 한다.
- bare [An3]: bare mode 에서 Claude Code 는 OAuth 자격증명과 system keychain 을 읽지 않는다. 같은 글은 bare mode 가 구독 로그인을 쓰지 않는다고도 적는다.
- bare의 앞날 [An3]: `--bare` 는 script 와 SDK 호출에 권하는 mode 다. 앞으로 나올 release 에서 `-p` 의 기본값이 된다.
- 무인 세션 [An2]: 미리 갱신하는 일은 사람 없이 도는 세션에 가장 중요하다. agent view 의 background 세션이나 Remote Control 세션이 로그인보다 오래 살면, 자격증명이 만료되는 때부터 멈춘다. 다시 로그인할 때까지 회복하지 못한다.

### 로그인이 놓이는 곳과 우선순위 [An2][An5]

- 계정마다 디렉터리 [An2]: 회사 계정과 개인 계정처럼 여러 계정에 한꺼번에 로그인해 두려면 계정마다 설정 디렉터리를 따로 준다. `claude` 를 띄울 때 환경 변수 `CLAUDE_CONFIG_DIR` 을 쓰려는 계정의 디렉터리로 둔다.
- 자격증명 파일 [An2]: `CLAUDE_CONFIG_DIR` 을 정하면 Claude Code 는 `.credentials.json` 을 그 디렉터리 아래에 둔다. macOS fallback 이 쓰는 파일도 같다. macOS Keychain 항목도 그 디렉터리에 묶인다. 그래서 `CLAUDE_CONFIG_DIR` 이 다른 세션은 다른 항목을 읽는다.
- API 키가 구독보다 앞선다 [An2]: non-interactive mode(`-p`)에서는 키가 있으면 늘 그 키를 쓴다.
- 같은 내용 [An5]: 시스템에 환경 변수 `ANTHROPIC_API_KEY` 가 있으면 Claude Code 는 Claude 구독(Pro, Max, Ultra, Team, Enterprise 플랜) 대신 그 API 키로 인증한다. 그러면 구독에 포함된 사용량을 쓰지 않고 API 사용 요금이 나온다.
- profile은 디렉터리 밖에 있다 [An2]: profile 은 Anthropic 설정 디렉터리에 있는, 이름 붙은 자격증명 설정 파일이다. 그 디렉터리의 기본값은 macOS 와 Linux 에서 `~/.config/anthropic` 이다.
- 같은 글: API 키 없는 Claude Console 로그인 둘은 디렉터리를 나눠도 갈리지 않는다. Claude Code 가 그런 로그인을 설정 디렉터리 밖에 두기 때문이다.
- active profile의 순위 [An2]: auth mode 가 `oidc_federation` 이면 `/login` 자격증명보다 앞선다. `user_oauth` 면 동작하는 `/login` 자격증명보다 뒤다.
- 조직 제한의 빈 곳 [An2]: `claude setup-token` 과 `/install-github-app` 은 `forceLoginMethod` 만 강제한다. 그래서 다른 조직의 token 을 만들 수 있다.

### self-hosted와 gateway [An7][An8]

- [An7]: self-hosted environment 는 Team 과 Enterprise 플랜에서 public beta 이고 기본으로 꺼져 있다.
- [An7]: 늘 켜 둔 자기 기계에서 Claude Code 를 돌리고 다른 기기에서 몰려면 Remote Control 을 쓰라고 적는다. Remote Control 은 Pro, Max, Ultra 플랜에서도 쓸 수 있다.
- [An8] gateway 자격증명으로 붙으면 구독을 쓰지 않는다. 문서는 그 사람들의 claude.ai 구독이 쓰이지도 청구되지도 않는다고 적는다.

### 2026년에 바뀐 것

- 02-20 [An9, 2차]: The Register가 그때의 legal 문구를 인용했다. Claude Free, Pro, Max 계정으로 얻은 OAuth token 을 다른 제품, 도구, 서비스에서 쓰는 것은 허용하지 않고 Consumer Terms of Service 위반이라는 문구다. Agent SDK 도 거기에 든다고 적혀 있었다. 지금 문서에는 이 문장이 없다(16:25:46 사본에서 `any other product` 검색 0건). 같은 기사: OpenCode가 목요일(02-19)에 Claude 구독 지원을 지웠다.
- 04-03 [An10, 2차]: 사용자가 HN에 올린 Anthropic 메일(1,099점). 4월 4일 12pm PT(8pm BST)부터 OpenClaw 를 비롯한 third-party harness 에는 Claude 구독 한도를 쓸 수 없다는 내용이다. Claude 계정으로 계속 쓸 수는 있지만 extra usage 가 든다. extra usage 는 구독과 따로 청구되는 종량제다. 공식 제품은 그대로다. 구독은 Claude Code 와 Claude Cowork 를 비롯한 모든 Claude 제품에 여전히 통한다. 범위: 이 정책은 모든 third-party harness 에 적용되고 곧 더 많은 곳으로 넓힌다고 적혀 있다.
- 04-06 [An11, 2차]: InfoWorld가 Claude Code 책임자의 말을 실었다. 구독은 이런 third-party 도구의 사용 패턴에 맞춰 만든 것이 아니라는 말이다.
- 04-21 [An12, 2차, 출처 하나]: HN 에 올라온 글의 제목은 OpenClaw 방식의 Claude CLI 사용이 다시 허용됐다고 Anthropic 이 말했다는 것이다(511점). 링크는 OpenClaw 문서다. 그 문서는 로그인과 구독을 Claude Code 가 가지고, OpenClaw 는 그 로그인을 저장하거나 갱신하지 않는다고 적는다. Anthropic이 직접 낸 글은 못 찾았다.
- 06-15 [An13, 2차]와 [An4, 1차]: 5월에 예고한 전환은 Claude Agent SDK, `claude -p`, Agent SDK 로 만든 third-party 앱을 구독 rate limit 에서 떼어 전용 월 credit 으로 옮기는 것이었다. 당일 보류했다. 메일은 그 변경을 그날 하지 않는다고 알렸다. 1차 문서도 같다. 2026-06-15 갱신 글은 예고한 Claude Agent SDK 사용 변경을 멈췄다고 적는다. 지금은 바뀐 것이 없고 Claude Agent SDK, `claude -p`, third-party 앱 사용은 여전히 구독 한도에서 쓴다고 적는다. 메일은 뒤를 열어 둔다. 사용자가 Claude 구독으로 만드는 방식을 더 잘 받치도록 플랜을 고치는 중이라고 적었다.
- 10-07 [An4, 1차]: 2026-10-07 갱신 글은 Claude Max, Ultra, Team 플랜에 월 API credit 이 들어간다고 적는다. 그 credit 은 Claude API 와 Claude Managed Agents 에 쓰인다. 연결한 Claude Console 조직의 API 키로 돌리는 Claude Agent SDK 와 `claude -p` 에도 쓰인다.

### 문서에 없는 것

- 자기 팀만 쓰는 self-hosted 서버가 문서가 말하는 고객의 제품이나 서비스에 드는지. 든다면 Commercial Terms 동의가 조건이다. Commercial Terms 원문은 받지 않았다.
- 보통의 개인 사용이 어디까지인지. 숫자도 예도 없다.
- 구독으로 상시 실행 agent를 돌리는 것을 직접 다룬 문장.
- wrapper와 third-party harness의 경계를 적은 1차 문장.

### 이 판정을 뒤집을 수 있는 근거

- legal 문서는 제품을 만드는 개발자에게 API 키를 쓰라고 한다(위 「개발자의 기본 경로」). 서버가 사람 대신 턴을 시작하는 상시 agent는 보통의 사용에서 멀다.
- 5월에 예고했다가 보류한 전환이 `claude -p`와 Agent SDK를 구독 한도에서 떼는 것이었다. 다시 시행하면 구독 Runtime의 과금이 바뀐다.
- 04-04 조치의 대상은 third-party harness다. 공식 CLI를 띄우는 서버가 거기에 드는지는 1차 문장이 없다. 다시 허용됐다는 말의 출처는 OpenClaw 문서다.

## OpenAI

### 로그인과 headless [Oa1][Oa3]

- 원격 로그인을 문서가 안내한다 [Oa1]: CLI 를 원격이나 headless 환경에서 돌리는 경우를 든다. 이럴 때는 device code 인증(beta)을 먼저 쓰라고 적는다.
- 로그인 파일을 옮기는 길도 있다 [Oa1]: 브라우저가 있는 기계에서 로그인을 끝낼 수 있으면, 저장된 자격증명을 headless 기계로 복사할 수 있다고 적는다.
- 그 파일의 무게 [Oa1]: `~/.codex/auth.json` 은 access token 이 들어 있으니 비밀번호처럼 다루라고 적는다. commit 하지 말고, ticket 에 붙이지 말고, chat 에 공유하지 말라고 한다.
- `codex exec` [Oa3]: `codex exec` 는 저장된 CLI 인증을 기본으로 다시 쓴다.
- 권하는 쪽 [Oa1]: CI/CD job 같은 programmatic Codex CLI workflow 에는 API 키 인증을 쓰라고 적는다. 신뢰할 수 없거나 공개된 환경에 Codex 실행을 내놓지 말라고도 적는다.
- 같은 글: 자동화에는 여전히 API 키가 권하는 기본값이다.
- [Oa3]: 자동화에는 API 키가 맞는 기본값이다. 발급하고 교체하기가 더 쉽기 때문이라고 적는다.
- [Oa5] 요금 표의 API Key 카드: CI 같은 공유 환경의 자동화에 좋다고 적는다.

### 구독 로그인으로 자동화할 때의 조건 [Oa2]

- 자동화를 인증하는 바른 방법은 API 키다. 이 안내는 workflow 를 꼭 자기 Codex 계정으로 돌려야 할 때만 쓰라고 적는다.
- 이것은 enterprise 와 그 밖의 신뢰할 수 있는 사설 자동화를 위한 고급 workflow 다. CI/CD job 대부분에는 여전히 API 키를 권한다.
- 다섯 조건이 모두 맞아야 한다. 그 가운데 셋은 이렇다. runner 가 신뢰할 수 있는 사설 인프라다. 갱신된 `auth.json` 을 실행 사이에 보존할 수 있다. `auth.json` 사본 하나는 기계 하나나 순서대로 도는 job 흐름 하나만 쓴다.
- 운영 규칙: runner 마다, 또는 순서대로 도는 workflow 흐름마다 `auth.json` 하나를 쓴다. 같은 파일을 동시에 도는 job 이나 여러 기계가 나눠 쓰지 않는다.
- 다시 로그인해야 하는 경우의 하나: 다른 기계나 동시에 돈 job 이 token 을 먼저 교체한 경우다.
- 공개 저장소나 open-source 저장소에는 이 workflow 를 쓰지 말라고 적는다.

### access token [Oa4]

- Codex access token 은 지금 ChatGPT Business 와 Enterprise workspace 에서 지원한다.
- runner 신뢰: 공개 CI, fork 에서 온 pull request, 공유 기계는 token 을 workspace 밖 사람에게 드러낼 수 있다. access token 은 신뢰하는 runner 에서만 쓴다.
- 공유 신원: 한 사람의 token 을 관계없는 팀들이 돌려쓰면 소유와 감사 기록이 흐려진다.

### third-party 앱이 구독을 쓰는 공식 경로 [Oa6]

- Sign in with ChatGPT 는 지금 고른 commercial partner 에게 limited trial 로 열려 있다. ChatGPT plan usage 는 모든 open-source partner 와 고른 private client 에게 열려 있다.
- ChatGPT plan usage 는 Sign in with ChatGPT 안의 선택 기능이다. open-source 앱은 identity scope 에 더해, 자격이 되는 Responses API 요청에 사용자의 ChatGPT 플랜을 쓰는 권한을 요청할 수 있다.
- 범위: 이 문서는 open-source·로컬 호스팅 앱의 ChatGPT plan usage 를 설명한다. 유료이거나 원격에서 호스팅하는 앱에 넣으려면 interest form 을 내라고 적는다. 원문의 앞 구절은 두 조건을 다 갖춘 앱으로도, 두 종류의 앱으로도 읽힌다.
- 묶이는 단위: 발급된 `client_id` 마다 인증한 사용자와 등록 때 고른 workspace 에 묶인다.
- 원격 VM: open-source 앱을 원격 VM(virtual machine)에서 돌릴 때 쓰는 안내가 따로 있다. 자격증명은 사람이 옮긴다. 고른 registration 의 보호된 자격증명 파일을 SSH 같은 안전한 channel 로, 그 도구가 문서에 적은 VM 경로에 옮기라고 적는다.
- 아직 없는 것: 옮긴 세션에 대해 host 별로 사용량을 귀속하는 기능과 ChatGPT plan 접근을 회수하는 기능은 아직 없다.
- 한도: ChatGPT Plus 사용자의 5시간 사용 한도는 그 사람이 ChatGPT 플랜을 쓰는 모든 앱이 나눠 쓴다. private client 와 open-source client 도 거기에 든다.
- 갱신: 같은 세션의 갱신은 순서대로 하라고 적는다. 두 프로세스가 교체되는 token 을 두고 다투지 않게 하려는 것이다.
- open-source 앱은 대기 명단 없이 로그인 때 등록한다. 첫 등록은 `client_id=dynamic_agent_client` 로 시작한다. host 의 `ext_agent_host_id` 를 넣는다. `agent_name_hint` 에는 앱의 실제 이름을 설치마다 같게 적는다. 상업 partner는 대기 명단이다. 문서는 Sign in with ChatGPT 를 지금 고른 commercial partner 들에게 제공한다고 적는다.
- Codex app-server도 이 토큰으로 돌릴 수 있다. 문서는 ChatGPT plan usage 권한이 있는 OAuth access token 을 쓰게 Codex app-server 를 설정하라고 적는다. 갱신은 앱 몫이다. 앱이 OAuth token 을 갱신해야 한다고 적는다.
- 이 길에서는 앱이 토큰을 쥔다. 사람이 CLI에 직접 로그인하는 길과 다르다. Anthropic과 Google의 문서에는 이런 길이 없다. 문서는 이 기능을 preview라고 부른다.
- 발표일은 2차뿐이다 [Oa7]: OpenAI 가 2026-09-29 DevDay 에서 launch partner 16곳과 함께 발표했다고 적는다.

### 읽지 못한 것

- Terms of Use(`https://openai.com/policies/row-terms-of-use/`)는 403이다. 계정 공유 조항을 확인하지 못했다.
- help.openai.com 글(`https://help.openai.com/en/articles/20001542-using-your-chatgpt-plan-in-other-apps-and-sites`)도 403이다.
- 제재 사례는 읽은 범위에서 못 찾았다. 없다는 뜻은 아니다.

## Google

### 약관과 FAQ [Go1][Go2][Go5]

- 약관 [Go1]: 서비스를 남용하거나 해치거나 방해하지 말라고 적는다. Google 이 제공하지 않은 제품과 엮어 서비스를 쓰는 것도 거기에 든다. third party software, 도구, 서비스로 이 서비스에 접근하는 것은 계약 위반이다. 약관은 Antigravity OAuth 를 OpenClaw 와 쓰는 것을 예로 든다. 그러면 Antigravity 계정이나 Gemini CLI 계정이 정지되거나 해지될 수 있다.
- FAQ 질문 [Go2]: Antigravity 로그인으로 third-party software(Claude Code, OpenClaw, OpenCode 같은 것)를 왜 못 쓰느냐는 질문이다. 답: third-party software, 도구, 서비스로 Antigravity 에 접근하는 것은 Terms of Service 위반이고 정당한 사용자의 경험을 크게 떨어뜨린다. 계정이 정지되거나 해지될 수 있다. Gemini 를 third-party coding agent 와 쓰려면 Gemini Enterprise 나 Google AI Studio 의 API 키를 권한다.
- FAQ 질문 [Go2]: Antigravity CLI 의 headless mode 를 third-party coding agent 안에서 쓰거나 계정 전환을 자동화해도 되느냐는 질문이다. 답: Antigravity CLI headless mode(`agy -p`)는 직접 쓰는 script 와 CI workflow 를 위한 것이다. `agy` 를 third-party coding agent 나 앱 안에 감싸는 것, 계정 돌려쓰기를 자동화하는 것은 소비자 플랜에서 지원하지 않는다.
- Gemini CLI 쪽 [Go5, 문구가 들어온 커밋 2026-02-27]: Gemini CLI 를 받치는 서비스(예로 Gemini Code Assist 서비스)에 third-party software, 도구, 서비스로 직접 접근하는 것은 적용되는 약관과 정책 위반이다. 문서는 Gemini CLI OAuth 를 OpenClaw 와 쓰는 것을 예로 든다. 계정이 정지되거나 해지될 수 있다.

### headless와 플랜 [Go3][Go4][Go6][Go7]

- [Go3]: Antigravity CLI 를 non-interactive 로 돌려 agent 작업을 script 로 만들고, CI pipeline 에 붙이고, 기계가 읽는 출력을 받는다고 소개한다.
- [Go3]: headless mode 는 저장된 자격증명을 쓴다. 먼저 interactive `agy` 세션으로 한 번 인증하라고 적는다.
- [Go4]: Google Antigravity 는 개인 계정에는 Google Terms of Service 에서 나온 약관으로, 팀에는 Gemini Enterprise 의 Google Cloud 약관으로 제공된다. 팀 쪽 약관은 읽지 않았다.
- [Go4] 지원하지 않는 것: rate limit 을 더 받으려고 자기 키(BYOK, bring-your-own-key)나 자기 endpoint 를 가져오는 것.
- [Go7, 2026-05-19]: 2026-06-18 에 Gemini CLI 와 Gemini Code Assist IDE extension 이 Google AI Pro 와 Ultra 의 요청을 받지 않게 된다고 알린다. Gemini Code Assist for individuals 로 무료로 쓰는 사람도 같다.
- [Go6]: 무료 tier 와 Google AI 플랜이 없다고 적는다. 무료 개인 접근과 Google AI Pro, Ultra(Google One)는 2026-06-18 에 Antigravity CLI 로 옮겼다.

### 제재와 그 뒤 [Go8][Go9][Go10]

- 02-27 [Go8, Maintainer 표시가 붙은 글]: 차단 이유는 3rd party 도구나 proxy 로 Antigravity 자원과 quota 에 접근한 것이다. 풀어 준 방식은 ToS 위반으로 최근 표시된 계정을 시스템 전체에서 자동으로 차단 해제하는 것이다. 다음부터는 영구 차단이다. 계정이 ToS 를 두 번째로 위반했다고 표시되면 영구히 차단된다.
- 09-15 [Go9, 2차]: 포럼에서 한 사용자가 외부 orchestration이 되느냐고 물었다. 같은 날 달린 답은 완전히 지원한다고 했다. 공식 `agy` binary 를 로컬 child process 로 headless mode 에서 띄우는 것은 지원하는 workflow 이고, 보통의 interactive CLI 사용과 똑같은 계정 권리와 구독 한도를 쓴다는 답이다. 원본 보고서는 이 답의 가운데를 줄여 옮겼다. 같은 답은 지원하지 않는 것도 적었다. disk 에서 OAuth token 을 꺼내는 것, 자격증명을 자기 HTTP client 에서 다시 쓰는 것, Antigravity backend endpoint 를 직접 부르는 것이다.
- 답한 계정은 Google 직원 표시가 없다(포럼 JSON의 staff, admin, moderator가 모두 false, trust level 1). 10-27에 다른 사용자가 FAQ와 어긋난다고 물었고 답이 없다. 이 답은 Google의 말로 쓸 수 없다. FAQ가 우선이다.
- 11-06 [Go10, 2차, 출처 하나]: proxy 사용자의 보고. 오래 돌린 pool 의 Antigravity OAuth 자격증명 셋 가운데 둘이 403 `PERMISSION_DENIED`, reason `TOS_VIOLATION` 을 돌려주기 시작했다는 내용이다. OAuth를 직접 쓴 경우라 이 설계와는 다르다.
- 읽은 제재 사례는 모두 OAuth를 직접 쓴 third-party 도구나 proxy다. 공식 `agy`를 감싼 앱이 제재받은 사례는 못 찾았다.

## 약관 문장이 설계와 코드에 닿는 곳

코드는 worktree `authz-d1-1-20261108`의 HEAD `9424cc7b5394`에서 읽기만 했다. 빌드와 실행은 하지 않았다.

1. Claude 로그인은 사람이 `claude` 안에서 끝낸다. 서버는 `CLAUDE_CONFIG_DIR` 경로만 정한다. `.credentials.json`은 Claude Code가 그 디렉터리에 쓴다. 서버 코드가 그 파일을 읽거나 토큰을 넘기면, 자격증명을 모으거나 보관하거나 중개하지 말라는 금지 문장에 걸릴 수 있다. 허용 문장과 금지 문장을 같이 읽은 내 해석이다. `lib`와 `bin`에 `credentials.json`을 이름으로 부르는 코드는 없다(rg 0건). 계정 이메일은 `.claude.json`의 `oauthAccount.emailAddress`에서 읽는다(`lib/runtime/runtime_account_email.mli:11`). 자격증명이 아니다.
2. `claude setup-token`으로 만든 토큰을 서버가 받아 보관하는 방식은 쓰지 않는다. 같은 금지 문장에 걸린다(내 해석). 조직 제한도 이 명령은 비켜 간다 [An2].
3. 사람 하나에 구독 하나다. Runtime 공유는 API 키 Runtime에만 열 수 있다. 근거는 조건 2와 계정 공유 조항, 그리고 API 키 예외 문장이다.
4. 확인함: 계정 디렉터리를 선언하면 Claude child는 기본 이름만 물려받는다(`lib/runtime/runtime_claude_environment_projection.ml:44-45`, `lib/runtime/runtime_official_account.ml:129-136`). `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`이 넘어가지 않는다. 운영자의 API 키가 사람의 구독을 덮는 일을 이미 막는다. Codex도 같다(`lib/runtime/runtime_codex_environment_projection.ml:41-47`).
5. 확인 필요(실측 안 함): `lib/runtime/runtime_claude_environment_projection.ml:5-9`가 `HOME`과 `XDG_CONFIG_HOME`을 물려준다. 문서상 Anthropic profile은 `~/.config/anthropic`에 있고 `CLAUDE_CONFIG_DIR` 밖이다. 서버 OS 사용자에게 profile이 있으면 `oidc_federation`은 사람의 `/login`보다 앞서고, `user_oauth`는 사람의 로그인이 만료됐을 때 대신 쓰인다. 그러면 운영자 조직이 그 사람의 사용량을 낸다. 조건 2와 반대다. 확인 방법: profile이 있는 host에서 빈 `CLAUDE_CONFIG_DIR`로 `claude`를 띄우고 `/status`에 `Profile` 행이 뜨는지 본다.
6. `-p`의 기본이 bare로 바뀌는 release에서 구독 경로가 끊길 수 있다. Claude Code 버전마다 "구독 로그인으로 `-p`가 도는가"를 탐침한다.
7. 로그인이 만료되면 사람이 다시 로그인해야 한다. 서버가 대신 갱신할 길이 없다. 만료를 Keeper 상태로 보여 준다.
8. Codex는 사람마다 `CODEX_HOME` 하나를 두고 `auth.json`을 한 기계에만 둔다. 스케일아웃하면 그 사람의 Codex 턴은 그 파일이 있는 node에 묶인다. 원격 로그인은 device code가 문서의 첫 길이다. 계정 이메일은 `auth.json`의 `tokens.id_token`에서 읽는다(`lib/runtime/runtime_account_email.mli:10`). 토큰 파일을 여는 코드다. 이를 막는 문장은 OpenAI 문서에서 못 찾았다.
9. 확인 필요: `Runtime_verification_codex_home.prepare`가 `auth.json`을 임시 `CODEX_HOME`으로 복사한다(`lib/runtime/runtime_verification_codex_home.mli:9-13`, 부르는 곳 `lib/runtime/runtime_codex_model_refresh.ml:24`, `lib/runtime/runtime_verification.ml:1033`). 사본에서 토큰이 갱신되고 사본이 버려지면 원본 로그인이 끊길 수 있다. [Oa2]가 다시 로그인해야 하는 경우로 든 것, 곧 다른 기계나 동시에 돈 job 이 token 을 먼저 교체한 경우가 이것이다.
10. Google AI Pro와 Ultra 로그인은 다계정 Runtime 종류에서 뺀다. 코드는 이미 다계정에서 Antigravity HOME을 만들지 않는다(`lib/runtime/runtime_antigravity_home.mli:11-13`). Gemini를 쓰려면 API 키 경로다.
11. 확인 필요(운영자 몫): 단일 사용자 서버의 Antigravity Runtime은 운영자의 로그인 사본을 관리 HOME에 두고 `agy`를 띄운다(같은 파일 1~13줄). 운영자 계정이 소비자 플랜이면 [Go2]가 소비자 플랜에서 지원하지 않는다고 적은 경우에 해당한다. 계정 종류는 내가 알 수 없다. [Go8]은 두 번째 위반을 영구 차단이라고 적는다.
12. 벤더에 물어야 닫히는 것 둘: 자기 팀만 쓰는 서버가 문서가 말하는 고객의 제품이나 서비스에 드는가. 보통의 개인 사용이 상시 실행 agent를 품는가. 문의처는 legal 문서가 적은 contact sales다.

## 하위 보고 셋을 묶은 결론

1. 구독으로 팀 서버를 돌릴 길은 Claude(조건부)와 Codex(비권장 경로) 둘이다. 조건은 같다. 로그인은 사람이 하고, 실행은 수정 없는 공식 CLI가 하고, 서버는 토큰을 만지지 않는다. masc의 "사람이 소유한 구독 Runtime을 서버가 띄운다"는 이 모양과 맞는다.
2. 벤더 플랫폼(Claude Code, Managed Agents, Cursor, Devin, OpenAI Agents API)은 같은 스케일아웃 모양을 쓴다. loop은 중앙에 있고, 실행기는 밖에서 붙어 일감을 가져간다. Claude Code와 Devin은 lease로 쥔다. 구독 CLI는 제약을 하나 더한다. 로그인 파일이 있는 기계에 그 사람의 턴이 묶인다.
3. 조사한 오픈소스 오케스트레이터 가운데 무료 판에서 팀 계정과 사람별 벤더 자격증명을 같이 주는 곳을 못 찾았다. 구독 계정별 한도를 아는 스케줄링도 비어 있다. masc가 가려는 자리다.
4. 커뮤니티(HN 위주 표본)에서 가장 자주 나온 불만 둘이 비용 귀속과 약관 불안이다. 사람별 구독은 비용 귀속을 구조로 푼다. 약관 불안은 설치 문서에 "어느 문장에 기대는가"를 적어야 풀린다. 위 Anthropic 허용 문장들이 그 재료다.
5. 가장 큰 위험은 정책 변동이다. Anthropic은 2026년에 날짜 있는 변경이 넷이고, 사전 통지 없이 집행할 수 있다고 적는다. Google은 2월에 계정을 막았다 풀었다. 같은 Keeper가 구독 Runtime과 API 키 Runtime 사이를 옮겨 갈 수 있어야 한다.
6. 아무도 못 푼 것도 같다. tool 효과의 멱등성은 읽은 벤더 문서 어디에도 없다. host 재부팅을 넘는 CLI 세션 복구는 조사한 오픈소스가 못 채웠다.

## 출처

열람은 모두 2026-11-10 KST다. 「사본」 열의 파일은 조사 세션의 임시 폴더에 있었고 이 묶음에는 넣지 않았다.

| 키 | 등급 | URL | 문서 날짜 | 열람 | 사본 |
|---|---|---|---|---|---|
| An1 | 1차 | https://code.claude.com/docs/en/legal-and-compliance | 없음 | 16:25:46 | `legal.md` |
| An2 | 1차 | https://code.claude.com/docs/en/authentication | 없음 | 17:26:11 (16:25에 요약 도구로 먼저 읽음) | `cc-authentication.md` |
| An3 | 1차 | https://code.claude.com/docs/en/headless | 없음 | 17:26:12 (16:25에 요약 도구로 먼저 읽음) | `cc-headless.md` |
| An4 | 1차 | https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan | 글 안 2026-10-07, 2026-06-15 | 16:27:23 | `agent-sdk-plan.html` |
| An5 | 1차 | https://support.claude.com/en/articles/11145838-use-claude-code-with-your-pro-max-or-ultra-plan | 없음 | 17:07:27 | `claude-code-plan.html` |
| An6 | 1차 | https://www.anthropic.com/legal/consumer-terms | 시행 2025-10-08 | 16:29:11 | `anthropic-consumer-terms.html` (한국어로 떠서 페이지 안 영어 원문 데이터에서 찾음) |
| An7 | 1차 | https://code.claude.com/docs/en/self-hosted-environments | 없음 | 17:08:54 | `cc-self-hosted-environments.md` |
| An8 | 1차 | https://code.claude.com/docs/en/gateways | 없음 | 17:08:55 | `cc-gateways.md` |
| An9 | 2차 | https://www.theregister.com/software/2026/02/20/anthropic-clarifies-ban-on-third-party-tool-access-to-claude/5014546 | 2026-02-20 | 17:26:18 | `register-0220.html` |
| An10 | 2차 | https://news.ycombinator.com/item?id=47633396 | 2026-04-03 | 17:26:13 | `hn-47633396.json` |
| An11 | 2차 | https://www.infoworld.com/article/4154435/anthropic-cuts-openclaw-access-from-claude-subscriptions-offers-credits-to-ease-transition.html | 2026-04-06 | 17:26:19 | `infoworld-0406.html` |
| An12 | 2차, 출처 하나 | https://news.ycombinator.com/item?id=47844269 , https://docs.openclaw.ai/providers/anthropic | 2026-04-21 | 17:26:16, 17:10:54 | `hn-47844269.json`, `openclaw-anthropic.md` |
| An13 | 2차 | https://news.ycombinator.com/item?id=48546618 | 2026-06-15 | 17:26:14 | `hn-48546618.json` |
| Oa1 | 1차 | https://learn.chatgpt.com/docs/auth | 없음 | 16:26:35 | `codex-auth.html` |
| Oa2 | 1차 | https://learn.chatgpt.com/docs/auth/ci-cd-auth | 없음 | 16:28:13 | `oai/codex_auth_ci-cd-auth.md` |
| Oa3 | 1차 | https://learn.chatgpt.com/docs/non-interactive-mode | 없음 | 16:28:15 | `oai/codex_noninteractive.md` |
| Oa4 | 1차 | https://learn.chatgpt.com/docs/enterprise/access-tokens | 없음 | 16:28:13 | `oai/codex_enterprise_access-tokens.md` |
| Oa5 | 1차 | https://learn.chatgpt.com/docs/pricing | 없음 | 16:28:14 | `oai/codex_pricing.md` |
| Oa6 | 1차 | https://developers.openai.com/siwc/llms-full.txt (낱장은 https://developers.openai.com/siwc/token-sharing-open-source 아래) | 없음 | 17:06:58, 낱장 16:28:12 | `oai/siwc-full.txt`, `oai/siwc_*.md` |
| Oa7 | 2차 | https://flaviocopes.com/sign-in-with-chatgpt/ | 2026-10-02 | 17:26:19 | `flaviocopes-siwc.md` |
| Go1 | 1차 | https://antigravity.google/terms | 없음 | 16:27:25 | `antigravity-terms.html` |
| Go2 | 1차 | https://antigravity.google/docs/faq/ | 없음 | 16:30:45 | `agy-faq.html` |
| Go3 | 1차 | https://antigravity.google/docs/cli/headless/ | 없음 | 16:30:46 | `agy-headless.html` |
| Go4 | 1차 | https://antigravity.google/docs/plans/ | 없음 | 17:07:28 | `agy-plans.html` |
| Go5 | 1차 | https://github.com/google-gemini/gemini-cli/blob/main/docs/resources/tos-privacy.md | 문구 커밋 2026-02-27, 마지막 커밋 2026-04-10 | 16:27:23, 커밋 목록 17:28 | `gemini-tos.md`, `gemini-tos-commits.json` |
| Go6 | 1차 | https://github.com/google-gemini/gemini-cli (README) | 없음 | 16:29:25 | `gemini-readme.md` |
| Go7 | 1차 | https://developers.googleblog.com/an-important-update-transitioning-gemini-cli-to-antigravity-cli/ | 2026-05-19 | 16:29:49 | `gcli-transition.html` |
| Go8 | 1차(Maintainer 글) | https://github.com/google-gemini/gemini-cli/discussions/20632 | 2026-02-27 | 17:08:23 | `disc20632.html` |
| Go9 | 2차 | https://discuss.ai.google.dev/t/is-external-orchestration-of-antigravity-cli-headless-mode-supported-with-account-based-usage/183051 | 2026-09-15, 2026-10-27 | 16:30:48 | `forum-183051.json` |
| Go10 | 2차, 출처 하나 | https://github.com/router-for-me/CLIProxyAPI/issues/7296 | 2026-11-06 | 17:26:16 | `cliproxy-7296.json` |

읽지 못했거나 읽지 않은 것:

- OpenAI Terms of Use와 help.openai.com 글: 403.
- Anthropic Commercial Terms, Google 일반 Terms of Service, Gemini Enterprise 약관: 받지 않았다.
- GitHub Copilot, Meta 같은 다른 벤더: 검색 요약만 봤다. 판정하지 않는다.
- 403을 돌아가는 reader proxy는 권한 분류기가 거절했고 다시 시도하지 않았다.

검증 스크립트(`check_quotes.py`)와 인용 표(`quotes.tsv`)는 조사 세션의 임시 폴더에 있었고 이 묶음에는 넣지 않았다.
