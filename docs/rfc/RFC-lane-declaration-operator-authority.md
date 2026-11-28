---
rfc: "lane-declaration-operator-authority"
title: "Lane 선언의 운영자 권한은 운영자가 파일에 적는다"
status: Draft
created: 2026-11-28
updated: 2026-11-28
author: claude
supersedes: []
superseded_by: null
related: ["#55104"]
---

# Lane 선언의 운영자 권한은 운영자가 파일에 적는다

- 코드 기준: main `38805541ee044`.
- **정한 것**: 운영자 표시 `operator_authority = true`(§3.1), 표시와 visibility 로 정하는 권한(§3.2), reconcile 의 검사와 worker 유지 조건(§3.3), 운영자가 할 일(§4).
- **바뀌는 동작**: 표시 없는 선언은 그 visibility 를 저장할 수 있는 사람 가운데 가장 낮은 권한으로 붙는다. 그런 선언에서는 `host_process` 가 돌지 않는다. workspace 밖 snapshot, 기록 grant, operator-only 소스도 거절된다. 이런 기능을 쓰는 운영자 선언에는 표시 한 줄을 더한다. 이 설치에서는 10개 중 5개다(§1.5).

## 0. 요약

Keeper 가 Lane 선언을 저장하면 서버는 그 Keeper 의 권한으로 선언을 검사한다. manifest 와 snapshot 파일은 workspace 안에 있어야 하고, `host_process` 패키지는 거절된다(`lib/lane_addon/lane_addon_runtime.ml:3718-3744`).

reconcile 은 그 선언을 다르게 다룬다. Shared 선언은 운영자 권한(`Operator_configuration`)으로 붙인다(`lane_addon_runtime.ml:4806-4809`). 선언 파일은 운영자 파일과 같은 폴더에 있고, 서버는 누가 썼는지 남기지 않는다.

선언이 가리키는 파일과 위층 Lane 은 저장 뒤에도 바뀐다. 바뀐 내용은 저장 때의 검사를 다시 거치지 않는다. 그래서 세 곳이 열려 있다.

1. manifest 가 `runtime = "host_process"` 로 바뀌면 reconcile 은 실행 방식을 보지 않고 호스트 프로세스를 띄운다. 실행 방식 검사는 저장(`:3725`)과 Attach(`:4352`)에만 있다. Keeper_only 선언도 같다.
2. Shared 선언의 snapshot 경로가 workspace 밖을 가리키는 링크로 바뀌면, worker 는 경로 제한 없이 읽는다(`lib/lane_addon/lane_addon_sources.ml:304-306`, `403-407`).
3. Shared 선언의 위층이 Operator_only 로 바뀌면 그 선언도 Operator_only 가 된다(`lane_addon_runtime.ml:3400-3403`). reconcile 은 이것을 운영자 권한으로 붙인다. 그러면 operator-only 출력이 Keeper 가 고른 container 로 들어간다.

이 RFC 는 운영자 권한을 선언 파일 안의 한 줄로 옮긴다. 그 줄은 운영자만 저장할 수 있다. 줄이 없는 파일은 누가 썼는지 모르는 파일로 본다. 그 visibility 를 저장할 수 있는 사람 가운데 가장 낮은 권한을 준다. 기록 파일도 잠금도 없다. 권한이 파일 바이트와 같이 다니니, 파일을 복사하거나 이름을 바꿔도 권한은 그대로다.

## 1. 지금 동작

### 1.1 저장

- 진입점은 MCP 도구 `masc_lane_declaration_save`(`lib/tool_misc.ml:278`)와 HTTP `POST /api/v1/lane-addons/declaration`(`lib/server/server_routes_http_routes_lane_addons.ml:532-540`, `800`)이다.
- MCP 도구는 Keeper 도구 실행기 두 곳에서도 불린다(`lib/keeper/keeper_tool_in_process_runtime.ml:2154`, `lib/keeper/keeper_tag_dispatch.ml:138`). 둘 다 `Keeper` 권한을 넘긴다.
- HTTP 는 운영자 자격 증명을 `Operator_configuration` 으로 바꾼다(`server_routes_http_routes_lane_addons.ml:60-64`). TUI 편집기도 이 경로로 저장한다(`lib/masc_tui/protocol/wire_runtime.ml:162`).
- Keeper 와 인증 없는 호출자의 저장은 이렇게 검사한다(`lane_addon_runtime.ml:3718-3744`).
  - manifest 를 `Within_workspace` 범위로 연다. realpath 가 workspace 밖이면 거절한다(`lib/lane_addon/lane_addon_config.ml:183-187`).
  - `host_process` 패키지를 거절한다(`authorize_execution`, `lane_addon_runtime.ml:3571-3576`).
  - snapshot 파일의 realpath 가 workspace 밖이면 거절한다(`Lane_addon_sources.authorize`).
  - 기록 grant 를 거절한다(`:3729-3735`).
  - visibility 가 자기 Keeper_only 이거나 Shared 일 때만 받는다(`:3738-3744`).
- 운영자 저장은 이 검사를 하지 않는다.
- 파일은 운영자 파일과 같은 폴더(`<config root>/lane-addons/`)에 쓴다(`lib/lane_addon/lane_addon_declaration.ml:42-45`).

### 1.2 reconcile

- 폴더의 `.toml` 을 모두 `Operator_declared` 범위로 읽는다(`lane_addon_config.ml:277`, `300-307`). manifest 경로에 제한이 없고, manifest 는 바퀴마다 다시 읽는다.
- visibility 는 같은 id·경로·revision 의 돌던 worker 나 기록에서 가져온다. 없으면 운영자 권한으로 바인딩에서 계산한다(`lane_addon_runtime.ml:4731-4759`, `4475-4485`).
- 붙일 때의 권한은 visibility 에서 거꾸로 만든다. `Keeper_only k` 는 `Keeper k` 이고, `Shared`·`Operator_only` 는 `Operator_configuration` 이다(`:4806-4809`).
- `attach_entry` 는 실행 방식을 보지 않는다(`:3578-3622`).
- manifest 가 바뀌면 revision 이 바뀐다. reconcile 은 돌던 worker 를 내리고 다음 바퀴에 새 package 로 붙인다(`:4785-4812`).
- 읽지 못한 선언은 issue 로 남는다. 그 선언의 돌던 worker 는 내리지 않는다(`:4693-4701`).
- 검사에 걸린 선언의 돌던 worker 도 그대로 둔다. 내리는 곳이 `Ok` 갈래 안에만 있다(`:4782-4796`).

### 1.3 읽을 때

- worker 는 소스를 entry 의 `source_access` 로 읽는다(`:1623-1626`).
- snapshot 파일은 `Operator_configuration` 이면 경로를 그대로 연다. 다른 권한이면 읽을 때마다 realpath 를 workspace 안으로 제한한다(`lane_addon_sources.ml:304-313`, `403-407`).
- Fusion run 과 위층 Lane 출력도 그 권한으로 읽는다(`lane_addon_sources.ml:327-328`, `lane_addon_runtime.ml:1625`).
- 기록 grant 는 `operator_owned ~configuration ~source_access` 로 판단한다(`:1165-1166`, `3586-3587`).

### 1.4 서버는 저장자를 모른다

- 소유 기록 `Lane_addon_document_owner` 는 「누가 이 선언을 읽고 고칠 수 있나」만 남긴다.
- Keeper 의 Keeper_only 저장과 운영자의 재배정은 같은 `Owned` 로 끝난다(`lib/lane_addon/lane_addon_document_owner.ml:118-150`).
- Shared·Operator_only 선언은 reconcile 이 바퀴마다 `revoke` 한다(`lane_addon_runtime.ml:4440-4442`). 그래서 Shared 저장은 흔적이 없다.
- 저장, reconcile, Attach, Detach, 읽기는 모두 `configuration_mutex` 를 잡는다(`:3701`, `4473`, `4360`, `4385`, `3680`). `Eio.Mutex.use_ro` 도 한 번에 한 fiber 만 들인다(eio `eio_mutex.mli` 의 `use_ro` 설명). 저장끼리는 겹치지 않는다.

### 1.5 이 설치의 상태

2026-11-28 03:20Z 에 선언 파일의 키 이름, 경로가 base path 안인지, manifest 의 `runtime` 만 읽었다.

- `<base-path>/.masc/config/lane-addons/` 에 선언이 10개 있다. Fusion 소스가 없어서 visibility 는 모두 Shared 다.
- manifest 는 모두 base path 안에 있다.
- 운영자 권한이 필요한 선언은 다섯이다.

  | 선언 | 필요한 이유 |
  |---|---|
  | `browser-ego` | `host_process` |
  | `wkbl-pbp` | `host_process` |
  | `wkbl-review` | `host_process` |
  | `vst-phrase` | snapshot 파일이 base path 밖에 있다 |
  | `operator-quiz` | 기록 grant(`board`, `github_pulls`, `repository`, `wiki`) |

- 나머지 다섯(`candle-appraiser-apple`, `dos-machine`, `keeper-librarian`, `msx-machine`, `workspace-curator`)은 표시 없이 붙는다. 읽기 권한이 바뀌어서 한 번 다시 시작한다(§3.3).

## 2. 원인

- 권한과 visibility 가 한 값(`source_access`)에 섞였다. 권한은 「이 선언이 무엇을 해도 되나」이고, visibility 는 「누가 출력을 읽나」다. reconcile 은 visibility 에서 권한을 만든다.
- 운영자 권한을 줄 근거가 파일 안에 없다. 저장 경로는 운영자 파일과 같은 폴더에 같은 모양으로 쓴다.
- 검사는 저장 때 한 번이다. 선언이 가리키는 파일과 위층은 그 뒤에도 바뀐다.

## 3. 설계

### 3.1 운영자 표시

- 선언에 선택 키 `operator_authority` 를 더한다. `true` 면 `Operator_marked`, 없거나 `false` 면 `Unmarked` 다(`Lane_addon_config.authority`). 다른 타입이면 그 선언의 issue 다.
- 저장 경로는 Keeper 와 인증 없는 호출자가 보낸 `operator_authority = true` 를 `Invalid_request` 로 거절한다. 운영자는 파일을 직접 고치거나 운영자 저장으로 쓴다.
- `masc browser-lane-setup` 은 새 `host_process` 선언에 이 줄을 쓴다. 기존 선언에는 파일을 수정하지 않고 필요한 줄과 경로를 알린다.
- 표시는 revision 밖이다. revision 은 「무엇을 돌리나」이고, 표시는 「무엇을 해도 되나」다. 돌던 worker 의 권한은 §3.3 이 따로 비교한다.

### 3.2 권한 표

표시와 visibility 로 실행 권한과 읽기 권한을 정한다(`declared_authority`). Keeper 전용 visibility 의 출처도 함께 검사한다.

| 표시 | visibility | 실행 권한 | 읽기 권한 |
|---|---|---|---|
| 있음 | Keeper_only k | 운영자 | Keeper k |
| 있음 | Shared, Operator_only | 운영자 | 운영자 |
| 없음 | Keeper_only k, 선언에 k 소유 Fusion 소스가 있음 | Keeper k | Keeper k |
| 없음 | Keeper_only k, 위층에서만 상속 | 거절 | 거절 |
| 없음 | Shared | 인증 없음 | 인증 없음 |
| 없음 | Operator_only | 거절 | 거절 |

- 표시 없는 파일은 그 visibility 를 저장할 수 있는 누구나 썼을 수 있다.
- Shared 는 인증 없는 호출자도 저장할 수 있다. 그래서 그 권한을 준다. Shared 바인딩에는 인증 없는 호출자가 못 읽는 소스가 없다. Fusion 소스가 있으면 Keeper_only 가 되기 때문이다(`lane_addon_runtime.ml:3407-3408`).
- 표시 없는 선언의 Keeper 권한은 그 선언이 직접 가리키는 Fusion 소스의 확인된 소유자에게만 준다. `Lane_output` 에서 물려받은 visibility 는 읽기 범위를 제한할 수 있지만 그 Keeper 의 실행 권한을 주지 않는다. 확인 시험은 직접 소스와 상속만 있는 소스를 각각 조립해 전자는 유지되고 후자는 표시 없이는 거절됨을 본다.
- Operator_only 는 운영자만 저장할 수 있다. 표시가 없으면 운영자가 썼다는 근거가 없으니 붙이지 않는다.
- 표시 있는 Keeper_only 는 실행만 운영자 권한이다. 읽기를 운영자 권한으로 하면 k 가 읽는 출력에 운영자 데이터가 섞인다.

### 3.3 reconcile

- 붙이기 전에 붙일 parse 로 세 가지를 검사한다. 실행 방식(`authorize_execution`), 소스(`Lane_addon_sources.authorize`), 기록 grant(`Lane_addon_records.grants`)다. 실패하면 그 선언의 issue 가 된다. 표시 없는 선언의 issue 에는 그 줄을 쓰면 풀린다는 말을 붙인다.
- 돌던 worker 는 세 조건을 모두 맞을 때만 그대로 둔다. revision 이 같아야 하고, 읽기 권한이 표와 같아야 하고, 실행 권한으로 그 package 를 돌릴 수 있어야 한다.
  - 읽기 권한이 다르면 내린다. 다음 바퀴에 표의 권한으로 붙인다.
  - 실행할 수 없으면 issue 를 남기고 내린다.
- 표가 거절하면(표시 없는 Operator_only) issue 를 남기고 돌던 worker 를 내린다.
- 읽지 못한 선언의 worker 를 지키는 규칙(`:4693-4701`)은 그대로다.

### 3.4 그대로인 것

- 명시적 Attach 는 호출자의 권한을 그대로 쓴다(`:4366-4368`).
- 소유 기록, 운영자 저장, Detach, 선언 읽기는 그대로다.
- 표시 없는 선언의 manifest 경로는 reconcile 에서 아직 `Operator_declared` 로 읽는다. §6 의 셋째 층에서 표시로 범위를 정한다.

## 4. 운영자가 할 일

- 표시가 필요한 선언에 `operator_authority = true` 한 줄을 더한다. 이 설치에서는 §1.5 의 다섯이다.
- 순서는 둘 중 하나다.
  - 재시작 전에 줄을 더한다. 옛 빌드는 모르는 키라 그 파일을 issue 로 두지만, 돌던 worker 는 내리지 않는다(`:4693-4701`). 그 사이 worker 가 죽으면 다시 붙지 않는다.
  - 재시작한 뒤 줄을 더한다. 그때까지 다섯 Lane 은 issue 로 멈춘다.
- 표시 없는 나머지 선언은 읽기 권한이 바뀌어서 첫 바퀴에 한 번 다시 시작한다.
- 되돌릴 때: 옛 빌드는 표시 줄을 모르는 키로 거절한다. 되돌리기 전에 줄을 지운다.
- 릴리스 노트(Upgrade notes)에 이 단계를 적는다.

## 5. 버린 방법

1. **저장자 기록**(이 RFC 의 첫 판). `declaration-authors/` 에 저장자를 남기고, 기록이 없으면 운영자 것으로 본다. 그러면 운영자 권한으로 새는 길이 셋 생긴다.
   - 운영자가 TUI 로 Keeper 선언을 한 번 고치면 기록이 그 바이트를 모르니 운영자 권한이 된다.
   - 업그레이드 전에 Keeper 가 저장한 파일은 기록이 없으니 운영자 것이 된다.
   - 기록은 `.masc/lane-addons/` 에 있다. 그 폴더를 지우거나 고칠 수 있으면 운영자 권한이 된다.
   - 모르는 입력을 운영자로 읽는 구조다. crash 순서 표도 따로 필요했다.
2. **reconcile 에서 실행 방식만 검사**한다. snapshot 과 operator-only 위층(§0 의 2, 3)이 남는다.
3. **저장 경로 전용 폴더**에 쓴다. 업그레이드 전 Keeper 파일이 운영자 폴더에 남는다. 운영자가 파일을 옮기면 권한이 말없이 바뀐다.
4. **표시 없는 Shared 는 운영자 읽기 권한으로 두고, host_process 와 snapshot 만 막는다.** 이 설치에서 표시할 선언은 넷으로 준다(`operator-quiz` 제외). 대신 operator-only 위층(§0 의 3)이 남고, 한 권한 값이 두 뜻을 갖는다.

## 6. 스택

1. 이 RFC.
2. 표시, 저장 거절, reconcile 의 권한 표와 검사, `browser-lane-setup`, 회귀 시험.
3. 표시 없는 선언의 manifest 를 reconcile, Detach, 선언 읽기에서 workspace 안으로 읽는다. `Lane_addon_config.load` 가 workspace 를 받는다.

## 7. 시험

`test/test_lane_addon_declaration.ml` 에 다섯을 더한다.

- Keeper 가 저장한 Shared 선언은 인증 없는 권한으로 읽는다. 저장 뒤 manifest 가 `host_process` 로 바뀌면 issue 가 되고 프로세스는 뜨지 않는다.
- 운영자가 Keeper 선언을 표시 없이 고친다. 그 뒤 snapshot 이 workspace 밖 링크가 되면, 붙기 전에 거절된다.
- 표시 있는 `host_process` 선언은 운영자 권한으로 돈다. 표시를 지우면 issue 를 남기고 멈춘다. 문자열 값은 issue 다.
- Keeper 와 인증 없는 호출자의 표시 저장은 거절된다. 운영자 저장은 받는다.
- 두 Keeper 의 Fusion run 을 읽는 표시 없는 선언은 거절된다. 표시하면 운영자 권한으로 붙는다.

`host_process` 나 기록 grant 를 reconcile 로 붙이는 기존 시험의 선언에는 표시를 더한다(composition, exact_native, native_runtime, reconcile, host_cycle).

## 8. 남는 한계

- 이 설계는 설정 폴더(`<config root>/lane-addons/`)에 운영자와 저장 경로만 쓴다고 본다. Keeper 가 그 폴더에 직접 쓸 수 있으면 어떤 표시도 믿을 수 없다.
- Keeper 가 base path 안의 파일을 실제로 바꿀 수 있는지는 확인하지 않았다. 이 RFC 는 바꿀 수 있다고 보고 막는다.
- 표시는 선언이 가리키는 파일까지 믿는다는 뜻이다. Keeper 가 표시 있는 선언의 manifest 나 snapshot 을 고칠 수 있으면, 그 worker 를 Keeper 가 정한다. 운영자는 Keeper 가 못 쓰는 파일을 가리키는 선언에만 표시한다. §1.5 의 다섯 선언이 가리키는 파일을 Keeper 가 쓸 수 있는지는 확인하지 않았다.
- snapshot 과 manifest 는 realpath 로 확인한 뒤 경로로 다시 연다(`lane_addon_sources.ml:291`, `372`; `lane_addon_config.ml:186`; `lib/lane_addon/lane_addon_manifest.ml:127-128`). 그 사이에 링크를 바꾸면 workspace 밖을 읽을 수 있다. 버린 방법도 같고, 이 RFC 밖이다.
- manifest 를 열 때 일반 파일인지 보지 않는다. FIFO 면 reconcile 이 잠금을 잡은 채 멈춘다. 이 RFC 밖이다.
