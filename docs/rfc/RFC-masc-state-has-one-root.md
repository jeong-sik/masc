---
rfc: "masc-state-has-one-root"
title: "masc 상태는 root 하나 아래에만 둔다"
status: Implemented
created: 2026-10-14
updated: 2026-10-14
author: claude
supersedes: []
superseded_by: null
related: ["dated-stores-take-retention-from-one-list"]
---

# RFC: masc 상태는 root 하나 아래에만 둔다

- 상태: 구현됨. 스택 #43087(맨 위 PR #43086)로 2026-10-14 에 main 에 들어갔다. 구현과 이 문서의 차이는 §11 에 적었다.
- 이슈: #42837. 운영자가 2026-10-13 에 보존 규칙 RFC §9 Q6 에서 "기본이 아닌 클러스터는 쓰지 않는다. root 를 하나로"라고 답했다.
- 근거: §2 의 코드 사실은 `origin/main` `5d142b8fb2` 에서 읽었다. 조사 에이전트가 쓰임새를 모았고, 글쓴이가 핵심 주장 셋(환경 변수를 읽는 곳, 대시보드 연결 표시, 라이브 폴더)을 다시 확인했다. 라이브는 2026-10-14 에 폴더 이름과 환경 변수 이름만 봤다.
- 앞선 문서: RFC "날짜별 store 는 보존 규칙을 한 목록에서 받는다". 그 RFC 가 만든 store 목록이 두 root 를 타입으로 나눠 적었다(`Dated_jsonl.Store` 의 `Base` 와 `Cluster`).

## 0. 요약

masc 는 상태를 `<base>/.masc` 아래에 둔다. 그런데 `MASC_CLUSTER_NAME` 을 주면 상태의 일부가 `<base>/.masc/clusters/<이름>` 으로 간다. 그래서 코드에는 root 가 둘이다.

- base root: `<base>/.masc`. `Common.masc_dir_from_base_path` 등이 만든다.
- cluster root: `Workspace.masc_dir config`. 기본 클러스터에서는 base root 와 같은 폴더다.

클러스터 이름이 하는 일은 둘뿐이다. 폴더를 고르고, 화면과 JSON 에 라벨로 나온다. 여러 서버를 묶거나 서로 부르는 코드는 없다(§2.2).

같은 기록을 두 root 로 나눠 다루는 자리가 적어도 일곱 곳 있다(§2.3). 한 store 를 어떤 곳은 cluster root 에, 다른 곳은 base root 에 쓰거나 읽는다. 기본 클러스터에서는 같은 폴더라 드러나지 않고, 이름을 주면 기록이 두 폴더로 갈린다. 라이브에는 `clusters` 폴더가 없고 환경 변수도 설정돼 있지 않다.

이 RFC 는 클러스터를 지우고 root 를 `<base>/.masc` 하나로 둔다. 그러면 이런 갈림이 한 번에 없어지고, store 목록의 `Base`/`Cluster` 나눔과 `cluster_root` 타입도 필요 없다.

## 1. 결정

- D1. 클러스터 이름을 지운다. `MASC_CLUSTER_NAME` 을 읽는 코드, `Backend_types.config.cluster_name`, 설정 목록의 그 줄이 사라진다.
- D2. root 는 `<base>/.masc` 하나다. `Workspace.masc_dir config` 와 base root 를 만드는 함수들은 같은 폴더를 돌려준다. `<base>/.masc/clusters` 는 어떤 코드도 만들거나 읽지 않는다.
- D3. `Dated_jsonl.Store` 의 `Base`/`Cluster` 나눔과 `cluster_root` 타입을 지운다. 모든 store 는 base path 에서 자리를 얻는다.
- D4. 클러스터 이름을 보여 주던 라벨과 JSON `cluster` 칸을 지운다(§3.4, §9 Q1).
- D5. tool blob 정리가 `.masc/clusters/*` 를 함께 훑던 코드와 그 보고 칸을 지운다.
- D6. 이름 붙인 클러스터를 다루는 테스트를 지운다. 같은 동작을 기본 root 에서 보는 테스트가 따로 없으면, 그 동작은 기본 root 로 옮겨 남긴다.
- D7. 데이터는 옮기지 않는다. 코드가 `clusters` 폴더를 더는 읽지 않는 hard cut 이다. 읽기 호환 코드와 변환 코드를 만들지 않는다.

## 2. 지금 구조

### 2.1 이름이 오는 곳

- production 코드에서 환경 변수를 읽는 곳은 하나다: `lib/config/env_config_core.ml:319-328` 의 `cluster_name_opt` 와 `cluster_name`. 값이 없거나 공백이면 `"default"` 다. 테스트 도우미 하나(`test/keeper_github_identity/workspace.ml:39`)도 직접 읽는다.
- 설정 파일 키와 CLI 플래그는 없다. 설정 목록(`env_config_snapshot.ml:37`)에 "Cluster name for multi-instance" 줄이 있고, 기본값을 `""` 로 보여 준다.
- `Workspace_utils_backend_setup.backend_config_for`(`:334-352`)가 이 값으로 backend root 를 `<base>/.masc` 나 `<base>/.masc/clusters/<seg>` 로 정하고, `Backend_types.config.cluster_name` 에 넣는다. `"" | "default"` 는 폴더를 붙이지 않는다.
- `Workspace_utils_paths_backend.masc_root_dir_from ~base_path ~cluster_name`(`:9-15`)이 같은 규칙으로 cluster root 를 만든다. `masc_dir config` 는 `masc_root_dir config` 와 같다.
- `Env_config_core.cluster_name ()` 호출은 16개 파일에 17번 있다. 8번은 경로를 만들고 9번은 JSON 라벨을 채운다. `cluster_name_opt ()` 를 부르는 곳이 하나 더 있다(`bin/masc_tui.ml:553`, TUI 머리 라벨). config 에 담긴 `Backend_types.cluster_name` 칸을 읽는 곳도 6곳이다(`server_bootstrap_maintenance.ml:656, :668`, `tool_workspace.ml:25`, `workspace_status.ml:25`, `workspace_utils_paths_backend.ml:20, :290`).
- Keeper 컨테이너에는 이 값을 넘기지 않는다(`keeper_sandbox_runtime_setup.ml:462-464`, 넘기는 환경 변수 목록 `:319-349` 과 `env_keeper_scrub.ml:30-41` 에 없다). 컨테이너 안은 늘 기본 클러스터다. 다만 호스트 쪽은 이름으로 마운트할 폴더를 고른다(`:454-468`).

### 2.2 이름이 하는 일

| 하는 일 | 자리 | 예 |
|---|---|---|
| 폴더 고르기 | cluster root 를 쓰는 store 와 상태 | board, voice_config, keepers, sessions, tool_calls, tool_usage, root-state.json, `Dated_jsonl.Store.Cluster` 목록, onboarding 의 keepers 검사(`onboarding_status.ml:140-142`), 환경 변수로 root 를 고르는 `keepers_runtime_dir_for_base_path`(`keeper_durable_store`, `keeper_github_identity`, CLI 둘) |
| 라벨 | JSON 의 `"cluster"` 칸 | `/api/v1/status`(h1, h2), 대시보드 shell status 와 projection diagnostics, execution workspace status 와 그 fixture, operator snapshot, operator digest, briefing `summary.cluster` |
| 라벨 | 글자 | `masc_status` 와 MCP `status` resource 의 "Cluster:" 줄, TUI 머리 라벨의 기본값, MCP `initialize` 안내문(`config/prompts/mcp.md:10-11`), `masc_status` 도구 설명 |
| 그 밖 | 열쇠와 검사 | 대시보드 캐시 칸막이(경로가 열쇠), `is_initialized` 캐시 열쇠(이름이 열쇠), 요청의 `expected_workspace.masc_root` 검사, 설정 바꾸기 때 root 비교, TUI 가 이름으로 로컬 root 를 만들어 서버와 맞춰 보는 검사(`bin/masc_tui_types.ml:172-185`) |
| 여러 서버 묶기 | 없음 | "multi-instance", "multi-machine" 이라는 문구만 있다 |

경로를 담아 밖으로 나가는 칸(`effective_masc_root`, `expected_workspace.masc_root`, Memory receipt 의 `receipt_scope` 등)은 이름이 아니라 경로를 담는다. 기본 클러스터에서는 이미 `<base>/.masc…` 이므로 D2 뒤에도 값이 같다.

### 2.3 지금 두 root 가 갈리는 자리

찾은 것만 적었다. 전부를 센 목록은 아니다. lib/bin 에는 base root 를 만드는 식이 100곳쯤, cluster root 를 만드는 식이 100곳쯤 있다. 기본 클러스터에서는 같은 폴더라 문제가 드러나지 않는다.

| 무엇 | 한쪽 | 다른 쪽 |
|---|---|---|
| 비용 장부 | 응답마다 쓰는 줄은 cluster root(`keeper_hooks_agent_core.ml` 의 `acc.masc_root`) | 정산 줄과 읽는 쪽은 base root(`keeper_unified_turn_success.ml`, `bin/masc_cost.ml`, `model_inference_metrics_reader.ml`). 실행 전 정산(`keeper_agent_run.ml:1196-1197` 의 `Keeper_unsettled_spend`)도 base root 에서 읽어서, 이름을 주면 응답마다 쓴 줄이 정산되지 않는다 |
| wire capture | 세 곳은 cluster root | `keeper_turn_driver_try_provider.ml` 의 `capture_rejected_reasoning` 은 base root |
| 멈춘 일 처리 영수증 | 쓰기는 cluster root(`keeper_paused_work_disposition_receipt.ml`) | 있는지 보기는 base root(`keeper_reaction_ledger.ml`) |
| lifecycle hook 의 coverage gap | `keeper_supervisor_cleanup.ml` 은 cluster root | `keeper_registry.ml` 은 base root |
| 디스크 압박 | `server_routes_http_runtime.ml` 은 cluster root | `server_routes_http_runtime_health_fleet.ml` 은 base root |
| Keeper 출력 폴더 | `Workspace.keepers_runtime_dir`(cluster root) | 8개 파일 11곳이 `Common.keepers_runtime_dir_of_base`(base root) |
| store 목록 | `Dated_jsonl.Store.Base`, `Reaction_ledger`, `Decision_audit` 는 base root | `Dated_jsonl.Store.Cluster`/`Keeper` 는 cluster root. 그래서 이름을 주면 한 Keeper 의 `keepers/<k>/` 가 두 root 로 나뉜다 |

이 갈림을 자리마다 맞추는 것은 같은 수정을 여러 번 하는 일이고, 목록이 다 찾았다는 보장도 없다. root 를 하나로 두면 한 번에 사라진다.

`.masc` 밖에 쓰던 자리(#42837 의 `Keeper_callback_failure.record`)는 이 RFC 와 따로 #42954 로 고쳤다(2026-10-13 병합).

### 2.4 테스트

이름 붙인 클러스터나 `cluster_name` 을 다루는 테스트 파일이 23개다. 지우는 것은 대개 파일이 아니라 그 안의 테스트 몇 개다.

- 클러스터 경로가 맞는지 보는 테스트: `test_workspace_utils_coverage`, `test_dated_jsonl_store`, `test_server_runtime_bootstrap`, `test_keeper_sandbox_read_backend`, `test_keeper_chat_store`, `test_keeper_github_identity`, `test_tui_server_identity_refresh`, `test_dashboard_http_core`, `test_telemetry_unified`, `test_deployment_store_directories`, CLI 테스트 둘(`test_keeper_checkpoint_purge`, `test_librarian_replay_cli`). 기능이 없어지면 함께 지운다.
- 클러스터 둘을 "서로 다른 root" 로 쓰는 테스트: `test_keeper_librarian_durable_consumer`, `test_keeper_librarian_store_scope`, `test_tool_blob_store`. 이 가운데 root 가 다르면 서로 섞이지 않는다는 것을 보는 경우는, base path 를 둘 쓰는 테스트로 바꿀 수 있는지 구현 때 본다. `test_keeper_portrait_http` 와 `test_tui_keeper_control` 은 `clusters/...` 모양의 경로를 "다른 root" 의 예로만 쓴다.
- `cluster_name` 칸을 레코드에 적기만 하는 테스트: `test_backend`, `test_backend_coverage`, `test_distributed_lock_backlog_namespace`, `test_workspace`. D1 뒤에는 컴파일되지 않으므로 그 칸만 지운다.
- 그 밖: 테스트 도우미 `test/keeper_github_identity/workspace.ml`, `test/test_deployment_queue_preflight_mutation.py` 가 환경 변수를 다룬다. `test_dashboard_namespace_truth.ml:256` 은 JSON `cluster` 칸을 확인하므로 §9 Q1 을 따른다.

### 2.5 문서

- `docs/spec/00-glossary.md` 의 Cluster 항목과, 상태를 "선택한 클러스터" 아래에 둔다고 적은 항목들.
- `config/prompts/mcp.md` 의 안내문, `config/tools/masc_status.toml` 의 설명, `bin/masc_checkpoint_purge.ml` 과 `bin/masc_librarian_replay.ml` 의 도움말.
- `docs/rfc/RFC-durable-tool-result-markers.md:111` 은 blob 정리가 `clusters` 가 비어 있지 않으면 멈춘다고 적었다. 지금 코드와도 맞지 않는다.

## 3. 설계

### 3.1 이름 (D1)

`Env_config_core.cluster_name_opt`, `cluster_name`, 설정 목록 줄, `Backend_types.config.cluster_name` 과 `Backend_types.default_config` 의 그 칸을 지운다. 이름을 받던 함수(`masc_root_dir_from ~cluster_name`, `Keeper_tool_call_log.init ?cluster_name`, `Tool_usage_log.init ?cluster_name`, `Workspace_status_rendering ~effective_cluster_name`)는 그 인자를 잃는다. `Tool_workspace.effective_cluster_name` 은 지운다.

`MASC_CLUSTER_NAME` 이 환경에 남아 있어도 아무 코드도 읽지 않는다. 라이브에는 설정돼 있지 않다(2026-10-14, 셸 환경과 `~/.zshenv` 에서 이름으로 확인).

### 3.2 root (D2)

`Workspace.masc_dir config` 는 `<base>/.masc` 를 돌려준다. `masc_root_dir`, `masc_root_dir_from`, `masc_dir_from_base_path` 가 셋 남을 까닭이 없으므로 하나로 줄인다. `keepers_runtime_dir_for_base_path` 는 환경 변수로 root 를 고르지 않고 base root 의 keepers 폴더를 돌려준다. `dated_store_cluster_root`(호출 20곳쯤)는 D3 에서 지운다.

`Common.clusters_dir_from_base_path` 를 지운다. `sanitize_namespace_segment` 는 Keeper 쪽 여러 곳이 쓰므로 남기고, 클러스터 이름에 쓰던 자리만 지운다.

Memory backend(`backend_setup.ml:354-355`)는 이름이 아니라 backend root 경로를 열쇠로 쓴다. D2 뒤에는 그 경로가 늘 `<base>/.masc` 이므로 고칠 것이 없다. 이름을 열쇠로 쓰는 캐시는 `is_initialized` 의 `init_cache_key`(`workspace_utils_paths_backend.ml:289-290`)이고, 열쇠에서 이름을 뺀다.

### 3.3 store 목록 (D3)

`Dated_jsonl.Store` 는 지금 `Base`, `Cluster`, `Keeper` 세 묶음, Keeper 마다 있는 `Reaction_ledger` 와 `Decision_audit`, 그리고 `cluster_root` 타입을 갖는다. 묶음을 나눈 까닭이 root 가 둘이라서였으므로, 묶음은 폴더 모양(한 폴더, Keeper 마다 한 폴더)만 나타내게 줄인다. `cluster_root` 를 받던 함수는 `~base_path` 를 받는다. 정리(`prune_listed_stores`)도 `~base_path` 만 받는다.

### 3.4 라벨 (D4)

- JSON `"cluster"` 칸을 지운다(§9 Q1). 대시보드는 그 칸 없이 연결을 판단한다.
- `masc_status` 와 MCP `status` resource 의 "Cluster:" 줄을 지운다. "Project:" 줄은 늘 보인다.
- MCP `initialize` 안내문과 `masc_status` 도구 설명에서 클러스터 문구를 지운다. MCP 클라이언트가 받는 글자가 바뀐다.
- TUI 머리 라벨은 `--workspace` 가 없으면 base path 의 마지막 이름을 쓴다. 지금 환경 변수가 없을 때와 같다.

### 3.5 blob 정리 (D5)

`tool_blob_maintenance.ml` 이 `.masc/clusters/*` 를 함께 훑는 코드, `Cluster_workspace_rejected` 오류, `skipped_cluster_files` 보고 칸을 지운다. `bin/deployment_preflight_helper.ml` 에서는 그 칸을 찍는 줄(`:436-450`)만 지운다.

## 4. 데이터

- 라이브 base path 에 `.masc/clusters` 가 없다(2026-10-14). 옮길 것이 없다.
- 이름 붙인 클러스터를 썼던 장비가 있다면 그 폴더는 아무 코드도 읽지 않는 채 남는다. 운영자 답(Q6)에 따라 그런 장비는 없다.
- 경로를 담아 저장된 칸(Memory receipt 의 `receipt_scope`, TUI 대기 파일의 `masc_root`)은 기본 클러스터에서 이미 `<base>/.masc…` 이다. 값이 바뀌지 않는다.

## 5. 다른 방법과 버린 까닭

- 이름은 남기고 늘 `"default"` 만 쓴다: 읽히지 않는 개념이 코드와 문서에 남는다. 다음 사람이 "클러스터를 쓰면 되겠다"고 읽는다.
- `MASC_CLUSTER_NAME` 이 있으면 서버 시작을 거부한다: 지운 개념을 검사하는 코드가 남는다. 라이브에 그 값이 없으므로 얻는 것이 없다.
- 갈림을 자리마다 맞춘다(§2.3): root 가 둘인 채로 같은 수정을 자리마다 한다. 찾지 못한 자리와 새 자리가 다시 생길 수 있다.

## 6. 하지 않는 것

- root 를 문자열로 넘기는 인자(`~masc_root`)를 타입으로 바꾸는 일: §9 Q2 에 따라 #43005 에서 따로 한다.
- base path 자체를 정하는 일(`.gate/runtime`, `.masc-ide` 가 `.masc` 밖에 있는 #42809 등)은 따로 한다.
- 다른 뜻의 "cluster"(글자 묶음, 도구 묶음, 실패 이유 묶음)는 건드리지 않는다.

## 7. 검증

- 빌드: `@check` 와 `lib/masc.cmxa`.
- 테스트: 지우지 않는 스위트 가운데 이 스택이 고친 파일의 스위트를 맨 위에서 모두 돌린다.
- 남은 이름 검사: `lib`, `bin`, `test`, `config`, `docs/spec` 에서 `MASC_CLUSTER_NAME`, `cluster_name`, `clusters_dir`, `cluster_root`, `"clusters"` 가 나오지 않는다(다른 뜻의 cluster 는 빼고 센다).
- 라이브: 배포 뒤 `/health` 의 `effective_masc_root` 가 `<base>/.masc` 이고, 서버가 `.masc/clusters` 를 만들지 않는다.

## 8. 확신도

- 높다: production 코드에서 환경 변수를 읽는 곳이 하나라는 것, 라이브에 `clusters` 폴더와 환경 변수가 없다는 것, 대시보드 연결 표시가 `cluster` 칸을 쓴다는 것. 글쓴이가 다시 확인했다.
- 높다: §2~§3 의 코드 사실. 조사 에이전트가 모으고, 이 글을 쓰지 않은 다른 에이전트가 `origin/main` 에 대어 따로 대조했다. 거기서 틀린 곳(호출 수 둘, 줄 번호 둘, Memory backend 의 열쇠)과 빠진 곳(대시보드 소비처, 테스트 파일 일곱 개, 정산 쪽 읽기, Keeper 폴더가 두 root 로 나뉘는 것)을 고쳤다.
- 중간: §2.3 이 갈림을 다 찾았는지. 찾은 것만 적었다. 구현 때 컴파일러가 빠진 자리를 알려 준다(D1 이 필드와 함수를 지우므로).
- 모른다: 자식 프로세스가 `MASC_CLUSTER_NAME` 을 부모 환경에서 물려받아 따로 읽는 곳이 있는지. masc 코드 안에서는 읽는 곳이 하나뿐이다.

## 9. 운영자가 정한 것

2026-10-14 에 운영자가 답했다.

- Q1. JSON `cluster` 칸을 모든 응답에서 지운다. 대시보드 연결 표시(`dashboard/src/components/ide/ide-presence-strip.ts:43-53`)는 status 응답을 받았는지로 연결을 판단하고, `runtime_id` 에는 `project` 를 쓴다.
  - 같이 고칠 소비처: `keeper-detail-runtime.ts:1438-1448` 은 값이 `default`/`unknown`/`N/A` 가 아닐 때만 "클러스터" 줄을 보인다. `mission-normalizers.ts:62`, `operator-normalizers.ts:46` 과 타입 파일 둘(`types/dashboard-execution.ts:752`, `types/dashboard-mission.ts:14, :214`)은 이 칸을 선택 칸으로 다룬다. 테스트 `test_dashboard_namespace_truth.ml:256` 이 이 칸을 확인한다.
- Q2. 이 스택은 root 값만 하나로 맞춘다. `~masc_root` 는 문자열로 둔다. root 가 하나가 되면 그 자리에 잘못 들어갈 수 있는 값은 base path 하나로 준다. root 를 타입으로 바꾸는 일(lib/bin 160곳쯤, 테스트 300곳쯤)은 이 RFC 밖에서 따로 한다(#43005).

## 10. 구현 순서

Native Stack 하나로 올린다.

1. 이름과 root(D1, D2). `Workspace.masc_dir` 가 늘 `<base>/.masc` 를 돌려준다. 이름 붙인 클러스터의 경로 테스트를 지운다.
2. store 목록(D3). `Base`/`Cluster` 나눔과 `cluster_root` 를 지우고 호출처를 `~base_path` 로 바꾼다.
3. 갈림 자리(§2.3)에서 root 를 두 번 만들던 코드를 하나로 줄인다. 2 뒤에는 값이 같으므로 동작이 바뀌지 않는다.
4. 라벨과 대시보드(D4, §9 Q1).
5. blob 정리(D5).
6. 문서, 안내문, 도움말.

## 11. 구현 결과

스택 #43087 의 여섯 층(PR #43017~#43086)이 2026-10-14 에 한 번에 main 에 들어갔다.

| PR | 한 일 | §10 의 단계 |
|---|---|---|
| #43017 | 클러스터 이름과 root(D1, D2), JSON `cluster` 칸과 대시보드(D4), blob 정리(D5) | 1, 4, 5 |
| #43022 | `Dated_jsonl.Store` 의 `Base`/`Cluster` 를 `Root` 하나로 합쳤다(D3) | 2 |
| #43031 | 같은 값을 돌려주는 root 함수를 하나씩만 남겼다(§3.2 의 셋 줄이기) | 3 의 일부 |
| #43047 | `~base_path` 와 `~masc_root` 를 함께 받던 함수가 하나만 받는다 | 3 |
| #43074 | workspace 상태 파일과 만드는 길을 하나로 줄였다 | §2.3 밖 |
| #43086 | 안내문, 도움말, 용어집 | 6 |

이 문서와 다른 곳은 셋이다.

- §3.3 은 store 함수가 `~base_path` 를 받는다고 적었다. 구현은 `Dated_jsonl.Store.root` 를 받는다. `root_of_base_path` 나 `root_of_masc_dir` 로 만든다. `masc_root` 문자열만 들고 있는 호출처가 많아서다. §9 Q2 대로 이 값은 아직 타입으로 묶지 않았다(#43005).
- §10 의 순서와 층이 다르다. 1, 4, 5 단계를 맨 아래 층 하나에 넣었고, 3 단계를 함수 이름 정리(#43031)와 입력 하나로 줄이기(#43047) 둘로 나눴다. 스택이 한 번에 들어갔으므로 main 에서 보이는 결과는 같다.
- §2.3 목록 밖에서 같은 "root 가 둘" 구조를 하나 더 찾아 #43074 에서 고쳤다. 운영자가 2026-10-14 에 넣기로 했다.
  - workspace 상태를 `.masc/root-state.json` 과 `.masc/state.json` 두 벌 적었고, workspace 를 만드는 길이 `Workspace.init` 과 `ensure_workspace_bootstrap` 둘이었다. 뒤의 것은 production 에서 아무도 부르지 않았다. 이제 `state.json` 과 `init` 하나뿐이다.
  - 그러면서 찾은 버그 셋을 함께 고쳤다. 2026-08-25 사고 뒤에 넣은 메시지 번호 되살리기(`reconcile_message_seq`)가 부르지 않는 쪽에만 있어서 라이브에서 돈 적이 없었다. `init` 은 번호를 0 부터 시작하는 자기 사본으로 상태를 만들었다. `read_state` 는 `state.json` 이 없으면 그것을 만들어, 읽기만으로 workspace 가 초기화된 것처럼 보였다.

§7 검증 가운데 라이브 확인(배포 뒤 `effective_masc_root` 가 `<base>/.masc` 인지)은 배포 뒤에 한다. 배포 뒤 라이브의 `.masc/root-state.json` 은 아무도 읽지 않으므로 지운다.

이 RFC 밖에 남은 일:

- #43005: `~masc_root` 를 타입으로 묶는다. wire 에 base path 와 masc root 를 둘 다 싣는 세 곳(`validate_expected_workspace`, msx checkpoint 영수증, path diagnostics)도 여기서 다룬다.
- #43125: `reconcile_message_seq` 가 `next_seq` 와 같은 상태 잠금 안에서 돈다(리뷰 P3).
