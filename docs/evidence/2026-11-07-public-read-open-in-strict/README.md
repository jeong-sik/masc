# strict 설정에서 열리는 Public_read 등록 (2026-11-07)

A4d 뒷부분(계획 `docs/superpowers/plans/2026-10-27-multi-account-oidc-runtime-authorization.md`의 "A4d 뒷부분 범위")이 옮길 등록의 목록이에요.

- 기준: main `82ef0dcb730`.
- 명령: `python3 -I public_read_open_in_strict.py <repo>`. 결과는 `public-read-open-in-strict.txt`예요.
- 방법: `lib/server`의 `Server_route` 등록 중 종류가 `Public_read`나 `Public_read_on_canonical_host`인 것을 읽어요. 그 경로에 `Server_auth.is_public_read_path`의 규칙을 적용해요. strict 설정의 `with_public_read`는 이 함수가 참인 경로만 자격 없이 열어요.
- 확인: 읽은 등록 수(130)가 소스의 `Server_route.Public_read` 글자 수와 같아야 끝나요. 경로가 모르는 상수이면 멈춰요.

## 결과

`Public_read` 등록 130개 중 13개가 strict 설정에서도 열려요.

| 경로 | 종류 | 열리는 범위 |
|---|---|---|
| `/api/v1/gate/health`, `/status`, `/connectors`, `/connector/status`, `/events` | `Public_read` | 경로 그대로 |
| `/favicon.ico`, `/favicon.svg` | `Public_read` | 경로 그대로 |
| `/dashboard`, `/dashboard/` | `Public_read_on_canonical_host` | 경로 그대로 |
| `/dashboard/` (prefix) | `Public_read_on_canonical_host` | prefix 전체 |
| `/api/v1/msx/carts` | `Public_read` | 경로 그대로 |
| `/api/v1/voice/audio/` (prefix) | `Public_read` | prefix 전체 |
| `/api/v1/published-artifacts/` (prefix) | `Public_read` | 형식이 맞는 artifact id만 |

2026-10-29 측정(`docs/evidence/2026-10-29-h2-route-gate/public-read-open-in-strict.txt`)의 15개와 다른 점:

- multimodal 세 경로(`/api/v1/multimodal/get/`, `list`, `provenance/`)는 이제 목록에 없어서 strict에서 닫혀요.
- 10-29는 서버를 띄워 자격 없이 찔러 본 값이고, 이번은 소스를 읽은 값이에요. published-artifacts는 10-29 측정에서 형식이 틀린 id로 찔러 닫힌 것으로 나왔어요. 이번 표에는 들어가요.

## 한계

- 경로 상수 여섯 개의 값은 스크립트에 적어 둔 값이에요(82ef0dcb730 기준). 상수가 바뀌면 스크립트도 고쳐야 해요.
- 서버를 띄워 확인하지 않았어요. 소스의 등록과 판정 규칙만 읽었어요.
