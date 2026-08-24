---
rfc: "keeper-external-tools-and-produced-artifacts"
title: "keeper 의 바깥 — 접근은 이미 열려 있고, 없는 것은 도구 정의와 증거다"
status: Draft
created: 2026-08-25
updated: 2026-08-25
author: claude
supersedes: []
superseded_by: null
related: ["skills-as-tools", "prompts-and-tool-definitions-outside-ocaml"]
implementation_prs: []
---

# RFC: keeper 의 바깥 (keeper-external-tools-and-produced-artifacts)

## 0. Summary

"keeper 가 바깥 도구를 못 쓴다"는 말은 두 개의 서로 다른 문제를 하나로 뭉친 것이다.
측정해 보면 **접근은 이미 열려 있다.** keeper 는 `Execute` 로 `gh` 를 170번 불렀고,
어제 playwright 로 대시보드를 직접 캡처해 174 KB 짜리 png 를 만들었다. 샌드박스는
네트워크를 막지 않는다.

없는 것은 둘이다.

1. **도구 정의** — CLI 가 없는 대상(JIRA)은 keeper 가 무엇을 부를지 알 방법이 없다.
   playwright 는 `playwright --version` 이 그 지식을 대신해 줬고, JIRA 는 대신해 줄
   것이 없다. keeper 는 매번 REST 스키마를 추측하게 된다.
2. **산출물 증거** — keeper 가 만든 png 는 `playground/kidsnote/` 에 굴러다니고
   ledger 에 남지 않는다. `analyze_image` 도구가 있지만 입력으로 받는 handle 을
   만들 방법이 없어 368턴 넘게 한 번도 호출되지 않았다.

이 RFC 는 둘을 각각 다룬다. 새 MCP 클라이언트 층을 "붙이면 다 된다"는 접근은 기각한다 —
접근은 이미 있고, 문제는 계약이다.

## 1. 관측

수치는 전부 다시 잴 수 있다. 2026-08-25 측정.

### 1.1 접근은 열려 있다

```bash
# keeper Execute 의 argv[0] 분포 (keeper 별 최근 25 turn trace)
python3 - <<'PY'
import glob, json, collections, os
c = collections.Counter()
for kd in glob.glob(os.path.expanduser("~/me/.masc/keepers/*/raw-traces")):
    for f in sorted(glob.glob(kd + "/*.jsonl"))[-25:]:
        for line in open(f, "rb").read().decode("utf-8", "replace").splitlines():
            try: o = json.loads(line)
            except Exception: continue
            st = [o]
            while st:
                x = st.pop()
                if isinstance(x, dict):
                    v = x.get("argv")
                    if isinstance(v, list) and v and isinstance(v[0], str): c[v[0]] += 1
                    st.extend(x.values())
                elif isinstance(x, list): st.extend(x)
print(c.most_common(12))
PY
```

```
git 403 · gh 170 · ls 62 · sleep 34 · dune 28 · grep 27 · opam 26 · bash 18
```

`gh` 170회는 GitHub API 호출이다. **네트워크는 나간다.** `Execute` 설명이
"never interprets program or subcommand meaning" 이라 masc 는 안에서 무엇이
나가는지 모른다.

### 1.2 keeper 는 이미 브라우저를 몰았다

`~/me/.masc/playground/kidsnote/capture_lanes_v2.py` (113줄, 2026-08-24 20:05:38).
vite dev server 를 띄우고 시스템 Chrome 을 playwright 로 몰아 대시보드 Tools 탭을
캡처한다. 산출물 `task-481-lanes-v2-capture.png` (174 KB, 1440x1200, 20:07:15).

같은 turn trace 에서 인터프리터를 세 번 바꾼 기록이 보인다 — pipx venv 두 경로가
깨져 있었고(`~/.local/pipx/venvs/playwright/bin/python3.13` → homebrew python@3.13
부재) `/opt/homebrew/bin/python3` 로 갈아타 성공했다.

### 1.3 도구 표면

```bash
rg -o "tools=\d+ tool_surface_bytes=\d+" ~/me/.masc/logs/*.log | tail -1
# tools=96 tool_surface_bytes=62685
```

상한은 `test/test_keeper_tool_schema_bytes.ml:44` 의 85,000 B. 여유 약 22 KB.

96개가 선언되지만 sangsu 최근 40턴에서 실제 호출된 것은 12종이다.

```
Execute 264 · Read 76 · masc_task_history 32 · keeper_tasks_list 18
keeper_task_done 12 · Write 10 · keeper_voice_speak 6 · Grep 6
keeper_voice_agent 4 · keeper_context_status 4 · keeper_task_claim 2 · masc_deliver 2
```

### 1.4 밖으로 나가는 계약은 이미 있다

`lib/keeper/keeper_tool_in_process_runtime.mli`:

- 읽기: `network_read_gate_operation` — `Replay_web_search | Replay_web_fetch`
- 쓰기: `connector_post_gate_operation` — `Replay_discord_post | Replay_slack_post`

계약 3항(`connector_post_replay_of_gate_input` 주석): 요청 **정확 보존**(재구성 금지),
**one-shot** 소비, **replay** 가능.

Slack 은 MCP 가 아닌데 커넥터로 붙어 있다. **MCP 냐 아니냐가 경계가 아니라, 읽기냐
쓰기냐가 경계다.**

### 1.5 증거 경로가 끊겨 있다

- `analyze_image` 는 turn trace 에 335회 **선언**되고 **호출은 0회**.
- 입력 `artifact` 는 vision store handle. vision store 는 대화로 들어온 이미지를
  담는다(`Keeper_vision_ingest.evict_blocks ~mode:Eager` / `evict_message
  ~mode:Store_only`). **keeper 가 만든 파일을 넣는 경로는 없다.**
- blob store 는 살아 있다: `~/me/.masc/tool_blobs/` 256 샤드 1.0 GB,
  trace 에 `masc:blob` 272회 · `keeper_artifact_read` 1274회. 다만 `Execute` 의
  stdout 만 들어간다.

### 1.6 JIRA

keeper trace 에 `sb`·`jira`·`atlassian` 호출 **0건**. `sb jira` 는 존재하지만
Second Brain 개인 도구이므로 masc 가 알아서는 안 된다.

## 2. 두 개의 빈자리

| | 접근 | 도구 정의 | 증거 |
|---|---|---|---|
| playwright | 있음 | CLI 가 대신함 | **없음** |
| JIRA | 있음 | **없음** | 없음 |

playwright 는 정의가 필요 없어서 이미 동작했다. JIRA 는 정의가 없어서 못 쓴다.
증거는 둘 다 없다.

## 3. 설계 A — MCP 도구 중계 (JIRA)

`runtime_handler` 는 닫힌 variant 37개다. 도구 하나마다 variant 하나면 외부 도구를
못 넣는다. **variant 하나로 묶는다.**

```ocaml
| Tool_mcp_call of { server : string; tool : string }
```

exhaustive match 는 유지되고, 서버·도구 이름은 값으로 들어간다.

`all_descriptors ()` 는 이미 `unit ->` 함수다(상수가 아니다). 여기서 설정을 읽어
선언된 MCP 도구를 붙인다. MCP 의 `{name, description, inputSchema}` 와 descriptor 의
`{name, description, input_schema}` 는 모양이 같아 변환이 기계적이다.

### 3.1 화이트리스트가 계약이다

전부 흡수하지 않는다. 설정에 **서버·도구·gate 를 명시**한다.

```toml
[[mcp_relay]]
server = "atlassian"
tool = "getJiraIssue"
gate = "network_read"

[[mcp_relay]]
server = "atlassian"
tool = "searchJiraIssuesUsingJql"
gate = "network_read"
```

`gate` 는 추론하지 않는다. 같은 서버 안에서도 조회는 `network_read`, 생성은
`connector_post`(one-shot) 로 갈린다. 자동 판단은 쓰기를 읽기로 오분류할 수 있다.

Atlassian MCP 는 31개 도구를 노출하지만 조회 용도라면 위 둘이면 된다. 표면 여유
22 KB 안에서 관리한다.

### 3.2 gate 별 계약

- `network_read`: `Replay_web_fetch` 옆에 선다. 재시도 가능, 부수효과 없음.
- `connector_post`: 요청 정확 보존 · one-shot · replay. JIRA 티켓 생성이 여기.

## 4. 설계 B — keeper 산출물 증거

keeper 가 만든 파일을 저장소에 등록하는 도구가 없다. `Keeper_vision_tool.store_artifact
~dir bytes` 는 이미 있고 호출자가 0개다.

필요한 것: 파일 경로를 받아 handle 을 돌려주는 도구. 두 가지를 정해야 한다.

1. **어느 저장소인가.** 이미지는 vision store(`analyze_image` 가 읽는 곳), 그 외는
   blob store. 하나로 합치는 것은 이 RFC 범위 밖이다.
2. **path jail.** `Keeper_alerting_path.effective_allowed_paths ~meta` 가 있다.
   읽기 허용 경로 안의 파일만 등록한다.

완성되면 keeper 의 흐름이 이렇게 닫힌다.

```
Execute 로 화면 캡처 → 산출물 등록(handle) → analyze_image 로 확인
```

MCP 도, Chrome 확장도 필요 없다.

## 5. 기각한 대안

### 5.1 Chrome 확장으로 붙기

로그인 세션을 그대로 쓰는 이득이 있다. 그러나 같은 이득을 `connect_over_cdp
("http://127.0.0.1:9222")` 두 줄로 얻는다(masc 에 CDP·확장 코드는 없다 — Chrome 언급은
User-Agent 문자열뿐).

둘 다 같은 대가를 치른다: 사용자 브라우저를 점유하고, 브라우저가 꺼져 있으면 못 쓰며,
keeper 여럿이 한 창을 나눈다. **가용성이 사람의 자리 지킴에 묶인다.** 로그인이 필요한
페이지에 한해 CDP 를 쓰고, 그 외에는 지금처럼 새 프로필로 띄운다.

### 5.2 `sb jira` 를 Execute 로 부르기

`sb` 는 Second Brain 개인 도구다. masc 가 그것을 알면 경계가 무너진다.

### 5.3 `analyze_image` 를 blob store 로 옮기기

2026-08-25 에 시도했다가 되돌렸다. vision store 디렉터리가 0개인 것을 보고 죽은
저장소로 판단했으나, `Keeper_vision_ingest` 가 대화 입력 이미지를 그리로 저장한다.
아직 keeper 에게 이미지를 준 적이 없어 비어 있었을 뿐이다. **두 저장소는 담는 것이
다르다** — 옮기면 ingest 경로가 깨진다.

## 6. 범위 밖

- vision store 와 blob store 통합
- Atlassian 외 MCP 서버
- keeper 가 MCP 서버를 스스로 추가하는 것 (설정은 사람이 쓴다)

## 7. 검증

- 표면: `test_keeper_tool_schema_bytes` 상한 85,000 B 유지
- gate: 중계 도구가 선언한 gate 로만 나가는지 — 읽기 도구가 `connector_post` 를
  거치지 않음을 단언
- 증거: 등록한 handle 을 `analyze_image` 가 읽어 텍스트를 돌려주는 왕복 테스트
- path jail: 허용 경로 밖 파일 등록이 거부되는지
