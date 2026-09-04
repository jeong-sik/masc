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

## 미확인

- 프록시를 게스트에 어떻게 알리는가 — 환경변수(`HTTPS_PROXY`)로 충분한지,
  아니면 백엔드별 네트워크 argv 가 필요한지. `env_keeper_scrub` 이 프록시
  변수를 이미 알고 있으므로(`NO_PROXY` 가 목록에 있다) 환경변수 경로가
  열려 있을 가능성이 있으나 확인하지 않았다.
- 프록시를 우회할 수 있는지. 환경변수만으로 두면 그걸 무시하는 클라이언트는
  그냥 나간다. fail-closed 를 지키려면 백엔드 네트워크 자체를 프록시로만
  향하게 해야 하고, 그게 백엔드마다 되는지 재봐야 한다.

두 번째가 이 설계의 타당성을 정한다. 환경변수만으로는 정책이 아니라 권고다.
