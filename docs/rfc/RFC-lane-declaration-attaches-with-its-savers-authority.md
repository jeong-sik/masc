---
rfc: "lane-declaration-attaches-with-its-savers-authority"
title: "Lane 선언은 저장한 사람의 권한으로 붙는다"
status: Draft
created: 2026-11-28
updated: 2026-11-28
author: claude
supersedes: []
superseded_by: null
related: ["#55104"]
---

# Lane 선언은 저장한 사람의 권한으로 붙는다

- 코드 기준: main `38805541ee044`.
- **정한 것**: 저장자 기록(D1), 저장·Attach·reconcile 이 같이 쓰는 검사(D2), worker 가 소스를 읽는 권한(D3), 권한이 바뀐 worker(D4), 이미 있는 선언(D5).
- **바뀌는 동작**: Keeper 나 인증 없는 호출자가 저장한 선언은 reconcile 에서도 그 저장자의 권한으로 붙는다. 그런 선언에서는 `host_process` 패키지가 붙지 않고, workspace 밖 snapshot 은 읽히지 않는다. 운영자가 쓴 선언은 §3 D2 의 한 경우 말고는 그대로다.

## 0. 요약

Keeper 가 Lane 선언을 저장하면 서버는 그 Keeper 의 권한으로 선언을 검사한다. manifest 와 snapshot 파일은 workspace 안에 있어야 하고, `host_process` 패키지는 거절된다(`lib/lane_addon/lane_addon_runtime.ml:3718-3744`).

reconcile 은 그 선언을 다르게 다룬다. Shared 선언은 운영자 권한(`Operator_configuration`)으로 붙인다(`lane_addon_runtime.ml:4806-4809`). 선언 파일은 운영자 파일과 같은 폴더에 있다. 서버는 누가 그 파일을 썼는지 남기지 않는다. 그래서 reconcile 은 Keeper 가 저장한 선언과 운영자가 쓴 파일을 구분하지 못한다.

선언이 가리키는 파일은 저장 뒤에도 바뀐다. reconcile 은 manifest 를 바퀴마다 다시 읽고, worker 는 snapshot 파일을 읽을 때마다 연다. 저장 뒤에 바뀐 내용은 저장 때의 검사를 다시 거치지 않는다. 그래서 두 곳이 열려 있다.

1. manifest 가 `runtime = "host_process"` 로 바뀌면, reconcile 은 실행 방식을 확인하지 않고 호스트 프로세스를 띄운다. 실행 방식 검사는 저장(`:3725`)과 Attach(`:4352`)에만 있다. Keeper_only 선언도 같다.
2. Shared 선언의 snapshot 경로가 workspace 밖을 가리키는 링크로 바뀌면, worker 는 경로 제한 없이 읽는다. 운영자 권한이면 경로를 그대로 쓰기 때문이다(`lib/lane_addon/lane_addon_sources.ml:304-306`, `403-407`).

Attach 는 이미 호출자의 권한을 worker 에 남긴다(`lane_addon_runtime.ml:4366-4368`). reconcile 에는 호출자가 없어서 이 규칙을 쓰지 못한다. 이 RFC 는 저장한 사람을 durable 하게 기록해서 reconcile 에 그 호출자를 돌려준다. 저장, Attach, reconcile 은 같은 검사 함수를 쓴다. worker 는 저장자의 권한으로 소스를 읽는다.

## 1. 지금 동작

### 1.1 저장

- 진입점은 둘이다. MCP 도구 `masc_lane_declaration_save`(`lib/tool_misc.ml:278`)와 HTTP `POST /api/v1/lane-addons/declaration`(`lib/server/server_routes_http_routes_lane_addons.ml:532-540`, `800`)이다.
- 둘 다 호출자의 권한(`Operator_configuration`, `Keeper k`, `Unauthenticated`)을 `save_declaration` 에 넘긴다.
- Keeper 와 인증 없는 호출자의 저장은 이렇게 검사한다(`lane_addon_runtime.ml:3718-3744`).
  - manifest 를 `Within_workspace` 범위로 연다. realpath 가 workspace 밖이면 거절한다(`lib/lane_addon/lane_addon_config.ml:183-187`, `lib/lane_addon/lane_addon_manifest.ml:451-458`).
  - `host_process` 패키지를 거절한다(`authorize_execution`, `lane_addon_runtime.ml:3571-3576`).
  - snapshot 파일의 realpath 가 workspace 밖이면 거절한다(`Lane_addon_sources.authorize`).
  - 기록 grant 를 거절한다. 주석이 이유를 적는다. reconcile 이 Shared 선언을 운영자 권한으로 붙이기 때문이다(`:3729-3735`).
  - visibility 가 자기 Keeper_only 이거나 Shared 일 때만 받는다(`:3738-3744`).
- 운영자 저장은 이 권한 검사를 하지 않는다.
- 파일은 운영자 파일과 같은 폴더(`<config root>/lane-addons/`)의 바로 아래에 쓴다(`lib/lane_addon/lane_addon_declaration.ml:42-45`).

### 1.2 reconcile

- 폴더의 `.toml` 을 모두 `Operator_declared` 범위로 읽는다(`lane_addon_config.ml:277`, `300-307`). manifest 경로에 제한이 없다. manifest 는 바퀴마다 다시 읽는다.
- visibility 는 운영자 권한으로 바인딩에서 계산한다(`lane_addon_runtime.ml:4475-4485`).
- 붙일 때의 권한은 visibility 에서 거꾸로 만든다. `Keeper_only k` 는 `Keeper k` 이고, `Shared`·`Operator_only` 는 `Operator_configuration` 이다(`:4806-4809`).
- `attach_entry` 는 실행 방식을 보지 않는다(`:3578-3622`).
- manifest 가 바뀌면 선언 revision 이 바뀐다. reconcile 은 돌던 worker 를 내리고(`:4785-4796`), 다음 바퀴에 새 package 로 붙인다(`:4797-4812`).
- 읽지 못한 선언은 issue 로 남고, 그 선언의 돌던 worker 는 내리지 않는다(`:4693-4701`).

### 1.3 읽을 때

- worker 는 소스를 entry 의 `source_access` 로 읽는다(`:1623-1626`).
- snapshot 파일은 `Operator_configuration` 이면 경로를 그대로 연다. 다른 권한이면 읽을 때마다 realpath 를 workspace 안으로 제한한다(`lane_addon_sources.ml:304-313`, `403-407`).
- Fusion run 은 읽을 때 그 권한으로 소유를 확인한다(`lane_addon_sources.ml:327-328`). 위층 Lane 출력도 그 권한으로 읽는다(`lane_addon_runtime.ml:1625`).
- 기록 grant 는 `operator_owned ~configuration ~source_access` 로 판단한다(`:1165-1166`, `3586-3587`).

### 1.4 소유 기록으로는 저장자를 알 수 없다

`Lane_addon_document_owner` 는 「누가 이 선언을 읽고 고칠 수 있나」를 기록한다.

- Keeper 가 자기 Keeper_only 선언을 저장하면 `prepare` → `complete` 로 `Owned` 가 된다(`lib/lane_addon/lane_addon_document_owner.ml:118-143`).
- 운영자가 쓴 Keeper_only 선언은 reconcile 이 `reassign` → `complete` 로 그 Keeper 의 `Owned` 로 만든다(`lane_addon_runtime.ml:4443-4457`, `lane_addon_document_owner.ml:144-150`).
- 두 경우가 같은 `Owned` 로 끝난다.
- Shared·Operator_only 선언은 reconcile 이 바퀴마다 `revoke` 한다(`lane_addon_runtime.ml:4440-4442`). 그래서 Shared 저장은 흔적이 없다.

### 1.5 이 설치의 상태

2026-11-28 02:45Z 에 확인했다. 파일 목록과 크기만 읽었다.

- `<base-path>/.masc/config/lane-addons/` 에 선언 파일 10개가 있다.
- 소유 기록(`<base-path>/.masc/lane-addons/declaration-owners/`) 23개는 모두 0 바이트다. 지금 파일 가운데 Keeper_only 선언은 없다.
- Shared 저장은 흔적을 남기지 않아 확인할 수 없다.
- `host_process` 로 붙어 있는 선언은 셋이다: `browser-ego`, `wkbl-pbp`, `wkbl-review`(11-28 01:36Z Lane 조회).

## 2. 원인

- 권한과 visibility 가 한 값(`source_access`)에 섞였다. 권한은 「누가 이 선언을 썼나」이고, visibility 는 「누가 출력을 읽나」다. reconcile 은 visibility 에서 권한을 만든다.
- 저장 경로는 운영자 파일과 같은 폴더에 쓰고 저장자를 남기지 않는다. reconcile 에는 권한을 알 근거가 없다.
- 검사는 저장 때 한 번이다. 선언이 가리키는 manifest 와 snapshot 은 그 뒤에도 바뀐다.

## 3. 설계

### D1. 저장자 기록

새 모듈 `Lane_addon_declaration_author` 가 선언 파일마다 저장자를 기록한다.

- 위치는 `<lane add-on store>/declaration-authors/<sha256(canonical source path)>.jsonl` 이다. 소유 기록과 같은 private JSONL 잠금 쓰기(`Fs_compat.update_private_file_durable_locked_result`)를 쓴다.
- 저장자는 `Keeper of string | Unauthenticated` 다. 운영자는 기록하지 않는다.
- 상태는 둘이다.
  - `Pending { author; proposed; prior; prior_author }`: 파일을 쓰기 전에 남긴다. `prior` 는 쓰기 전 파일의 source_revision 이다. `prior_author` 는 그 바이트의 저장자이고, 운영자면 비어 있다.
  - `Written { author; revision }`: 쓴 바이트를 확인한 뒤 남긴다.

지금 바이트의 source_revision 이 `r` 일 때 저장자는 이렇게 정한다.

| 기록 | 저장자 |
| --- | --- |
| 없음 | 운영자 |
| `Written`, `revision = r` | `author` |
| `Written`, `revision ≠ r` | 운영자 |
| `Pending`, `proposed = r` | `author` |
| `Pending`, `prior = Some r` | `prior_author`. 비어 있으면 운영자 |
| `Pending`, 그 밖 | 운영자 |
| 읽기 실패 | 정하지 않는다. reconcile 은 붙이지 않고 issue 를 남긴다 |

- 「기록이 지금 바이트를 가리키지 않으면 운영자」는 전제 하나에 기댄다. 저장 경로 밖에서 이 폴더를 고칠 수 있는 사람은 운영자뿐이다. Keeper 가 이 폴더를 직접 쓸 수 있으면 저장 때의 검사부터 뜻이 없다.
- 운영자 저장은 기록을 쓰지 않는다. 운영자가 바이트를 바꾸면 기록이 그 바이트를 가리키지 않게 된다.
- 운영자가 Keeper 의 바이트를 그대로 다시 쓰면 그 바이트는 Keeper 의 것으로 남는다. 권한이 좁아지는 쪽이라 받아들인다.

Keeper·인증 없는 호출자의 저장 순서:

1. 선언 저장 잠금을 잡는다. 새 `Eio.Mutex` 하나가 모든 선언 저장을 한 줄로 세운다. 저장은 드물다. reconcile 은 이 잠금을 잡지 않는다.
2. 남은 `Pending` 을 정리한다. 지금 바이트가 `proposed` 면 `Written { author; proposed }` 로, `prior` 면 그 전 저장자로, 둘 다 아니면 기록 없음으로 본다.
3. `Pending` 을 쓴다.
4. 선언 파일을 쓴다. 지금의 revision 비교 쓰기를 그대로 쓴다.
5. 다시 읽어 바이트를 확인하고 `Written` 으로 마무리한다.

Keeper_only 저장의 소유 기록 절차(`prepare`·`complete`)는 지금 자리에서 그대로 돈다. 저장자 기록은 그 앞뒤를 감싼다.

잠금이 없으면 두 저장이 엇갈린다. A 의 `Pending` 을 B 의 `Pending` 이 덮은 뒤 A 의 쓰기만 성공하면, 파일은 A 의 바이트인데 기록은 B 를 가리킨다. 표의 「그 밖」 줄에 걸려 운영자로 읽힌다. 지금 저장은 `configuration_mutex` 를 읽기로만 잡아서(`:3701`) 저장끼리 동시에 돌 수 있다.

### D2. 저장·Attach·reconcile 이 같이 쓰는 검사

저장(`:3718-3744`)과 Attach(`:4342-4369`)에 흩어진 검사를 함수 하나(`admit`)로 모은다. 입력은 권한, package, binding 이다.

1. `authorize_execution ~access:authority package`
2. `Lane_addon_sources.authorize ~workspace ~access:authority binding`
3. `binding_visibility m ~access:authority binding` 로 visibility 를 얻는다.
4. worker 의 소스 권한을 정한다(D3).
5. 그 소스 권한으로 `Lane_addon_sources.authorize` 를 한 번 더 한다. Attach 가 지금 하는 일이다(`:4369`).

부르는 곳:

- 저장은 호출자 권한으로 `admit` 을 부른다. 그 뒤 지금처럼 visibility 와 소유를 맞춘다(`:3738-3744`).
- Attach 는 호출자 권한으로 `admit` 을 부른다. 동작은 바뀌지 않는다.
- reconcile 은 D1 의 저장자를 권한으로 `admit` 을 부른다. 실패하면 붙이지 않고 그 선언의 issue 로 남긴다.
- reconcile 은 선언 바이트의 source_revision 으로 저장자를 먼저 찾는다. 저장자가 운영자가 아니면 저장 때와 같은 `Within_workspace` 범위로 manifest 를 연다. manifest 가 workspace 밖으로 바뀌면 그 선언은 읽기 issue 가 된다. 돌던 worker 는 §1.2 처럼 남고, 이미 검사를 거친 package 로 돈다.

운영자 선언에서 바뀌는 경우가 하나 있다. visibility 가 Keeper_only 이면서 workspace 밖 snapshot 을 읽는 운영자 선언이다. 지금은 붙은 뒤 읽을 때 실패한다. 앞으로는 5단계에서 걸려 붙기 전에 issue 로 남는다. 이 설치에는 Keeper_only 선언이 없다(§1.5).

### D3. worker 가 소스를 읽는 권한

Attach 의 규칙(`:4366-4368`)을 reconcile 에도 쓴다.

- visibility 가 `Keeper_only k` 면 `Keeper k`
- `Shared`·`Operator_only` 면 저장자의 권한

운영자가 쓴 선언은 지금과 같다. Keeper 가 저장한 Shared 선언은 그 Keeper 의 권한으로 읽는다. 그래서 snapshot 경로 제한, Fusion run 소유 확인, 위층 출력 읽기 확인이 읽을 때마다 그 Keeper 기준으로 돈다(§1.3).

### D4. 권한이 바뀐 worker

지금 reconcile 은 revision 이 같고 worker 가 돌면 그 worker 를 둔다(`:4788`). 앞으로는 worker 의 소스 권한도 같아야 둔다. 다르면 내리고, 다음 바퀴에 `admit` 을 거쳐 다시 붙인다.

### D5. 이미 있는 선언

- 옮기는 코드는 만들지 않는다. 기록이 없는 파일은 운영자가 쓴 것이다.
- 이 설치에는 Keeper_only 선언이 없다(§1.5). Shared 저장은 구분할 수 없다. 릴리스 노트는 운영자에게 `lane-addons/` 를 한 번 보라고 적는다. 이 설치는 파일 10개다.
- 운영자 선언 셋(`browser-ego`, `wkbl-pbp`, `wkbl-review`)은 고치지 않아도 그대로 붙는다.
- 옛 바이너리로 되돌리면 `declaration-authors/` 를 읽지 않는다. 지금 동작으로 돌아간다.

### D6. 그대로 두는 것

- 저장 때 Keeper 의 기록 grant 를 거절하는 검사(`:3733-3735`)는 둔다. 주석의 이유만 바꾼다. D3 뒤에는 reconcile 도 Keeper 권한으로 붙여서, 그 grant 는 운영자 소유가 아니다.
- 소유 기록(`declaration-owners/`)의 뜻과 선언 TOML 형식은 바꾸지 않는다.

## 4. 중단되는 지점

Keeper A 가 파일 바이트 `P` 를 `R` 로 바꾸는 저장이다. `x` 는 `P` 의 저장자다.

| 멈춘 곳 | 파일 | 기록 | reconcile 이 보는 저장자 |
| --- | --- | --- | --- |
| `Pending` 쓰기 전 | P | 이전 | x |
| `Pending` 쓰기 실패 | P | 이전 | x. 저장은 실패로 끝난다 |
| `Pending` 뒤, 파일 쓰기 전 | P | `Pending{A, R, P, x}` | x |
| 파일 쓰기가 revision 충돌로 실패 | P | `Pending{A, R, P, x}` | x |
| 그 사이 운영자가 Q 로 고침 | Q | `Pending{A, R, P, x}` | 운영자 |
| 파일 쓰기 뒤, `Written` 전 | R | `Pending{A, R, P, x}` | A |
| `Written` 쓰기 실패 | R | `Pending{A, R, P, x}` | A. 저장은 성공으로 돌려준다. 다음 저장의 2단계가 마무리한다 |
| `Written` 뒤 | R | `Written{A, R}` | A |
| 기록 읽기 실패 | - | - | 붙이지 않는다 |

어느 칸에서도 Keeper 의 바이트가 운영자 권한으로 붙지 않는다.

## 5. 고르지 않은 안

1. **선언에 `host_process = true` 를 적게 한다.** 이 줄은 운영자만 쓸 수 있다. 실행 구멍은 이미 있는 선언까지 막힌다. 하지만 snapshot 구멍은 남는다. 운영 선언 셋도 고쳐야 한다.
2. **저장 폴더를 나눈다**(`lane-addons/<저장자>/`). 권한이 경로에 드러나고 기록 절차가 없다. 하지만 `file_name` 규칙, 읽기·저장 API 의 `source_path`, 소유 기록의 열쇠가 모두 바뀐다. 대시보드와 TUI 도 고쳐야 한다.
3. **reconcile 에서 visibility 로 만든 권한으로 검사만 다시 한다.** Keeper_only 는 막히지만 Shared 는 운영자 권한 그대로다.
4. **소유 기록에 저장자를 더한다.** 소유 기록은 읽고 고치는 권한이다. reconcile 은 Shared 선언마다 소유를 지우고, 운영자 선언도 Keeper 에게 넘긴다(§1.4). 두 뜻을 한 기록에 넣으면 둘 다 흐려진다.
5. **저장할 때 manifest 와 snapshot 을 서버 쪽에 복사해 고정한다.** 저장 뒤 바뀐 파일의 영향이 없어진다. 하지만 snapshot 은 계속 바뀌어야 하는 입력이라 고정할 수 없다. Keeper 가 고친 패키지를 쓰려면 다시 저장해야 한다.
6. **기록이 없으면 Keeper 로 본다.** 그러려면 운영자 파일에 표시가 필요하다. 이 설치의 파일 10개를 모두 고쳐야 한다.

## 6. 구현 순서 (native stack)

1. 이 RFC
2. `Lane_addon_declaration_author` 와 단위 시험. D1 의 표와 §4 의 모든 칸을 시험으로 옮긴다.
3. 저장 경로: 저장 잠금, `Pending`·`Written`, `admit` 추출. 저장과 Attach 가 `admit` 을 쓴다.
4. reconcile: 저장자 읽기, `Within_workspace` 읽기, `admit`, D3, D4, 회귀 시험, changelog

## 7. 확인

- 단위 시험: D1 표의 모든 줄과 §4 의 모든 칸
- 회귀 시험은 `test/test_lane_addon_reconcile.ml` 계열에 둔다. 각 시험은 고치기 전 코드에서 실패해야 한다. 4층의 시험을 3층 위에 먼저 올려 `test.yml` 로 실패를 확인한다.
  - Keeper 가 컨테이너 선언을 저장한 뒤 manifest 가 `host_process` 로 바뀌면, 다음 reconcile 은 붙이지 않고 issue 를 남긴다. 호스트 프로세스는 뜨지 않는다.
  - Keeper 가 Shared 선언을 저장한 뒤 snapshot 파일이 workspace 밖 링크로 바뀌면, 읽기가 거절된다.
  - 운영자가 쓴 `host_process` 선언은 그대로 붙는다.
  - 운영자가 Keeper 의 파일을 직접 고치면 운영자 권한으로 붙는다.
- 배포 뒤: Lane 조회에서 `browser-ego`, `wkbl-pbp`, `wkbl-review` 가 attached 로 남는지 본다. `declaration-authors/` 는 Keeper 가 저장하기 전까지 비어 있다.
- TLA+: Lane 선언의 spec 은 없다. 새 spec 은 만들지 않고, §4 의 표를 단위 시험으로 옮긴다.

## 8. 남는 것

- Keeper 가 base path 안의 파일을 실제로 바꿀 수 있는지는 확인하지 않았다. 이 RFC 는 바꿀 수 있다고 보고 막는다.
- 운영자가 `host_process` 로 선언한 패키지의 manifest 가 Keeper 가 쓸 수 있는 곳에 있으면, 그 manifest 가 정한 명령이 돈다. 운영자의 선택이고 이 RFC 범위 밖이다.
- 저장자를 화면에 보이는 일(선언 읽기 결과의 `author`)은 필요해지면 따로 한다.
