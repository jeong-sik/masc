---
rfc: "every-lane-is-one-row-in-one-registry"
title: "모든 Lane 을 한 목록에 모은다"
status: Draft
created: 2026-09-27
updated: 2026-09-27
author: claude
related: ["event-spine-and-source-contract", "machine-spectating-goes-through-lanes", "0439", "browser-lane-stagehand", "0457"]
---

# RFC: 모든 Lane 을 한 목록에 모은다

- 관련 문서: `docs/design/lane-addon-v0.md`, `docs/design/tui-lane-experience.md`, glossary 의 Lane 항목들, TUI 작업대 RFC(#39231), RFC-tui-measured-operator-home(#38801). 뒤의 둘은 아직 main 에 없다.
- 범위: Lane 을 가리키는 id, 설정으로 켜고 끄는 규칙, 상태를 말하는 타입, 목록을 읽는 endpoint 하나, TUI `Lanes` 목록, 배포 순서. Lane 이 하는 일(판정, 브라우저 조작, 기계 실행, 패키지 관측)은 바꾸지 않는다.
- 근거 기준: `origin/main` = `7a8a5e109d` (2026-09-27). 줄 번호는 모두 이 커밋 기준이다. 라이브 설정(`~/me/.masc/config`)은 2026-09-27 에 읽었다.
- 표시: **[사실]** 은 코드·파일에서 확인한 것이다. **[제안]** 은 이 RFC 가 정하려는 것이다.

## 무슨 일이 있었나 (사람이 읽는 서두)

2026-09-27 에 운영자가 TUI `Lanes` 화면을 보고 이렇게 말했다.

> Lane add-on 이면 여기 있는 게 맞다. 그러면 지금 있는 Lane 도 전부 add-on 처럼 떼었다 붙일 수 있어야 한다.
> 지금 있는 Browser Lane 도, DOS 와 MSX 도 이렇게 들어와야 한다. 제대로 개발되지 않았다. 다 훑어보고 제대로 하라.

"떼었다 붙인다" 가 무슨 뜻이냐고 물었다. 운영자는 "Lane 을 한 목록에 모으고, 내장 Lane 은 서버 프로세스 안에 둔다" 는 안을 골랐다.

- 모든 Lane 이 manifest 하나(id, 읽는 원천, 행동과 도구, 설정 자리, 상태)를 가진다. 모두 한 목록에 들어간다. 설치·켜기·끄기·상태를 같은 방식으로 본다.
- 내장 Lane(standalone exact-output lane, Browser Lane backend, MSX, DOS)은 지금처럼 서버에 컴파일되어 서버 프로세스 안에서 돈다. **설정으로 켜고 끈다.**
- Docker 로 도는 Lane Add-on 패키지는 그 목록 안의 프로세스 종류 하나가 된다.
- 타입이 있는 도구(`masc_msx_*`, `masc_dos_*`, `masc_browser_*`)는 그대로 둔다.
- 서버 안 기계의 성능은 그대로다. 잠금 없이 "그대로" 를 답하는 live 라우트와, DOS 실행 한 번에 기계 잠금을 최대 약 170ms 쥐는 구조를 바꾸지 않는다.

지금은 이것이 안 된다. 운영자 화면에서 "lane" 은 다섯 가지를 가리키고, 다섯 모두 id 타입과 설정 자리와 켜고 끄는 법이 다르다(1장). "not loaded", "unavailable", "installed" 는 각각 서로 다른 상태 여럿을 한 단어로 보여 준다(1.4). 고르지 않은 두 안은 7장에 적는다.

## 1. 문제

### 1.1 운영자가 보는 "lane" 이 다섯 가지다

| 무엇 | id 타입 | 설정 자리 | 켜고 끄기 | 프로세스 | TUI 입구 |
|---|---|---|---|---|---|
| Exact-output lane 6개 (Board Attention, HITL Auto Judge, Librarian, Workspace Curator, Verifier, Browser Stagehand) | 닫힌 타입 `Standalone_lane.t` (`lib/runtime/standalone_lane.mli:12-18`) | `[runtime.exact_output_lanes.<id>]` | lane 마다 다름 (1.4) | 서버 안 fiber | `Lanes` 의 Standalone 표 |
| Browser Lane backend 3개 (`live`, `automation`, `stagehand`) | 닫힌 타입 `Browser_lane.Lane_name.t`, `[@@deriving enumerate]` (`lib/browser_lane/browser_lane_name.mli:12`) | `live`: 없음(host 설치와 운영자 브라우저). `automation`: `[browser] geckodriver/binary` (`lib/browser_configuration.ml:23-36`). `stagehand`: `[browser.stagehand]` (`:38` 부터) | 설정 없으면 호출 때 `Lane_absent` | 서버 코드가 운영자 브라우저 또는 서버가 띄운 브라우저를 부린다 | Connectors 화면 아래 (`bin/masc_tui_types.ml:6643-6656`), `B`·Ctrl-^ |
| 기계 2개 (MSX, DOS) | 모듈 `Msx_lane`, `Dos_lane`. 기계를 나열하는 합타입이 여럿이다 (1.2) | 없음 | 늘 켜짐 | 서버 안 singleton | `&` 기계 메뉴 (`bin/masc_tui.ml:21596`) |
| Lane Add-on 설치 (라이브 2개) | 선언의 `id` 문자열 (`lib/lane_addon/lane_addon_config.mli:4-12`) | `<config-root>/lane-addons/*.toml` (`lib/lane_addon/lane_addon_runtime.ml:660-662`) | 파일이 있으면 설치 | 설치마다 Docker container 하나 | `o`/`A`, `/addons`, 팔레트 |
| Runtime candidate order | 문자열 이름 `Runtime_lane.t` | `[runtime.lanes.<name>]` | 해당 없음 | 프로세스가 아니다. Keeper turn 의 후보 순서다 | `Lanes` 머리글의 "Lanes N" 탭 (`bin/masc_tui_render.ml:5802-5806`, `:5832`) |

[사실] 운영자와 Keeper 가 보는 곳에 "lane" 이 두 번 더 나온다.

- Add-on 안에서 "lane" 은 관측 행이 놓이는 **열**이다. `row.lane_id` (`lib/lane_addon/lane_addon_types.mli:9`), "Package-local lane IDs" (`:28-29`), `lane.toml` 의 `lanes = ["dos/guest"]` (`addons/dos-world/lane.toml:15`).
- Keeper 도구 `keeper_lane_status` 와 셸 명령 `masc lane status` 는 Keeper 의 **sandbox 실행 경로**(microvm_remote, remote_ssh, docker)를 말한다 (`config/tools/keeper_lane_status.toml:1-5`).

glossary 는 이 중 일부를 이미 나눴다. `[runtime.lanes.<이름>]` 은 **Runtime Candidate Order** 라고 적었다 (`docs/spec/00-glossary.md:837`, `:848-856`). 그런데 TOML 키, 타입 이름, TUI 탭 이름은 여전히 "lane" 이다.

### 1.2 공통 모델이 없다

[사실] **Lane 을 가리키는 id 타입**이 family 마다 따로다. `Standalone_lane.t`, `Browser_lane.Lane_name.t`, 선언 `id` 문자열, `Runtime_lane.id` 문자열이다. 기계에는 id 타입이 없다. 여러 family 에 걸친 타입은 있다. `Lane_addon_sources.source`·`kind`·`activity` (`lib/lane_addon/lane_addon_sources.mli:8-14`, `:18-19`, `:28`)는 MSX, DOS, Browser 를 함께 나열한다. 다만 이것은 "Add-on 이 받는 원천의 종류" 이지 Lane 의 id 가 아니다. Lane 의 id 로 여러 family 를 묶는 타입이나 manifest 는 찾지 못했다.

[사실] 한 family 안에서도 같은 사실을 여러 번 적는다.

- Exact lane 이 필수인지는 세 곳이 안다.
  - projection 의 `required = true` (`lib/server/server_standalone_lane_projection.ml:78`, `:84`)
  - 문자열 목록 `mandatory_exact_output_lane_ids` (`lib/server/server_runtime_bootstrap.ml:125-126`). 부팅 사전 검사가 이 문자열을 `String.equal` 로 비교한다 (`:133-146`).
  - 같은 목록이 `~required_lane_ids` 로 registry 에 넘어가고 (`server_runtime_bootstrap.ml:256`), registry 가 보관한다 (`lib/runtime/runtime_exact_output_registry.ml:66`). `validate_required_lanes` (`:269-283`)가 부팅 때와 config commit 때마다 검사한다 (`runtime_exact_output_registry.mli:103-122`, `:130-142`).
- 선택 lane 의 부팅 경고는 손으로 쓴 세 줄이다 (`lib/runtime/runtime.ml:3726-3728`). Librarian, Verifier, Browser Stagehand 만 있고 Workspace Curator 는 빠졌다.
- `Standalone_lane.all` 은 손으로 쓴 목록이다. 테스트가 이 목록을 자기 match 와 맞춰 본다 (`lib/runtime/standalone_lane.ml:9-12`).
- Board Attention 의 id 는 `to_id` 대신 문자열로 한 번 더 적었다 (`lib/keeper/keeper_board_attention_exact_flow.ml:4`).
- 기계 둘을 나열하는 합타입이 셋이다. `Lane_addon_sources.live_reader = Msx_screen | Dos_screen` (`lane_addon_sources.mli:23`), `activity` 의 `Msx_changed | Dos_changed` (`:28`), TUI 의 `Masc_tui_machine_live.source = Msx | Dos` (`bin/masc_tui_machine_live.ml:4`). TUI 는 `"msx_capture"`·`"dos_capture"` 를 다시 쓴다 (`:6`). 셋은 type equation 으로 묶여 있지 않아서 컴파일러가 서로 맞춰 보지 않는다.

[사실] 새 기계 하나가 닿는 파일을 DOS 로 셌다. `lib/dos_lane` 밖에서 DOS 를 이름으로 부르는 파일은 29개다(`git grep -l -i 'dos_lane\|masc_dos_\|dos_capture\|Dos_screen\|Dos_changed\|dos_live' -- lib bin scripts dune-project masc.opam`). 여기에 도구 TOML 11개(`config/tools/masc_dos_*.toml`), Skill 3개, glossary 가 더해진다.

| 컴파일러가 잡는다 | 조용하다 (문자열이나 손 목록) |
|---|---|
| `Tool_schemas_misc.misc_operation` (`[@@deriving enumerate]`, `lib/tool_schemas/tool_schemas_misc.ml:151-201`)이 강제하는 도구 이름, schema, dispatch, `activity_of_misc_operation` | `lib/tool/tool_catalog.ml:240-261` 도구 이름 문자열 |
| `Lane_addon_sources.source`·`kind`·`live_reader` 를 match 하는 서버 live 라우트와 TUI add-on 화면 | `lib/keeper/keeper_tool_descriptor.ml:2889-2912` 도구 descriptor 문자열 |
| | `lib/tool_schemas/tool_schemas_misc_toml.ml:40-50` `schema_of_name "masc_dos_*"` |
| | `lib/lane_addon/lane_addon_sources.ml:34-40` `kind_of_string`, `:249`·`:276` 의 `"workspace-msx"`·`"workspace-dos"` |
| | `bin/masc_tui_machine_live.ml:4-7` 의 따로 된 합타입 |
| | `bin/masc_tui_types.ml` 의 기계별 mutable 필드, `bin/masc_tui.ml:8321-8339` 기계 메뉴 |
| | `lib/dune`, `lib/server/dune`, `dune-project:61-69`, `masc.opam`, `scripts/opam-pin-external-deps.sh`, `lib/build_identity.ml:11`·`:1272` |

`test/` 에서 `misc_operations`·`all_of_misc_operation` 을 도는 테스트는 찾지 못했다. catalog 와 descriptor 의 문자열을 도구 목록과 맞춰 보는 검사가 있는지는 확인하지 못했다.

### 1.3 `dos-world` 는 두 번째 DOS 를 띄운다

[사실]

- 서버의 DOS 는 `ocaml-dos` 코어다. 서버 프로세스 안에 하나 있고, 모든 Keeper 가 `masc_dos_*` 로 같은 기계를 쓴다 (`lib/dos_lane/dos_lane.mli:1-7`, `dune-project:69`).
- `dos-world` 패키지는 container 안에서 js-dos/WASM DOS 를 따로 띄운다 (`addons/dos-world/README.md:3-7`, `addons/dos-world/lane.toml:5`, `:18`). Keeper 는 이 기계를 `masc_lane_act` 로 부린다. 원천을 받지 않는다 (`lane.toml:27-33`, `"maxItems": 0`).
- 라이브에 `dos-counter`(package id `dos-world`)와 `dos-output-statistics` 두 선언이 있다 (`~/me/.masc/config/lane-addons/`, 2026-09-27).
- 기록된 설계는 이렇다. lane-addon-v0 는 Add-on 을 "기존 실행 환경 위에 붙는 선택적 관측·관계 레이어" 로, 머신과 세션을 "재사용한다" 고 적었다 (`docs/design/lane-addon-v0.md:5-8`). 사건 척추 RFC 는 "기계는 서버 프로세스 안(L1)에 공유 1대 … 애드온 샌드박스로 내리지 않는다" 고 적었다 (`docs/rfc/RFC-event-spine-and-source-contract.md:89-91`).
- `dos-world` 는 공유 기계를 옮기지 않는다. 대신 에뮬레이터·도구·상태가 모두 다른 DOS 를 하나 더 띄운다. 운영자와 Keeper 는 "DOS" 를 두 개 보게 된다.
- artifact 바이트를 내는 패키지는 `dos-world` 하나다 (`rg -l artifacts addons --glob '*.{py,mjs,js}'`).
- `dos-world` 를 이름으로 부르는 파일은 28개다 (`git grep -l dos-world`). 출력 합성 안내서, `docs/examples/lane-addons/` 예제 둘, `test/test_lane_addon_config.ml`, `addons/tests/test_value_difference.py`, `addons/value-difference/README.md`, `addons/README.md`, `docs/design/lane-addon-v0.md:40`, glossary(`00-glossary.md:1081`)가 들어 있다.

### 1.4 상태 단어가 상태를 숨긴다

**"not loaded" 는 TUI 가 아직 서버에 요청하지 않았다는 뜻이다.** [사실]

1. `Lanes` 화면은 `launch_lanes_load` 로 standalone lane 만 읽는다 (`bin/masc_tui.ml:5707-5722`). Add-on 은 묻지 않는다. 코드 주석도 그렇게 적었다 (`bin/masc_tui_lane_addons.ml:1141-1147`).
2. 목록 아래의 "Lane Add-ons:" 줄은 add-on 화면이 닫혀 있으면 `state.lane_addons_cached` 를 읽는다 (`bin/masc_tui_render.ml:5872-5885`). 이 값은 `snapshot = None` 인 `initial` 로 시작한다 (`bin/masc_tui_types.ml:8124`, `bin/masc_tui_lane_addons.ml:49`).
3. `installed` 가 `Not_read` 를 돌려주고 (`bin/masc_tui_lane_addons.ml:1153-1162`), 그 줄은 `"not loaded"` 를 그린다 (`bin/masc_tui_types.ml:8420`, `:8438-8439`).
4. 첫 조회는 운영자가 add-on 화면을 열 때뿐이다 (`bin/masc_tui.ml:24316`, `:9482`, `:19957` → `:4889`).
5. 서버 쪽도 같은 말을 낸다. 첫 reconcile 전에는 `configuration_status` 가 `` `Null `` 이다 (`lib/lane_addon/lane_addon_runtime.ml:458`, 값을 넣는 곳 `:1033`·`:1051`). TUI 는 이것을 `None` 으로 읽는다 (`bin/masc_tui_lane_addons.ml:78-79`).

라이브에는 선언이 두 개 있다. 맞는 답은 "2" 다.

**"installed" 는 파일 수다.** [사실] 선언 파일 수를 센다. 문제만 낸 파일도 센다 (`bin/masc_tui_lane_addons.ml:94-97`). 도는 worker 수가 아니다. 거절된 파일도 "installed" 라는 같은 말 아래 들어간다.

**"unavailable" 은 세 원인을 한 단어로 합친다.** [사실]

- projection 은 `Unconfigured` 와 `Registry_unavailable` 을 모두 `"unavailable"` 로 낸다 (`server_standalone_lane_projection.ml:757`). 같은 행의 `config_state` 는 둘을 나누지만 (`:751-752`), 표가 그리는 것은 `status` 다.
- `Unconfigured` 는 다시 두 뜻이다. Workspace Curator 는 표를 지우는 것이 끄는 유일한 방법이다 (`lib/server/server_workspace_memory_curator.ml:307-313`). 다른 lane 에서는 "아무도 설정하지 않았다" 다.
- `Registry_unavailable` 은 설정을 못 읽었다는 뜻이 아니다. registry 가 아직 publish 되지 않았거나(`Registry_not_published`), config commit 이 진행 중이다(`Publication_busy`) (`lib/runtime/runtime_exact_output_registry.mli:169-172`). 그래서 commit 이 도는 동안 모든 exact 행이 잠깐 "unavailable" 이 된다.
- 결과적으로 "일부러 껐다", "설정을 잊었다", "commit 중이다" 가 같은 글자로 보인다. glossary 도 이 문제를 적었다 (`docs/spec/00-glossary.md:899-904`).
- `"degraded"` 도 여러 원인을 합친다 (`server_standalone_lane_projection.ml:758-767`). 받아들인 slot 이 없음, 문자열로 합쳐진 admission 오류(모든 slot 거절, Curator 의 CLI slot, Stagehand slot drop 등, `:964-992`), 마지막 실행 실패다. 앞의 둘은 일을 받을 수 없는 상태이고, 마지막은 다음 일을 받을 수 있는 상태다.

**Browser 의 `Lane_absent` 도 세 원인을 합친다.** [사실] 운영자 브라우저 미연결(`live`), WebDriver 미설정이나 시작 실패(`automation`), backend 미설치(`stagehand`)다 (`lib/tool_misc_browser_lane.ml:52-61`). automation 의 시작 실패는 세 곳에서 로그만 남긴다 (`lib/server/server_browser_webdriver.ml:230`, `:235`, `:239`). main 에는 `install_stagehand_executor` 를 부르는 곳이 없다 (`lib/browser_lane/browser_lane.ml:413`, 호출자 0). 그런데 안내 문장은 "`[browser.stagehand]` 를 설정하라" 고 말한다. main 에서는 설정해도 바뀌는 것이 없다.

**표가 없을 때의 뜻이 lane 마다 다르다.** [사실]

| Lane | 설정이 없으면 |
|---|---|
| Board Attention, HITL Auto Judge | 부팅 거절 (`server_runtime_bootstrap.ml:125-146`) |
| Librarian, Verifier, Browser Stagehand(exact) | 부팅 경고 한 줄 (`runtime.ml:3726-3728`) |
| Workspace Curator | 아무 말 없이 꺼짐 |
| Browser `automation` | 부팅 로그 한 줄, 호출 때 `Lane_absent` (`server_browser_webdriver.ml:231-232`) |
| MSX, DOS | 설정 자리가 없다. 늘 켜짐 |
| Add-on | 파일이 없으면 설치되지 않음 |

**머리글 숫자가 한 family 만 센다.** [사실] "Lanes N" 탭은 runtime candidate order 수다 (`masc_tui_render.ml:5802-5806`). "Standalone N lanes" 는 exact lane 만 센다 (`:5814-5817`, `:5834-5837`). Browser, 기계, add-on 은 세지 않는다.

라이브 runtime.toml 에는 exact 표가 넷 있다(verifier, librarian, hitl, board_attention). 그래서 Curator 와 Browser Stagehand 가 "unavailable" 로 보인다. 둘 중 어느 쪽이 일부러 끈 것인지는 설정에 남아 있지 않다.

## 2. 결정

### 2.1 Lane 을 가리키는 id 는 닫힌 타입 하나다

[제안] 타입과 순수 함수는 `lib/lane_registry/` 에 둔다. 이 디렉터리는 `masc` 라이브러리의 일부가 된다(`lib/dune` 은 `include_subdirs unqualified`). `masc` 는 `masc.runtime`, `masc.browser_lane`, `masc.tool_schemas` 를 이미 본다.

```ocaml
(* lib/lane_registry/machine_lane.mli *)
type t = Msx | Dos [@@deriving enumerate]

(* lib/lane_registry/declaration_file.mli *)
type t = private string
(* lane-addons 디렉터리의 바로 아래 .toml 파일 하나. 값은 확장자를 뺀 파일 이름이다. *)
val of_file_name : string -> t option   (* "<이름>.toml", '/' 없음, 이름이 비지 않음 *)

(* lib/lane_registry/lane_id.mli *)
type builtin =
  | Exact of Standalone_lane.t
  | Browser of Browser_lane.Lane_name.t
  | Machine of Machine_lane.t
[@@deriving enumerate]

type t =
  | Builtin of builtin
  | Package of Declaration_file.t

val to_wire : t -> string
(* exact/<Standalone_lane.to_id>, browser/<Lane_name.to_wire>,
   machine/msx|dos, package/<Declaration_file> *)
val of_wire : string -> t option
```

- 내장 Lane 목록은 손으로 쓰지 않는다. `[@@deriving enumerate]` 가 `all_of_builtin` 을 만든다. 인자 타입도 `all` 이 있어야 한다.
  - `Browser_lane.Lane_name.all` 은 이미 derive 한다 (`browser_lane_name.mli:11-12`, `browser_lane.ml:21` 이 다시 내보낸다).
  - `Standalone_lane.t` 는 손 목록을 derive 로 바꾼다. 손 목록과 그것을 지키던 테스트를 지운다. `masc.runtime` 에는 지금 `ppx_enumerate` 가 없다 (`lib/runtime/dune:67-68`). `masc.browser_lane` 은 이미 쓴다 (`lib/browser_lane/dune:8-9`).
- `Machine_lane.t` 는 새 사실이 아니다. 기계를 나열하는 합타입 셋(1.2)을 하나로 줄인다. `Lane_addon_sources.live_reader` 와 `Masc_tui_machine_live.source` 를 지우고 이 타입을 쓴다. `activity` 의 기계 생성자는 `Machine_changed of Machine_lane.t` 하나가 된다.
- Package Lane 은 선언 파일 하나로 가리킨다. 선언의 `id` 로 가리키지 않는 이유는 둘이다.
  - 못 읽는 파일에도 행이 있어야 하는데, 그런 파일에는 id 가 없을 수 있다 (`lane_addon_config.mli:14`, issue 의 `id : string option`).
  - 같은 id 를 적은 파일이 둘이면 loader 가 둘 다 뺀다 (`lane_addon_config.mli:36-37`). 그 두 파일도 각각 행이어야 한다.
- `of_wire` 는 첫 `/` 에서 한 번 나눈다. 앞은 닫힌 family 태그 넷 중 하나여야 한다. 내장 Lane 은 `all_of_builtin` 을 `to_wire` 로 되읽어 찾는다. 이름을 두 번 적지 않는다(`Standalone_lane.of_id`, `standalone_lane.ml:26` 과 같은 방식). package 는 `Declaration_file.of_file_name` 을 거친다. 경계에서 한 번 parse 하고, 안쪽 코드는 문자열을 비교하지 않는다.

### 2.2 내장 Lane 의 manifest 는 id 에서 값을 내는 exhaustive 함수들이다

[제안] manifest 는 저장하는 레코드가 아니다. id 를 받아 값을 내는 exhaustive 함수 묶음이다. wire 로 보낼 때만 한 레코드로 모은다. 그래서 "container 인데 exact 설정 자리" 같은 조합은 어디에도 저장되지 않는다. 두 값 모두 같은 id 에서 계산되기 때문이다.

```ocaml
(* masc.runtime, standalone_lane.mli — 필수 여부는 여기 한 곳만 안다 *)
type obligation = Required | Optional
val obligation : t -> obligation   (* exhaustive *)

(* masc — lib/lane_registry *)
type process =
  | In_server                          (* exact lane, 기계 *)
  | In_server_with_operator_browser    (* live *)
  | In_server_with_spawned_browser     (* automation: geckodriver+Firefox, stagehand: Chromium *)
  | Container                          (* package *)

type config_home =
  | Exact_output_table of Standalone_lane.t        (* [runtime.exact_output_lanes.<id>] *)
  | Browser_table of Browser_lane.Lane_name.t      (* [browser.<lane>] *)
  | Machine_table of Machine_lane.t                (* [machines.<id>] *)
  | Declaration of Declaration_file.t              (* <config-root>/lane-addons/<파일>.toml *)

val label : Lane_id.builtin -> string
val purpose : Lane_id.builtin -> string
val process : Lane_id.t -> process
val config_home : Lane_id.t -> config_home
val tools : Lane_id.builtin -> Tool_schemas_misc.misc_operation list
val serves : Standalone_lane.t -> Browser_lane.Lane_name.t option
val offers : Lane_id.builtin -> Lane_addon_sources.kind list      (* Lane_addon_sources 에 둔다 *)
```

내장 manifest 가 코드와 어긋나지 않게 하는 방법:

- **label·purpose.** `lane_spec` (`server_standalone_lane_projection.ml:72-110`)의 label 과 purpose 를 이 함수로 **옮긴다.** 복사하지 않는다.
- **필수 여부.** `Standalone_lane.obligation` 한 곳에만 적는다. `masc.runtime` 안에 두는 이유는 registry 가 `masc.runtime` 에 있기 때문이다. `required_lane_ids` 는 이 함수로 `Standalone_lane.all` 을 걸러 만든다. 문자열 목록 `mandatory_exact_output_lane_ids` 와 projection 의 `required` 필드는 지운다. 필수 여부만 exact family 에 있다. 다른 family 에는 필수 Lane 이 없다(2.3).
- **tools.** 새 exhaustive 함수 `lanes_of_misc_operation : Tool_schemas_misc.misc_operation -> Lane_id.builtin list` 를 둔다. 목록인 이유가 있다. `Misc_browser_*` 도구는 `lane` 인자로 backend 셋을 모두 받는다 (`lib/tool_misc_browser_lane.ml:40-47`). 어떤 verb 를 어느 backend 가 받는지는 `Browser_lane` 이 계속 정한다 (`browser_lane.ml:176`, `:186`, `:196`). `masc_lane_*` 는 빈 목록이다. 이 도구들은 package 설치에 붙는다. `Misc_dos_*` 를 하나 더하면 이 함수를 채울 때까지 컴파일되지 않는다.
- **offers.** 원천 종류를 누가 내놓는지는 `Lane_addon_sources` 가 이미 정한다 (`lane_addon_sources.ml:85-86` 의 stagehand 거절, `:113-115` 의 `kind_of_live_reader`). 같은 사실을 registry 에 다시 적지 않는다. `Lane_addon_sources.offers : Lane_id.builtin -> kind list` 를 exhaustive 로 두고, `parse` 가 이 함수를 써서 browser 원천을 받을지 정한다. 그러면 거절 규칙과 목록이 같은 함수에서 나온다.
- **serves.** `Browser_stagehand` 만 `Some Stagehand` 다. 이 exact lane 을 부르는 곳은 Stagehand backend 의 `llm.generate` 뿐이다 (RFC-browser-lane-stagehand §3.7, `docs/rfc/RFC-browser-lane-stagehand.md:282-289`). 목록은 이 값으로 "exact lane 은 준비됐는데 부를 backend 가 없다" 를 보인다.
- **reads.** 내장 Lane 은 Lane 원천을 읽지 않는다. 자기 도메인 저장소(Board 후보, 보류 승인, Keeper 기록 등)를 읽고, 그 설명은 `purpose` 가 한다. package 가 읽는 원천은 선언의 binding 에서 온다.

내장 Lane 에 `lane.toml` 을 주지 않는다. 코드와 파일 두 곳에 같은 사실을 적으면 둘이 어긋난다. 내장은 코드가, package 는 `lane.toml` 이 manifest 를 만든다.

컴파일러가 잡지 못하는 것은 테스트가 잡는다. `all_of_builtin` 의 wire id 가 모두 다르고 `of_wire (to_wire x) = Some x` 인지, 모르는 wire 문자열이 `None` 인지 본다.

### 2.3 켜고 끄는 규칙은 하나다

[제안] 규칙:

1. **내장 Lane 11개는 모두 runtime.toml 에 자기 표를 가진다.** 표가 없으면 load 오류다. 오류는 빠진 표 이름을 적는다. seed `config/runtime.toml` 은 11개를 모두 적는다.
2. **모든 표와 모든 선언 파일은 `enabled = true` 나 `enabled = false` 를 적는다.** 빠지면 load 오류다. 기본값은 두지 않는다. load 단위는 지금과 같다.
   - runtime.toml 은 파일 전체가 한 단위다. 모르는 키도 지금 파일 전체의 load 오류다 (`lib/runtime/runtime_toml.ml:2628-2648`). 부팅이면 뜨지 않고, config commit 이면 거절되고 이전 registry 가 남는다.
   - 선언 파일은 파일 하나가 한 단위다. 지금도 모르는 필드는 그 파일의 오류다 (`lib/lane_addon/lane_addon_config.ml:103-105`). reconcile 은 그 파일의 마지막 적용 상태를 유지한다 (`lane_addon_runtime.mli:31-33`).
3. 그래서 **"선언 없음" 은 행 상태가 아니다.** 내장 Lane 은 표가 없으면 서버가 뜨지 않는다. package 는 파일이 있어야 행이 생긴다. 지금 Curator 가 표 없이 조용히 꺼지는 경로(`server_workspace_memory_curator.ml:307-313`)와 그것을 만드는 `Exact_lane_unconfigured` 는 사라진다.
4. **exact lane 의 slot 규칙.** 지금 parser 는 모든 exact 표에 slot 을 하나 이상 요구한다 (`runtime_toml.ml:2731`, "exact-output lane must have at least one slot"). 이 규칙은 `enabled = true` 인 표에만 둔다. 규칙 1 로 모든 표가 필수가 되므로, 꺼 둔 lane 에 쓰지 않을 slot 을 지어 넣게 할 이유가 없다. `enabled = false` 인 표에 slot 이 있으면 그대로 둔다. 다시 켤 때 쓴다.

**필수 Lane 을 지키는 곳은 한 곳이다.** registry 의 `validate_required_lanes` (`runtime_exact_output_registry.ml:269-283`)가 부팅 때와 모든 config commit 때 검사한다. 이 RFC 는 그 옆에 규칙을 더하지 않는다.

- 입력만 바뀐다. `required_lane_ids` 가 `Standalone_lane.obligation` 에서 나온다(2.2).
- `enabled = false` 인 lane 은 slot 을 받아들이지 않는다. 그래서 필수 lane 을 끄는 파일은 같은 검사에 걸린다. 부팅이면 뜨지 않고, commit 이면 거절된다. 운영자가 고칠 키가 달라서 오류 생성자를 하나 더한다. `Required_lane_disabled of { lane_id }` 는 `enabled` 를 고치라고 말하고, 지금의 `Required_lane_unavailable` 은 slot 을 고치라고 말한다.
- 필수 lane 이 받아들인 slot 을 하나 이상 가져야 하는 규칙과, rule 3 으로 비워진 lane 을 면제하는 규칙(`server_runtime_bootstrap.ml:248-257`)은 그대로 둔다.
- 부팅의 사전 검사 `mandatory_exact_output_lane_violations` (`server_runtime_bootstrap.ml:133-146`)는 지운다. 그 두 경우(표 없음, slot 없음)는 규칙 1 과 규칙 4 로 parser 의 load 오류가 된다.

**필수 Lane 은 Board Attention 과 HITL Auto Judge 뿐이다.** 지금과 같다.

- Board Attention: 후보는 모델 호출 전에 영속화되고 만료가 없다 (constitution `keeper_attention`, `no_wall_clock_death`). 이 lane 이 없으면 어떤 후보도 판정되지 않는다. Keeper 끼리 Board 로 주고받는 일이 멈춘다. constitution 의 실패 조건 "여러 Keeper 가 자기들끼리 커뮤니케이션하지 않는다" 다.
- HITL Auto Judge: 코드는 필수로 두지만 이유를 적은 곳을 찾지 못했다. 3장 (d3) 에서 확인을 받는다.
- 나머지 9개는 선택이다. 기계와 Browser 가 없어도 Keeper turn 은 돈다.

**`enabled` 는 새 필드이고, 새 거절을 만든다.** 근거는 둘이다.

- 운영자가 2026-09-27 에 "설정으로 켜고 끈다" 를 골랐다. 기계와 `live` Browser 의 켜고 끄기는 이 결정이 근거다. 지금은 끌 방법 자체가 없다.
- exact lane 에서는 지금 사실 하나가 사라진다. 운영자가 "껐다" 는 사실이 설정에 남지 않는다. Curator 는 표를 지워야 꺼지고, 지우면 slot 설정도 같이 사라진다.

이 결정이 만드는 새 거절은 "꺼진 Lane 에 대한 요청 거절" 한 종류다. family 마다 생성자 하나씩이다(아래 표). 다른 Gate 는 더하지 않는다.

| family | 설정 자리 | 지금 | 바뀌는 것 |
|---|---|---|---|
| Exact | `[runtime.exact_output_lanes.<id>]` | 표가 있으면 켜짐 | 6개 표 모두 필수, `enabled` 필수 |
| Browser `live` | `[browser.live]` | 없음 | 새 표. `enabled` 만 |
| Browser `automation` | `[browser.automation]` | `[browser] geckodriver/binary` | 두 키를 옮기고 `enabled` 를 더한다. 3장 (d5) |
| Browser `stagehand` | `[browser.stagehand]` | 같은 자리. 없어도 된다 | 필수, `enabled` 를 더한다. chrome·extension·profile 은 `enabled = true` 일 때만 필수 |
| 기계 | `[machines.msx]`, `[machines.dos]` | 없음. 늘 켜짐 | 새 표. `enabled` 만 |
| Package | 선언 파일 | 파일이 있으면 설치 | `enabled` 필수 |

꺼진 Lane 이 무엇을 거절할지는 그 Lane 을 가진 모듈이 지금 판단하는 곳에서 정한다. 새 목록 모듈은 Lane 을 켜거나 끄지 않는다.

| family | 꺼지면 | 언제 반영되나 |
|---|---|---|
| Exact | registry 가 slot 을 받지 않는다. 호출자는 typed 거절 `Exact_lane_off` 를 받는다. Curator 의 시작 판단도 이 값을 읽는다 | config commit 때. commit 이 registry 를 바꾸는 지금 경로 그대로다 |
| Browser `live` | host 가 가져가는 요청과 도구 호출이 typed 거절 `Lane_off` 를 받는다. `Lane_absent` 와 다른 답이다 | 켜기와 끄기 모두 다음 요청부터. `live` 는 부팅 때 설치하는 것이 없다 |
| Browser `automation`, `stagehand` | 요청이 `Lane_off` 를 받는다 | 끄기는 다음 요청부터. 켜기는 다음 부팅부터다. executor 설치가 부팅 때 한 번이기 때문이다 (`server_browser_webdriver.ml:229-245`). 그 사이 행은 `Waiting_for_restart` 다 |
| 기계 | 도구 목록에는 남는다. 호출은 설정 키를 적은 typed 거절을 받는다. live 라우트는 `off` 를 답한다. 기계 메모리의 상태는 지우지 않는다 | 다음 호출부터 |
| Package | 지금 선언을 지울 때 하는 detach 를 한다. 선언 파일과 보존한 증거는 남는다. 행도 남는다 | 다음 reconcile 부터 |

"다음 요청부터" 에 필요한 장치가 둘 있다. 둘 다 영속 저장이 아니다. 정본은 설정 파일이다.

- **게시된 enabled 값.** 부팅과 모든 config commit 이 확정된 설정에서 Lane 별 `enabled` 를 뽑아 `Atomic` 하나에 게시한다. exact registry 를 바꾸는 같은 commit 경로에서 한다. 기계 도구 dispatch, Browser 요청, live 라우트가 이 값을 읽는다. live 라우트의 빠른 길은 `Atomic.get` 하나가 늘 뿐이라 잠금을 잡지 않는다.
- **Browser 부팅 설치 결과.** 부팅의 설치가 backend 마다 `Installed | Install_failed of install_failure | Not_started_off` 를 `Atomic` 에 남긴다. `install_failure` 는 지금 로그만 남기는 세 exit 에서 온다: `Config_invalid`(`server_browser_webdriver.ml:230`), `Launch_failed`(`:235`), `Driver_unready`(`:239`). stagehand 설치(#38739)도 같은 타입을 쓴다.

### 2.4 배포는 두 단계다

[사실] 설정 파일을 고치는 길은 떠 있는 서버의 admin raw endpoint 다. 이 endpoint 는 **떠 있는 바이너리**의 parser 로 검사한다. 그 parser 는 모르는 키를 거절한다 (`runtime_toml.ml:2628-2648`, 선언은 `lane_addon_config.ml:103-105`).

그래서 `enabled` 를 요구하는 바이너리를 한 번에 내보내면 막힌다. 옛 서버는 `enabled` 를 모르니 파일에 넣을 수 없다. 새 서버는 `enabled` 없는 파일로는 뜨지 않는다. 2026-09-27 에 같은 모양의 사고가 있었다. 리드 보고에 따르면 16:16Z 에 병합된 hard cut(#38795/#38966, sandbox_image 이름)이 라이브 Keeper TOML 24개를 모두 무효로 만들었다. 서버는 Keeper 24개가 설정 오류인 채로 떴고, 손으로 고쳤다. 설정 API 로는 고칠 수 없었다(#39373, 열림). 시각과 개수는 리드 보고이고 이 RFC 작성자가 직접 확인하지 않았다.

[제안] 그래서 설정 키를 더하는 PR 은 둘로 나눈다.

1. **받아들이는 PR (PR-4a).** parser 가 새 표와 `enabled` 를 안다. 적혀 있으면 그대로 따른다. 없으면 지금처럼 동작한다. 이것은 옛 데이터를 읽는 호환 reader 가 아니다. 떠 있는 서버의 admin raw endpoint 가 새 키를 받게 하는 단계다. 다음 PR 이 이 "없으면 지금처럼" 가지를 지운다. `[browser] geckodriver/binary` 도 이 PR 동안에만 두 자리 중 한 곳에서 읽는다. 두 자리에 모두 있으면 load 오류다.
2. **운영자 단계.** PR-4a 가 배포된 뒤, admin raw endpoint 로 라이브 runtime.toml 에 아래를 넣는다. 파일을 직접 고치지 않는다.

   ```toml
   # 이미 있는 exact 표 넷에 한 줄씩
   [runtime.exact_output_lanes.verifier_exact]
   enabled = true
   [runtime.exact_output_lanes.librarian_exact]
   enabled = true
   [runtime.exact_output_lanes.hitl_auto_judge]
   enabled = true
   [runtime.exact_output_lanes.board_attention_exact]
   enabled = true

   # 새 exact 표 둘. 라이브에서 지금 꺼져 있으므로 false
   [runtime.exact_output_lanes.workspace_curator_exact]
   enabled = false
   [runtime.exact_output_lanes.browser_stagehand_exact]
   enabled = false

   # Browser. [browser] 의 geckodriver·binary 는 [browser.automation] 으로 옮기고 [browser] 에서 지운다
   [browser.live]
   enabled = true
   [browser.automation]
   enabled = true
   geckodriver = "<지금 [browser].geckodriver 값>"
   binary = "<지금 [browser].binary 값>"
   [browser.stagehand]
   enabled = false

   # 기계. 지금 늘 켜져 있으므로 true
   [machines.msx]
   enabled = true
   [machines.dos]
   enabled = true
   ```

   모든 값은 지금 라이브의 동작을 그대로 옮긴 것이다. 켜져 있던 것은 `true`, 꺼져 있던 것은 `false` 다.
3. **요구하는 PR (PR-4b).** 표나 `enabled` 가 없으면 load 오류다. 배포는 #39345 의 preflight 를 거친다. #39345 는 새 바이너리의 검사로 라이브 runtime.toml 을 **이전 서버를 멈추기 전에** 읽고, 거절하면 배포를 멈춘다(`scripts/deploy.sh` 3단계 앞, `scripts/install-local-build.sh`). 운영자 단계를 빠뜨렸으면 서버는 멈추지 않고 옛 바이너리로 계속 돈다. 그래서 PR-4b 는 #39345 가 병합된 뒤에만 진행한다.

package 선언도 같은 순서다. PR-5a 가 선언의 `enabled` 를 받아들이고, 운영자가 선언 저장 API 로 라이브 선언 둘에 `enabled = true` 를 넣고, PR-5b 가 요구한다. #39345 는 선언 디렉터리를 읽지 않는다. 다만 선언 파일의 load 오류는 그 파일 하나의 문제이고, reconcile 이 마지막 적용 상태를 유지한다(2.3 규칙 2). 서버 전체가 멈추지는 않는다.

### 2.5 상태는 family 마다 닫힌 타입이다

[제안] 한 평평한 상태 타입은 "기계인데 브라우저 연결 끊김" 같은 없는 상태도 적을 수 있다. 그래서 family 마다 따로 두고 행 타입의 생성자로 묶는다. 각 생성자가 자기 family 의 id 와 상태를 함께 가진다.

```ocaml
type exact_state =
  | Off
  | Not_admitted of exact_admission_problem   (* 켜졌지만 받아들인 slot 이 없다 *)
  | Idle
  | Running of { runs : int }

type live_browser_state =
  | Off
  | Disconnected                              (* 연결된 운영자 브라우저가 없다 *)
  | Connected of { clients : int }

type spawned_backend = Automation_backend | Stagehand_backend
type spawned_browser_state =
  | Off
  | Waiting_for_restart                       (* 켰지만 부팅 때 꺼져 있어서 설치하지 않았다 *)
  | Install_failed of install_failure
  | Ready

type machine_state =
  | Off
  | Idle of { program : string option }       (* None: 올린 프로그램이 없다 *)
  | Running                                   (* 게시된 표식이 Running *)

type package_declaration =
  | Accepted of { enabled : bool; desired_revision : string }
  | Rejected of Lane_addon_config.problem
type package_worker =
  | No_worker
  | Worker of { phase : Lane_addon_types.phase; applied_revision : string }
type package_state = { declaration : package_declaration; worker : package_worker }

type row =
  | Exact of Standalone_lane.t * exact_state
  | Browser_live of live_browser_state
  | Browser_spawned of spawned_backend * spawned_browser_state
  | Machine of Machine_lane.t * machine_state
  | Package of Declaration_file.t * package_state
```

- Browser 는 `Browser_lane.Lane_name.t` 를 exhaustive 함수로 `live` 와 spawned 둘로 나눠 행을 만든다. `live` 에는 설치가 없고 spawned 에는 연결이 없어서다.
- package 는 곱타입이다. 선언과 worker 는 따로 있을 수 있다. 새 선언이 거절돼도 이전 revision 의 worker 는 계속 돈다 (`lane_addon_runtime.mli:31-33`). `Rejected` 이면서 `Worker { phase = Observing }` 인 행이 그 상태다. "켰는데 아직 반영 안 됨" 은 `Accepted { enabled = true; desired_revision }` 과 worker 의 `applied_revision` 이 다른 것이다. 따로 저장하지 않고 그릴 때 계산한다.

**상태를 만드는 곳**

| 상태 | 만드는 곳 |
|---|---|
| exact `Off` | registry admission. `enabled = false` |
| exact `Not_admitted` | registry admission. 지금 문자열로 합쳐지는 원인들(`server_standalone_lane_projection.ml:964-992`)을 PR-1b 가 `exact_admission_problem` 의 생성자로 하나씩 옮긴다 |
| exact `Idle`·`Running` | exact run registry 의 실행 중 run 수 (`server_standalone_lane_projection.ml:764`) |
| `live` `Disconnected`·`Connected` | 새 `Browser_lane.connected_client_count ()`. 지금의 `active_clients ()` 는 쓰지 않는다. 그 함수는 연결이 끊긴 client 를 정리하고 기다리던 요청을 `client_disconnected` 로 끝낸다 (`browser_lane.ml:247-262`). 새 함수는 같은 잠금 아래에서 `connected` (`:244`)만 세고 아무것도 바꾸지 않는다 |
| spawned `Install_failed`·`Ready`·`Waiting_for_restart` | 2.3 의 Browser 부팅 설치 결과와 게시된 enabled 값 |
| 기계 `Idle`·`Running` | `Msx_lane`·`Dos_lane` 의 게시된 표식 (`Machine_live_publication`, `lib/server/server_routes_http_routes_lane_addons.ml:196-210`) |
| 모든 `Off` | 게시된 enabled 값 |
| package `Rejected` | `Lane_addon_config.load` 의 issue. 지금은 `message : string` 이다 (`lane_addon_config.mli:14`). PR-5a 가 원인을 `problem = Unreadable | Invalid of string | Duplicate_id` 로 나눈다. `Invalid` 의 문자열은 화면에 보이는 설명이고, 코드는 이 문자열로 분기하지 않는다 |
| package worker | `Lane_addon_runtime` 의 phase 와 적용 revision. phase `Failed of string` 은 지금 타입 그대로다 (`lane_addon_types.mli:54`). 그 문자열도 설명일 뿐이다 |

**행 상태가 아닌 것**

- **마지막 실행 결과.** 마지막 run 이 실패한 exact lane 도 다음 일을 받는다. 그 결과는 행의 상세(지금 있는 latest terminal)에 둔다. 그래서 exact lane 과 기계에는 `Failed` 가 없다. 기계 fault 는 실행 하나를 끝낼 뿐 기계는 남는다.
- **설정을 못 읽음.** 내장 Lane 에는 이 상태가 없다. runtime.toml 이 부팅 때 틀리면 서버가 뜨지 않는다. commit 때 틀리면 commit 이 거절되고 이전 설정이 남는다.
- **commit 진행 중.** registry 의 `current ()` 는 commit 동안 `Publication_busy` 를 돌려준다. 이것은 읽기 경합이지 Lane 상태가 아니다. 목록은 `current ()` 대신 새 읽기 전용 함수 `last_published : unit -> t option` 을 쓴다. 이 함수는 게시된 `Atomic` (`runtime_exact_output_registry.ml:141`)을 그대로 읽는다. commit 이 끝나기 전까지는 이전 registry 가 실제로 쓰이는 값이므로 그것을 보여 준다.
- **registry 게시 전.** `last_published ()` 가 `None` 이면 목록 전체가 `registry_not_published` 로 답한다. 행 하나의 상태가 아니다. 서버가 요청을 받기 시작하는 시점과 게시 시점 사이에 이 창이 실제로 있는지는 PR-1b 가 확인한다.
- **선언 디렉터리를 다 못 읽음.** `Lane_addon_config.load` 의 `complete = false` 다 (`lane_addon_config.mli:20`, `:33-35`). Packages 묶음 전체에 붙는 값이다. 묶음 제목이 "목록에 빠진 파일이 있을 수 있음" 을 적는다.
- **"아직 읽지 않음".** TUI 가 목록을 아직 받지 못한 상태다. 서버는 이 값을 만들지 않는다. TUI 는 목록 전체를 `Not_read | Read_failed of string | Read of registry` 로 든다. TUI 작업대 RFC(#39231) S7-1 의 `Masc_tui_fetched` 와 같은 방향이다.

서버의 lane 상태 wire 에서 `"unavailable"` 과 `"degraded"` 는 사라진다.

**생성자를 더하고 빼는 PR.** 아무도 만들지 않는 생성자를 먼저 두지 않는다. 더는 만들 수 없게 된 생성자는 그 PR 에서 지운다.

| 생성자 | 더하는 PR | 지우는 PR | 이유 |
|---|---|---|---|
| exact `Undeclared`, spawned `Undeclared` | PR-1b | PR-4b | PR-4b 전에는 표가 없을 수 있다(라이브 Curator) |
| spawned `Not_installed` | PR-1b | PR-4a | 부팅 설치 결과를 기록하기 전에는 "설정했는데 slot 이 빔" 의 원인을 모른다. PR-4a 가 `Install_failed`·`Waiting_for_restart` 로 나눈다 |
| 모든 `Off`, spawned `Install_failed`·`Waiting_for_restart` | PR-4a | — | `enabled` 와 설치 결과가 PR-4a 에서 생긴다 |
| package `Rejected` 의 `problem` | PR-5a | — | |

### 2.6 목록을 읽는 곳은 하나다: `GET /api/v1/lanes`

[제안]

- 한 번 읽으면 모든 행이 온다. 내장 Lane 행은 `all_of_builtin` 에서, package 행은 선언 디렉터리의 파일에서 온다.
- 행마다 wire id, family, label, purpose, process, 설정 자리, 필수 여부(exact 만), 상태, 원천(offers·reads), 도구 이름, serves, family 별 상세가 온다. 상세는 이렇다.
  - exact: 지금 standalone projection 의 slot·run 필드
  - package: desired/applied revision, phase, instance id
  - 기계: 올린 프로그램, 조종권
  - Browser: 연결된 client 수, 설치 결과
- **어디에 두나.** 타입과 순수 함수는 `lib/lane_registry` (`masc`)에 둔다. 행을 만드는 코드와 route 는 `lib/server` (`masc.server`)에 둔다. 상태를 읽을 곳(exact run registry 조회, Browser 설치 결과, add-on 주인)이 `masc.server` 쪽에 있기 때문이다 (`lib/server/dune:15`, `:20`).
- **읽기 전용이다.** 시작·정지·재시도를 하지 않는다. 아무것도 쓰지 않는다. `Server_standalone_lane_projection` 의 약속과 같다 (`server_standalone_lane_projection.mli:1-7`). Browser 는 정리하지 않는 `connected_client_count`, exact 는 fence 를 잡지 않는 `last_published` 를 쓴다(2.5).
- **파일 읽기는 server fiber 밖에서 한다.** 선언 디렉터리 읽기는 `lane_addon_config.mli:1-3` 이 요구하는 대로 offload 한다.
- **package 행은 첫 reconcile 을 기다리지 않는다.** 선언 파일이 "설치했다" 의 정본이다. 목록은 `Lane_addon_config.load` 로 파일을 직접 읽는다. reconcile 은 적용 상태만 준다. 그래서 첫 reconcile 전에 목록이 비어 보이는 문제(1.4 의 5번)가 생기지 않는다. 그때 행의 worker 는 `No_worker` 다.
- **projection 위에 projection 을 얹지 않는다.** PR-1b 는 standalone projection 의 행 만들기를 이 모듈로 옮기고 `Server_standalone_lane_projection` 을 지운다. 옛 route `/api/v1/dashboard/standalone-lanes` 는 TUI(PR-2a)와 Dashboard(PR-3)가 옮길 때까지 남는다. 그동안 옛 route handler 는 새 모듈의 exact 행을 옛 wire 모양으로 적기만 한다. 둘 중 늦게 들어가는 PR 이 옛 route 를 지운다.
- 권한은 지금 standalone-lanes 와 같다.

### 2.7 TUI `Lanes` 는 목록 하나다

[제안]

- `Lanes` 화면은 자기 load 에서 `/api/v1/lanes` 를 읽는다. 목록 아래의 "Lane Add-ons:" 줄, `installed_reading`, 그 줄이 add-on 캐시를 읽던 길을 지운다.
- 행은 family 로 묶는다. 순서는 Exact-output(6), Browser(3), Machines(2), Packages(N) 다. 묶음 제목은 수와 상태별 수를 적는다. 예: `Machines 2 · idle 1 · off 1`, `Packages 2 · observing 1 · rejected 1`. 거절된 선언 파일도 행이지만, "installed" 같은 한 단어 아래 섞지 않고 상태로 따로 센다.
- 머리글 숫자는 목록에서 센다. 지금 "Lanes N" 탭은 runtime candidate order 를 센다. 이 탭 이름을 3장 (a) 에 따라 먼저 바꾼다. 그래서 PR-2a 는 (a) 결정 뒤에 한다. 탭 글자만 PR-2a 가 바꾸고, TOML 키와 타입 이름은 PR-8 에서 바꾼다.
- 행에서 Enter:
  - exact 행: 지금 상세와 slot 편집(#39293)
  - Browser 행: Browser Lane 화면. 3장 (c)
  - 기계 행: 그 기계를 고른 채로 여는 새 입구. 지금 `open_msx_screen` (`bin/masc_tui.ml:8321`)은 관전 화면이 아니라 기계 메뉴를 연다 (`:8318` 주석). PR-2b 가 기계를 받아 관전 화면을 여는 함수를 더한다. `&` 는 지금처럼 메뉴를 연다.
  - package 행: 그 설치를 고른 add-on 화면
- `&`, `B`, Ctrl-^, `A`, `/addons` 는 같은 곳으로 가는 지름길로 남는다.
- 팔레트의 "go MSX" 는 DOS 도 읽는 메뉴를 연다 (`bin/masc_tui.ml:8339`). 이름을 "go Machines" 로 바꾼다.
- TUI 작업대 RFC(#39231) §4.1 은 `Lanes(Standalone)`, `Runtime(Lanes, All runtimes)`, `Clients` 를 `System › Lanes` 한 화면에 모은다. 이 목록이 그 화면의 Lane 구역이 된다.

### 2.8 Add-on 은 프로세스 종류 하나가 된다

[제안] Lane Add-on 패키지 설치는 목록에서 `process = Container` 인 Lane 이다. 설치·적용·제거 주기(`Lane_addon_runtime`)는 그대로 쓴다. 패키지를 더할 때 서버·TUI·Dashboard 코드를 고치지 않는다는 약속도 그대로다 (`lane-addon-v0.md:53`).

원천은 세 곳에서 온다. 내장 Lane 이 내놓는 것(기계 화면, 브라우저 문서), package 가 내놓는 출력(`lane_output`), 설치자가 묶은 파일(`snapshot_file`)이다.

아래 문장은 이 RFC 가 대신한다. 5장 PR-6 이 문서를 고친다.

| 문서 | 지금 문장 | 바뀌는 것 |
|---|---|---|
| `docs/design/lane-addon-v0.md:5-8` | "Lane Add-on은 기존 MASC 원장과 실행 환경 위에 붙는 선택적 관측·관계 레이어다. MSX Lane의 머신, Browser Lane의 세션 … 재사용한다. 패키지 하나가 여러 Lane 행을 제공할 수 있다." | Lane Add-on 은 container 로 도는 Lane 이다. 내장 Lane 과 다른 package 가 내놓는 원천을 받거나, 자기 환경을 가진다. "여러 Lane 행" 의 "Lane" 은 3장 (d1) 에 따라 바뀐다 |
| `docs/design/lane-addon-v0.md:53-54` | 첫 문장(패키지 추가에 코드 수정 없음)과 둘째 문장(원천 드라이버와 의미 레이어를 구분) | 첫 문장은 그대로다. 둘째 문장은 이렇게 바뀐다. 새 장치의 원천은 내장 Lane 을 더하는 일이고, `Lane_id.builtin` 에 생성자를 더하는 일이다 |
| `docs/design/lane-addon-v0.md:56-61` | "기존 MSX·Browser Lane과의 관계" | 내용(기계는 `Msx_lane` 이 가진다, 잠금 밖 처리)은 그대로다. 지금은 기계를 Add-on 이 빌려 쓰는 원천으로 적었다. 앞으로는 기계 Lane 이 내놓는 관측을 package Lane 이 받아 쓴다고 적는다 |
| `docs/spec/00-glossary.md:1077-1090` Lane Add-on | "기존 MASC 원장과 실행 환경 위에 붙는 선택적 관측·관계 레이어" | 위와 같이 고친다 |
| `docs/spec/00-glossary.md:827-846` Lane | "모델이 도는 exact-output 작업을 위한 고정 실행 경로. 다섯 …" (실제는 여섯) | Lane 은 목록의 한 줄이다. exact-output lane 은 그중 한 family 다 |
| `docs/spec/00-glossary.md:890-909` Standalone Lane | 표 이름과 `sl_status` 다섯 값 | 목록의 exact family 와 2.5 의 `exact_state` 로 고친다 |
| `docs/rfc/RFC-event-spine-and-source-contract.md:54-61` | "Lane은 원시 개념이 아니다" | 대신한다. Lane 은 운영자가 켜고 끄는 단위의 이름이다. 사건 순서의 계약은 여전히 event source 다. 두 축은 겹치지 않는다 |
| `docs/rfc/RFC-event-spine-and-source-contract.md:89-91` | "기계는 서버 프로세스 안(L1)에 공유 1대 … 애드온 샌드박스로 내리지 않는다" | **그대로 둔다.** 운영자가 고른 안(내장 Lane 은 서버 안에 남는다)은 이 원칙과 맞는다 |
| `docs/design/tui-lane-experience.md:37` | "메인 `Lanes`는 standalone Lane 목록과 실행 상세를 유지한다" | 목록 하나(2.7) |
| `docs/guides/tui-lane-addons.md:6` | "`Lanes`는 standalone 실행과 실행 상세를 다룬다. Add-ons는 패키지 …" | 목록 하나(2.7) |

### 2.9 "lane" 이 멈추는 곳

[제안]

- 목록의 한 줄이 Lane 이다. 나머지는 Lane 이 아니다.
- runtime candidate order, add-on 행의 열, Keeper sandbox 실행 경로는 3장 (a), (d1), (d2) 에서 정한다.
- 서버 안 모듈 이름(`Keeper_lane` fiber, `Keeper_memory_lane`, `keeper_egress_lane`, `slack_lane`, `connector_ingress_lane` 등)은 바꾸지 않는다. 운영자와 Keeper 가 보는 말이 아니다. glossary 경계 문단(`00-glossary.md:836-841`)은 이 중 `Keeper_lane` 과 `Keeper_memory_lane` 만 적었다. PR-6 이 나머지도 그 문단에 한 줄씩 더한다. 수십 파일을 건드리는 이름 변경으로 얻는 것은 없다.

## 3. 운영자가 정할 것

**(a) runtime candidate order 의 이름**

| 안 | 내용 | 장점 | 단점 |
|---|---|---|---|
| a1 | `candidate order`. `[runtime.candidate_orders.<name>]`, `Runtime_candidate_order.t`, TUI 탭 "Candidate orders" | glossary 가 이미 이 이름이다 (`00-glossary.md:848-856`) | 길다 |
| a2 | `ladder`. `[runtime.ladders.<name>]` | 짧다. RFC-0457 이 "사다리" 로 불렀다 | glossary 를 한 번 더 고쳐야 한다 |
| a3 | "lane" 을 두고 목록을 다른 이름으로 부른다 | 이름 변경이 없다 | 운영자가 "Lanes" 화면에 모으라고 했다. 한 말이 두 뜻으로 남는다 |

권고: **a1**. 파일 수(`git grep -l`): `Runtime_lane.` 은 lib·bin 10개, `runtime.lanes` 는 lib·bin 13개이고 저장소 전체로는 55개(test, docs, benchmarks, scripts 포함)다. hard cut 이다. 라이브 runtime.toml 의 표 이름을 바꾸는 일도 2.4 와 같은 두 단계가 필요하다. #38892(Dashboard 에서 runtime lane 편집, 열림)와 충돌한다. #38892 가 먼저 병합되거나, #38892 가 새 이름을 쓰게 된 뒤 진행한다.

**(b) `dos-world`**

| 안 | 내용 | 장점 | 단점 |
|---|---|---|---|
| b1 | 두 번째 DOS 로 그대로 둔다 | 작업 없음 | 목록에 "DOS" 가 둘이다. 에뮬레이터·도구·상태가 다르다 |
| b2 | 서버 DOS 를 원천(`dos_capture`)으로 받게 바꾼다 | DOS 가 하나가 된다 | act 를 잃는다. 원천은 관측만 가져온다 (`lane_addon_sources.mli:1-3`). 서버 기계에 입력을 넣는 원천은 없다. `dos_capture` 에는 화면·입력 기록·steps·program·controller 가 있고 `STATE.BIN` 이 없다 (`lane_addon_sources.ml:262-283`). 패키지의 뜻이 바뀐다 |
| b3 | 지운다 (hard cut) | DOS 가 하나가 된다. js-dos 이미지와 CI(`.github/workflows/lane-dos-package.yml`)가 사라진다 | 자기 환경을 가진 패키지 예와 artifact 바이트를 내는 유일한 패키지가 사라진다. `dos-world` 를 부르는 파일 28개(1.3)의 생산자를 바꿔야 한다. 라이브 선언 둘을 지운다 |
| b4 | 그대로 두되 이름에서 DOS 를 뺀다 (예: `counter-sandbox`). 제목과 README 가 "workspace DOS 가 아닌 패키지 전용 sandbox" 라고 말한다 | 2.8 의 새 정의(container Lane 은 자기 환경을 가질 수 있다)와 맞는다. 공유 기계는 서버에 남는다. artifact 경로와 합성 예제가 남는다 | 에뮬레이터 두 벌을 계속 유지한다. id 가 바뀌므로 라이브 선언 둘을 다시 저장한다 |

권고: **b4**. 기록된 원칙은 "공유 기계" 를 container 로 내리지 말라는 것이다. `dos-world` 는 공유 기계를 옮기지 않는다. 운영자와 Keeper 가 헷갈리는 원인은 이름이다. 운영자가 패키지 전용 에뮬레이터를 원하지 않으면 b3 이다.

**(c) Browser Lane 의 자리**

| 안 | 내용 |
|---|---|
| c1 | 목록의 Browser 행에서 Enter 로 연다. Connectors 에서는 뺀다. `B`, Ctrl-^ 는 지름길로 남는다 |
| c2 | Connectors 에 둔다. 목록 행은 상태만 보이고 Enter 로 Connectors 의 Browser Lane 을 연다 |

권고: **c1**. TUI 의 Connectors 는 "transport list" 다 (`bin/masc_tui_types.ml:11693-11697`). 대화를 주고받는 통로의 목록이다. constitution 도 대화를 이어 갈 자리로 Connector, Dashboard, Slack, Discord 를 든다 (`<failure_conditions>`). Browser Lane 은 Keeper 가 도구로 쓰는 환경이다. 기계와 같은 자리가 맞다. c2 는 입구가 두 곳이 된다.

**(d) 그 밖에 찾은 것**

- **(d1) add-on 행이 놓이는 열의 이름.** 지금 `row.lane_id`, `lane.toml` 의 `lanes`·`all_lanes`, `Selected_lanes`·`All_lanes`, Timeline 의 "Lane 열" 이다. 권고: `track`(`track_id`, `tracks`, `all_tracks`). 사건 척추 RFC 가 이미 "시각 트랙(swimlane)" 이라고 불렀다 (`RFC-event-spine-and-source-contract.md:56-57`). `world.outputs` parser 는 모르는 키를 거절한다 (`lib/lane_addon/lane_addon_manifest.ml:9-21`). 그래서 옛 `lane.toml` 은 출력을 조용히 잃지 않고 설치 오류로 보인다. 이미 저장된 행에 `lane_id` 가 들어 있어서, 이름을 바꾸면 저장된 행을 버리고 새로 시작해야 한다("Fresh state required"). 파일 수: `lane_id` 를 단어로 찾으면 lib/lane_addon·TUI add-on 파일·addons·Dashboard add-on API 에서 26개, `all_lanes\|Selected_lanes\|All_lanes` 는 저장소 전체 20개, `lanes = ` 로 시작하는 줄이 있는 addons·docs 파일은 5개다. 대안은 이름을 두고 glossary 에 두 뜻을 적는 것이다.
- **(d2) `keeper_lane_status` / `masc lane status`.** Keeper 의 sandbox 실행 경로를 말한다. 권고: `keeper_sandbox_status` / `masc sandbox status`. Keeper 가 보는 이름이라 프롬프트와 Skill 도 고친다. 파일 수: lib·bin·config 11개, 저장소 전체 89개(test 36, docs 29, dashboard 8 등).
- **(d3) HITL Auto Judge 가 필수인 이유.** 코드는 필수로 둔다 (`server_runtime_bootstrap.ml:125-126`, `server_standalone_lane_projection.ml:84`). 이유를 적은 곳은 찾지 못했다. 이 RFC 는 필수로 둔다. 운영자가 이유를 확인해 주면 `purpose` 와 glossary 에 적는다.
- **(d4) exact lane `Browser Stagehand` 의 label.** 목록에는 exact 행 "Browser Stagehand" 와 Browser 행 "stagehand" 가 함께 보인다. 권고: exact 행 label 을 "Stagehand model" 로 바꾸고, 2.2 의 `serves` 로 어느 backend 를 위한 것인지 보인다.
- **(d5) `automation` 의 설정 자리.** 권고: `[browser.automation]` 로 옮긴다. Lane 하나에 표 하나가 된다. 대신 PR-4a 동안 `geckodriver`·`binary` 를 두 자리 중 한 곳에서 읽는다(2.4). 대안은 `[browser]` 에 `enabled` 를 두고 키를 옮기지 않는 것이다. 옮기는 일이 없지만, `[browser] enabled` 는 Browser 전체를 끄는 것처럼 읽힌다. `[browser.live]`·`[browser.stagehand]` 와 모양도 달라진다.

## 4. 열린 PR 과의 충돌과 순서

2026-09-27 `gh pr view` 기준이다.

| PR | 건드리는 곳 | 이 RFC 와의 관계 | 순서 |
|---|---|---|---|
| Stagehand 스택 #38736 → #38739 → #38747 → #38752 → #38760 | backend(#38736), 부팅 설치와 `server_browser_configuration`(#38739), `browser_lane.ml`·`lane_addon_sources.ml`·`tool_schemas_misc`·`tool_catalog`(#38747), 문서(#38752), TUI·executor·CI(#38760) | PR-1a 의 `lanes_of_misc_operation` 과 #38747 의 새 도구는 파일이 겹치지 않아도 서로 맞아야 한다. PR-4a 는 #38739 와 같은 parser·부팅 설치를 고친다 | PR-1 은 나란히 간다. 단, **PR-1a 와 #38747 중 나중에 병합하는 쪽은 먼저 병합된 쪽을 합친 main 위에서 CI 를 다시 돈다.** 파일이 겹치지 않으면 constitution 의 다시 돌기 규칙이 걸리지 않는데, 둘 다 초록이어도 합치면 exhaustive match 가 깨진다. **PR-4a 는 스택 뒤** |
| #39345 (Ready) | 배포 preflight 가 라이브 runtime.toml 을 새 바이너리로 검사. `runtime_exact_output_registry.ml`·`server_runtime_bootstrap.ml` 도 고친다 | PR-4b 의 배포 안전장치다. 같은 두 파일을 PR-4a·4b 가 고친다 | **#39345 먼저.** PR-4b 는 #39345 병합 뒤에만 |
| #39333 | 목록 아래 "Lane Add-ons:" 줄이 읽는 오류를 `snapshot_read_error` 로 바꾼다 | PR-2a 가 그 줄을 지운다. 필드는 add-on 화면이 계속 쓴다 | **#39333 먼저** |
| #39293 | exact lane slot 편집 이동 (`masc_tui.ml`, `masc_tui_keys.ml`, `masc_tui_render.ml`) | PR-2 가 exact 행의 Enter 에서 이 편집을 그대로 연다 | **#39293 먼저** |
| #39324 | Browser Lane 실패 원인 한 번 표시 (`masc_tui_render.ml`, `masc_tui_types.ml`) | Browser Lane 화면 안이다. 겹치는 파일만 있다 | **#39324 먼저** |
| #39236 (TUI 작업대 S1-1) | 탭 hit map | PR-2 가 탭 줄과 목록 행을 바꾼다. hit map 은 그린 프레임을 읽으므로 크게 겹치지 않는다 | **#39236 먼저** |
| TUI 작업대 RFC #39231 과 그 스택 | §4.1 `System › Lanes` 로 모음, §7 "SLOT → RUNTIME", S1-4 가 손으로 센 `lanes_overview_hit` 을 지움 (`bin/masc_tui_types.ml:9028-9045`) | 이 목록이 `System › Lanes` 의 Lane 구역이다. (a) 가 그 RFC 의 `Runtime(Lanes, …)` 이름을 바꾼다 | PR-2 는 S1-4 뒤가 낫다. S1-4 가 늦으면 PR-2 가 `lanes_overview_hit` 을 목록 행에 맞게 고치고, S1-4 가 나중에 지운다 |
| #38801 (measured home) | Lanes 를 System 아래로 옮긴다. `masc_tui.ml`·`masc_tui_render.ml`·`masc_tui_types.ml` 를 크게 바꾼다 | 화면 위치만 바뀐다 | **#38801 먼저** |
| #39365 (draft) | glossary 의 Exact-output route 항목 | PR-6 과 같은 파일이다. 이 PR 은 Lane 항목의 "다섯" (`00-glossary.md:828`, `:893`)을 고치지 않는다 | **#39365 먼저** |
| #38892 | Dashboard 에서 runtime lane 편집과 배정 | (a) 이름 변경과 충돌 | (a) 는 #38892 뒤 |
| #39385 | ocaml-msx pin | 겹치지 않는다 | 무관 |

## 5. 구현 스택

PR 하나의 출력은 20k 토큰 이하로 나눈다 (constitution `work_unit`). 로컬 Dune 빌드는 하지 않는다. 병합은 Keeper 가 한다.

| # | 범위 | 확인 |
|---|---|---|
| PR-1a | `Machine_lane.t`, `Declaration_file.t`, `Lane_id`(`[@@deriving enumerate]`, `to_wire`·`of_wire`). `masc.runtime` 에 `ppx_enumerate` 를 더하고 `Standalone_lane.all` 손 목록과 그 테스트를 지운다. `Standalone_lane.obligation` 과 거기서 만드는 `required_lane_ids`. 문자열 목록 `mandatory_exact_output_lane_ids` 를 지운다(사전 검사는 이 값을 읽도록 바꾼다). `lanes_of_misc_operation`, `Lane_addon_sources.offers` 와 `parse` 가 그것을 쓰게. `live_reader`·`Masc_tui_machine_live.source`·`activity` 의 기계 생성자를 `Machine_lane.t` 로. label·purpose 함수 | 단위: 모든 내장 id 의 wire round-trip, id 가 겹치지 않음, 모르는 wire(`exact/nope`, `machine/`, `package/a/b`)는 `None`. `required_lane_ids` 가 Board Attention·HITL 둘. `offers (Browser Stagehand) = []` 이고 stagehand 원천 binding 은 지금처럼 거절. `rg 'mandatory_exact_output_lane_ids' lib bin` 0 |
| PR-1b | `lib/server` 에 행 만들기와 `GET /api/v1/lanes`. `Server_standalone_lane_projection` 의 행 만들기를 옮기고 모듈을 지운다. 옛 route 는 새 exact 행을 옛 모양으로 적는다. `last_published`, `connected_client_count`. 상태 생성자는 이 PR 이 만드는 것만(2.5 표) | route fixture: Curator 표가 없으면 행이 `undeclared`. commit 진행 중에 읽어도 행이 이전 registry 를 보임(`unavailable` 아님). 선언 파일 둘 중 하나가 틀리면 그 행만 `rejected`. 같은 id 를 적은 파일 둘이 각각 행. 첫 reconcile 전에도 package 행이 보임. `live` client 가 끊긴 채 읽어도 client 가 정리되지 않고 기다리던 요청이 끝나지 않음. 요청 한 번에 store 에 쓴 바이트 0 |
| PR-2a | ((a) 결정 뒤) TUI 가 `/api/v1/lanes` 를 `Lanes` 화면의 load 에서 읽는다. family 묶음 목록, 머리글 숫자, candidate order 탭 글자. "Lane Add-ons:" 줄과 `installed_reading` 을 지운다 | PTY: TUI 를 처음 열고 add-on 화면을 열지 않은 채 목록에 package 행과 수가 보인다("not loaded" 회귀). 서버 503 이면 "load failed". 60열·80열 캡처 |
| PR-2b | 행 Enter 의 목적지. 기계를 받아 관전 화면을 여는 새 입구. (c) 에 따라 Browser Lane 을 Connectors 에서 옮긴다. 팔레트 "go Machines" | PTY: DOS 행 Enter → DOS 관전 화면, Browser 행 Enter → Browser Lane 화면, package 행 Enter → 그 설치를 고른 add-on 화면. `&` 는 기계 메뉴, `B`·`A` 는 지금 목적지 |
| PR-2c | live 라우트를 `/api/v1/lanes/live` 로 옮긴다. 이 라우트가 읽는 것은 package 가 아니라 기계 Lane 이다. RFC-machine-spectating §2.1(l.52-55)이 적은 "왜 Lane 경로 아래인가" 의 답이 목록으로 바뀐다 | `rg 'lane-addons/live' lib bin` 0. 라우트 테스트를 새 경로로 옮김 |
| PR-3 | Dashboard 가 `/api/v1/lanes` 를 읽는다. `dashboard-standalone-lanes.ts`, `LANE_IDS`, `standalone-lanes-parity.test.ts` 를 지운다. label 은 목록에서 온다. PR-2a 보다 늦으면 옛 route 를 지운다 | vitest. `rg 'standalone-lanes' lib bin dashboard/src` 0(옛 route 를 지우는 PR 에서). 브라우저 화면 캡처 |
| PR-4a | (Stagehand 스택과 #39345 뒤) **받아들이는 단계.** parser 가 새 표와 `enabled` 를 안다. 적혀 있으면 따르고, 없으면 지금처럼. exact slot 규칙을 `enabled = true` 에만. `Exact_lane_off`, `Lane_off`, 기계 거절, `Required_lane_disabled`. 게시된 enabled 값과 Browser 부팅 설치 결과. 크기에 따라 exact / Browser / 기계 셋으로 나눈다. 변경 조각에 "Upgrade notes" 로 운영자 단계를 적는다 | 음성: `Required` lane 이 `enabled = false` 인 파일은 부팅 거절, 같은 내용의 commit 도 거절되고 이전 registry 유지. Curator `enabled = false` 면 시작하지 않고 행이 `off`. 끈 DOS 에 `masc_dos_screen` → 설정 키를 적은 거절, 다시 켜면 기계 상태 그대로. 끈 automation → `Lane_off` 이고 `Lane_absent` 가 아님. `[browser]` 와 `[browser.automation]` 에 모두 geckodriver 가 있으면 load 오류. live 라우트 빠른 길이 잠금을 잡지 않음 |
| 운영자 | admin raw endpoint 로 2.4 의 라이브 추가분을 넣는다 | 저장 뒤 `GET /api/v1/lanes` 에서 11개 행이 모두 `undeclared` 가 아님 |
| PR-4b | **요구하는 단계.** 표나 `enabled` 가 없으면 load 오류. `Undeclared`, `Exact_lane_unconfigured`, 부팅 사전 검사 `mandatory_exact_output_lane_violations`, 손 경고 세 줄, `[browser] geckodriver/binary` 자리를 지운다. seed 가 11개 표를 모두 적는다 | 음성: 표 하나를 뺀 파일 → 그 표 이름을 적은 load 오류. `enabled` 를 뺀 표 → 그 키를 적은 load 오류. #39345 preflight 가 운영자 단계를 빠뜨린 라이브 파일에서 이전 서버를 멈추기 전에 배포를 거절(`test/test_deploy_preflight.sh` 에 경우 추가) |
| PR-5a | 선언 파일의 `enabled` 를 받아들인다. `false` 면 reconcile 이 worker 를 떼고 선언은 남긴다. `Lane_addon_config.problem` | 음성: `false` → container 제거 확인(지금 detach 증명), 행은 남음. 다시 `true` → 붙음. 새 선언이 거절돼도 이전 worker 가 돌면 행이 `rejected` 이면서 `observing` |
| 운영자 | 선언 저장 API 로 라이브 선언 둘에 `enabled = true` | 저장 뒤 두 행이 `accepted` |
| PR-5b | 선언에 `enabled` 가 없으면 그 파일의 load 오류 | 음성: `enabled` 없는 선언 → 그 행만 `rejected`, 다른 설치는 그대로 |
| PR-6 | 2.8 의 문서 고침. glossary Lane·Standalone Lane·Lane Add-on·MSX·DOS·Browser 항목과 경계 문단. `addons/README.md` 가 패키지 8개를 모두 적음(지금 6개, `addons/README.md:10-17`). 원천 종류 목록을 코드의 다섯 개와 맞춤 | 2.8 표의 옛 문장이 남지 않음 |
| PR-7 | (b) 결정 | b4: id 를 바꾼 패키지가 CI 이미지·합성 예제·테스트를 통과. b3: `rg dos-world` 0 |
| PR-8 이후 | (a), (d1), (d2), (d4) 이름 변경. 하나씩 따로. 설정 키를 바꾸는 것은 2.4 와 같은 두 단계 | 각 PR 에서 옛 이름 `rg` 0 |

## 6. 하지 않는 것과 트레이드오프

- **Dynlink 나 컴파일된 코드의 hot loading 은 없다.** 내장 Lane 을 더하는 일은 생성자를 더하고 다시 빌드하는 일이다. 떼었다 붙이는 것은 설정의 `enabled` 이다. 코드를 빼는 것이 아니다.
- **기계는 서버 프로세스 안에 남는다.** live 라우트의 잠금 없는 "그대로" 답(RFC-machine-spectating l.36-43)과 DOS 실행 한 번의 잠금 약 170ms(l.19-20)는 그대로다. live 라우트에 더해지는 것은 게시된 enabled 값을 읽는 `Atomic.get` 하나다.
- **타입 도구는 그대로다.** `masc_lane_act` 로 옮기지 않는다. `masc_lane_*` 는 package 설치에만 쓴다.
- **새 거절은 "꺼진 Lane" 한 종류다.** 운영자 결정이 근거다(2.3). 필수 Lane 검사는 지금 registry 의 검사 하나가 계속 맡는다.
- **목록은 켜고 끄지 않는다.** 각 주인이 지금 결정하는 자리에서 설정을 읽는다. 새 scheduler 는 없다.
- **꺼도 기계 메모리를 비우지 않는다.** 올린 프로그램을 내리지 않는다.
- **spawned Browser backend 켜기는 다음 부팅부터다.** executor 설치가 부팅 때 한 번이기 때문이다. 그 사이 행은 `Waiting_for_restart` 다.
- **Keeper 가 목록을 읽는 도구는 더하지 않는다.** Keeper 는 꺼진 Lane 을 typed 거절로 안다.
- 트레이드오프: 표와 `enabled` 를 필수로 두면 모든 선언을 한 번씩 고쳐야 하고, 배포가 두 단계가 된다(2.4). 기본값을 두면 이 일이 없지만, 파일만 보고 켜짐인지 알 수 없고 Curator 같은 조용한 꺼짐이 다시 생긴다.
- 트레이드오프: PR-4a 동안에는 "없으면 지금처럼" 가지와 `geckodriver` 두 자리 읽기가 있다. 떠 있는 서버로 라이브 파일을 고칠 길을 남기기 위해서다. PR-4b 가 지운다.
- 트레이드오프: TUI 단계(PR-2)는 TUI 작업대 스택과 같은 파일을 고친다. 순서를 지키면 한 번씩만 rebase 한다.

## 7. 고르지 않은 안

**모두 프로세스 밖 (모든 Lane 을 container 로, 타입 도구를 `masc_lane_act` 로)**

- 장점: 설치·적용·제거와 phase 를 가진 주기는 이미 add-on 에 있다 (`lib/lane_addon/lane_addon_runtime.mli:31-48`). 코드를 실제로 떼어 낼 수 있다. `dos-world` 가 작은 경우에 이 길이 돈다는 것을 보였다.
- 단점:
  - 사람과 Keeper 의 모든 기계 입력이 MCP 왕복과 container 한도를 거친다.
  - live 라우트의 잠금 없는 답은 같은 프로세스의 `Atomic` 게시에 기대고 있다.
  - MSX 관측 하나가 약 147KB 를 남긴다 (RFC-machine-spectating l.84). container 경계를 넘으면 매번 복사한다.
  - Keeper 계약이 바뀐다. 타입 도구를 이름으로 부르는 Skill 이 7개다 (`dos-play`, `msx-play`, `msx-observe`, `sangokushi-2`, `sangokushi-2-end-command`, `sangokushi-3`, `sangokushi-3-end-month`).
  - exact lane 은 AGENT_CORE exact-output 흐름과 영속 registry(Board attention 후보 등)를 가진다. container 로 옮기면 영속 상태의 주인이 바뀐다.
  - 운영자가 고르지 않았다.

**화면과 상태만 (TUI 에서 지금 목록들을 묶어 보이기만)**

- 장점: 작다. 설정이 바뀌지 않는다.
- 단점:
  - id 타입 네 벌과 기계 합타입 세 벌, 손 목록, Curator 의 조용한 꺼짐, lane 마다 다른 "표 없음" 의 뜻이 그대로다.
  - 목록을 여러 endpoint 에서 모아야 한다. 머리글 숫자가 여전히 family 마다 다른 곳에서 온다.
  - 다음 기계도 파일 29개와 조용한 자리를 그대로 지난다.

## 8. 확인하지 못한 것

- 라이브 서버의 `/api/v1/dashboard/standalone-lanes`·`/api/v1/lane-addons` 실제 응답. 운영자 토큰이 필요해서 읽지 않았다. 1.4 의 라이브 서술은 라이브 설정 파일과 코드에서 나왔다.
- 도는 서버 바이너리가 `origin/main` 과 같은지.
- Keeper TOML 이나 composition 이 `masc_msx_*`·`masc_dos_*`·`masc_browser_*` 를 Keeper 별로 막는지.
- HITL Auto Judge 가 필수인 이유 (3장 d3).
- `tool_catalog`·`keeper_tool_descriptor` 의 문자열을 도구 목록과 맞춰 보는 테스트가 있는지 (1.2).
- 서버가 요청을 받기 시작한 뒤 exact registry 가 게시되기 전의 창이 있는지 (2.5).
- 2.4 의 2026-09-27 16:16Z 사고 시각과 Keeper 수는 리드 보고다. #39373 이 열려 있는 것만 확인했다.
