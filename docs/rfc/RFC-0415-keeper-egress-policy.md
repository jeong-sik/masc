---
rfc: "0415"
status: Draft
---

# RFC-0415 — keeper egress 에 none 과 inherit 사이를 만든다

- Status: Draft
- Decision driver: `network_mode` 가 스위치 하나다. 라이브 키퍼 14개 중 **12개가
  `inherit`** 이고, GitHub 하나 쓰려고 인터넷 전체가 열려 있다. 좁힐 방법이
  `none` 밖에 없는데 그러면 `gh` 도 `git` 도 죽는다.
- Area: `lib/keeper_types_profile_sandbox/`,
  `lib/keeper/keeper_sandbox_microvm.ml`, `lib/keeper/keeper_turn_sandbox_runtime.ml`,
  `config/keepers/*.toml`
- Related: RFC-0405(microVM 백엔드), RFC-keeper-github-apps(토큰 수명·범위),
  `docs/superpowers/specs/2026-08-27-openssh-microvm-exec-design.md` §4.1

## 지금 무엇이 없나

```ocaml
type network_mode = Network_none | Network_inherit
```

중간이 없다. 그리고 나가는 트래픽을 보는 자리가 어디에도 없다.

| 라이브 실측 (2026-09-04, `.masc/config/keepers/*.toml`) | |
|---|---|
| `network_mode = "inherit"` | 12 |
| `network_mode = "none"` | 2 |

masc 는 도구 호출·승인·파일 쓰기를 전부 원장에 남긴다. **네트워크만 비어
있다.** 키퍼가 오늘 어디에 접속했는지 답할 수 있는 기록이 없다.

egress 프록시는 없다 (`rg 'egress.*proxy|policy_proxy' lib/` → 0건).

## 제안

`Network_policy` 를 더한다. 나가는 트래픽이 masc 서버가 여는 프록시를 지나고,
프록시가 키퍼별 목적지 allowlist 로 판정한다.

```toml
sandbox_profile = "microvm"
network_mode = "policy"

[keeper.egress]
allow = ["github.com", "api.github.com", "dl-cdn.alpinelinux.org"]
```

### D1. variant 를 더하는 값을 먼저 잰다

RFC-0405 는 프로필 변형을 안 늘렸다. 45개 파일이 전수 매치하는데 그 45곳이
답할 질문이 백엔드가 아니었기 때문이다. 여기는 다르다.

`network_mode` 를 전수 매치하는 파일은 **lib+bin 17개, 테스트 포함 26개**다.
그리고 그 자리들이 답할 질문이 정확히 "이 모드에서 나가는 트래픽을 어떻게
하나" 다 — variant 가 물어야 할 질문 그 자체다. 컴파일러가 17곳에 답을
강요하는 것이 이득이다.

번역 지점도 이미 하나로 모여 있다.

```ocaml
(* keeper_sandbox_microvm.ml:114 *)
let network_args_for backend ~dns (mode : network_mode) = ...
```

백엔드마다 이 함수 하나가 argv 를 낸다. `Network_policy` 는 여기서 프록시
주소를 게스트에 주는 argv 로 번역된다.

### D2. 프록시는 masc 서버가 소유한다

OpenShell 은 Gateway 라는 별도 컨트롤 플레인을 세운다. masc 는 그 자리가 이미
있다 — 서버가 키퍼 수명·정책·자격증명을 이미 소유한다. 새 플레인을 세우지
않고 프록시를 서버에 붙인다.

### D3. 모르는 목적지는 거부지 통과가 아니다

allowlist 에 없는 목적지는 거부한다. 로그만 남기고 통과시키지 않는다.
`Network_inherit` 은 그대로 남아 있으니, 열어두고 싶으면 그걸 고르면 된다.
`policy` 를 골랐는데 조용히 열리는 경우가 있으면 안 된다.

### D4. 거부와 허용 둘 다 증거다

프록시를 지나는 모든 요청이 이벤트가 된다. 목적지·판정·시각. 이것이 이 RFC 의
두 번째 산출물이고, 어쩌면 첫 번째보다 값이 크다 — 지금은 12개 키퍼가 어디에
나가는지 아무도 모른다.

## remote_ssh 는 이 RFC 밖이다

`remote_ssh` 는 `network_mode` 를 아예 거부한다.

> `remote_ssh_no_network_mode: sandbox_profile "remote_ssh" does not support
> network_mode = "none" (only "inherit" is accepted in Phase 1; per-VM egress
> policy arrives with the microVM backend)`

원격 엔드포인트의 네트워크는 그 호스트의 정책이지 masc 가 argv 로 정하는 것이
아니다. 이 제약은 유지한다. `Network_policy` 도 `remote_ssh` 에는 거부된다.

## 무엇을 하지 않는가

- **추론 게이트웨이(`inference.local`).** 모델 키는 이미 샌드박스 밖이다.
  OCaml 서버가 프로바이더를 부르고 shim 의 `env_allowlist` 는 `MASC_BASE_PATH`
  계열 셋뿐이다. 지금 이득이 없다. 설계 스펙 §4.1 도 같은 판단을 적어뒀다.
- **TLS 투명 종단.** OpenShell 은 샌드박스별 임시 CA 로 TLS 를 끊어 L7 검사와
  자격증명 주입을 한다. 게스트 신뢰 저장소에 CA 를 심어야 하고, 그건 별도
  판단이다. 이 RFC 는 목적지 단위에서 멈춘다.
- **자격증명 주입.** 게스트에서 GitHub 토큰을 없애는 것은 이 프록시 위에
  얹히지만 별개다. 순서상 RFC-keeper-github-apps 가 먼저다 — 그쪽이 오늘 당장
  blast 를 계정 전역 무기한에서 keeper 1시간으로 줄인다.
- **호출한 바이너리 단위 판정.** OpenShell 이 하는 것이지만 microVM 경계 너머라
  masc 가 지금 구조로 얻을 수 있는지 확인하지 못했다. 재보지 않은 것을 설계에
  넣지 않는다.

## 검증

| 확인할 것 | 방법 |
|---|---|
| allowlist 밖은 거부된다 | `policy` 키퍼가 미허용 호스트를 부르면 실패하고, 그 실패가 이벤트로 남는다 |
| allowlist 안은 통과한다 | 같은 키퍼가 `gh api` 와 `git push` 를 완주한다 |
| 조용한 개방이 없다 | 프록시를 죽인 상태에서 `policy` 키퍼는 나가지 못한다 (fail-closed) |
| `inherit` 이 안 변한다 | 기존 12개 키퍼의 동작이 그대로다 |
| `remote_ssh` 는 거부된다 | `remote_ssh` + `policy` 조합이 TOML 로드에서 거부된다 |
| 백엔드마다 번역된다 | `network_args_for` 가 백엔드별로 프록시 주소를 낸다 |
| 라이브 | 키퍼 하나를 `policy` 로 옮기고 턴 하나를 완주 |

### D5. 강제 지점은 하네스 아래다 — 환경변수가 아니다

초안은 "프록시를 어떻게 알리나"를 미확인으로 뒀다. 조사해보니 이건 열린
질문이 아니라 이미 답이 있는 질문이다.

`HTTPS_PROXY` 는 **권고지 정책이 아니다.** 원시 소켓을 열거나 자기 HTTP
클라이언트를 들고 오는 하위 프로세스는 그냥 나간다. 강제 지점은 하네스 **아래**
여야 한다 — OS 네트워크 네임스페이스, 또는 컨테이너 경계의 forward proxy.

masc 에 유리한 점이 하나 있다. **백엔드들이 이미 그 경계에 있다.** Apple
`container` 의 `--network`, gondolin 의 `--allow-host` 는 게스트 프로세스가 못
건드리는 자리에서 판정한다. 이 RFC 가 강제 지점을 새로 발명할 필요가 없고,
`network_args_for` 가 각 백엔드의 그 자리로 번역하면 된다.

그래서 `Network_policy` 의 계약은 이렇다. **환경변수는 편의고, 정책은 백엔드
네트워크 argv 다.** 환경변수만 세팅되고 argv 가 안 붙는 조합은 이 모드가 아니다.

### D6. 매처가 신뢰 경계다 — 문자열로 비교하지 않는다

allowlist 를 도입하면 **매처 자체가 새 공격면**이 된다. 이건 가정이 아니라
실제로 뚫린 자리다.

Claude Code 의 샌드박스는 나가는 트래픽을 SOCKS5 프록시로 돌리고, 호스트명을
JavaScript `endsWith()` 로 allowlist 와 비교했다. 공격자가
`attacker-host.com\x00.google.com` 을 주면 — JS 는 뒤의 `.google.com` 을 보고
통과시키고, libc `getaddrinfo()` 는 널 바이트에서 끊어 `attacker-host.com` 을
해석한다. **같은 바이트를 두 파서가 다르게 읽는 것**이 우회다.
`sandbox-runtime <= 0.0.42` 가 SOCKS5 CONNECT 의 DOMAINNAME 원시 바이트를
매처에 그대로 넘겼고, 널 바이트 거부도 길이 상한도 문자 화이트리스트도 없었다.
0.0.43 의 `isValidHost()` 가 `\x00`·`%`·CRLF 를 매처 앞에서 거부하며 닫혔다
(Claude Code 2.1.90 포함). 공개 시점 기준 CVE 나 보안 권고는 없었다고
보고되어 있다.

OCaml 문자열도 바이트 열이고 `\x00` 을 담는다. 같은 종류의 버그가 그대로
도달한다.

그래서 이 RFC 는 매처를 문자열 비교로 두지 않는다. 호스트명을 **타입으로
파싱**한 뒤 비교한다 — 라벨 분해, 허용 문자 집합, 길이 상한, 널 바이트 거부가
파서 안에서 끝난다. 파싱에 실패한 입력은 "매칭 실패"가 아니라 **거부**다.
`Parse, don't validate` 가 여기서는 취향이 아니라 이 사고의 직접적인 교훈이다.

## 강제 지점 실측 (2026-09-04, Apple container 1.3.1, macOS 26.6.1)

타당성을 정하는 질문 — "백엔드 argv 로 프록시 하나만 남길 수 있는가" — 을 쟀다.
**된다.**

`container network create --internal <name>` 이 host-only 네트워크를 만들고,
`--network <name>` 으로 붙인 게스트에서 이렇게 나온다.

| 시도 | 결과 |
|---|---|
| 공개 이름 DNS (`api.github.com`) | `bad address` |
| 원시 TCP `1.1.1.1:443` | BLOCKED |
| 원시 TCP `140.82.121.6:443` (github) | BLOCKED |
| 호스트 게이트웨이 ICMP | 닿음 |
| **호스트 게이트웨이 TCP `:18443`** | **HTTP 응답 반환** |

원시 소켓이 IP 로 직접 나가는 것까지 막힌다. DNS 만 막힌 것이 아니라 **라우팅
레벨에서 닫혀 있다.** 그리고 호스트는 열려 있으니 프록시가 설 자리가 있다.

이것이 D5 가 요구한 "하네스 아래의 강제 지점"이다. 기본 백엔드에 대해 이
RFC 는 권고가 아니라 정책을 만들 수 있다.

## 미확인

- **gondolin·docker 는 재보지 않았다.** gondolin 은 `--allow-host` 가 게이트웨이
  자체라 모양이 다르다 — 프록시를 앞에 두는 것이 아니라 이미 정책 지점이다.
  그 둘을 같은 `network_args_for` 계약으로 덮을 수 있는지 확인이 필요하다.
- **DNS 를 누가 해석하는가.** 위 실측에서 내부 네트워크의 게스트는 공개 이름을
  아예 못 푼다. 프록시를 쓰게 되면 이름 해석이 프록시로 넘어가야 하는데, 게스트가
  자기 리졸버를 갖는 순간 매처가 보는 이름과 실제 연결 대상이 갈라진다 — D6 의
  사고가 정확히 그 틈이었다. `--dns` 와 `--no-dns` 가 이 자리에 있으나
  조합을 재보지 않았다.

## 출처

- [Agent Network Egress Policy — AgentPatterns.ai](https://agentpatterns.ai/security/agent-network-egress-policy/)
- [Claude Code Sandbox Bypass (SOCKS5 Null-Byte) — PoC](https://oddguan.com/blog/claude-code-sandbox-2/README.md)
- [Second Time, Same Sandbox — Aonan Guan](https://oddguan.com/blog/second-time-same-sandbox-anthropic-claude-code-network-allowlist-bypass-data-exfiltration/)
- [How OpenShell Works — NVIDIA](https://docs.nvidia.com/openshell/about/how-it-works)
