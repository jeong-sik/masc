# task-362: Official-client tool/context truth on an exact-revision live binary

## 결론 (요약)

main revision `8ef224aa3fa47c8348a783219136017aa75e0e53` 에서 직접 빌드한 라이브 바이너리로 official-client 레인(claude_code, codex_app_server)의 도구 도달성과 컨텍스트 조건을 실측했다.

- **Tool truth**: 카탈로그의 model-facing 도구 83개 전부 `projected` (surface pass, 오프라인·무료)
- **Live truth**: 두 official-client 레인에서 `keeper_time_now` 가 실제 호출됨 (`tool_invoked`)
  - `claude_code.claude-haiku-4-5` — 13.5s, session 01a05967-3a17-7000-850e-6437ad2a537a
  - `codex_subscription.gpt-5.4-mini` — 11.2s, thread 01a05969-98f0-7230-b653-ebef60c630c3
- **Context truth**: probe 턴은 `--setting-sources=` (빈 목록) 로 돈다 — CLAUDE.md·hooks·subagents·skills 어느 설정 레이어도 로드되지 않고, `system_prompt=None` 이라 probe 프롬프트가 유일한 지시다. 즉 실측값은 디스크 컨텍스트에 오염되지 않은 순수 projection 결과다.

## 재현 (정확한 revision)

```
$ gh repo clone jeong-sik/masc -- --depth 50   # HEAD = 8ef224aa
$ dune build --root .                          # exit 0
$ _build/default/bin/keeper_capability_probe_cli.exe --base-path "$MASC_BASE_PATH" --list-runtimes   # exit 0
$ _build/default/bin/keeper_capability_probe_cli.exe --base-path "$MASC_BASE_PATH" --list-tools      # 83 lines
```

측정 시각: 2026-09-01 04:56–05:01 (KST). base-path: `/Users/dancer/me` (MASC_BASE_PATH, deployment overlay `agent-core-models-overlay.toml` 적용 로그 확인).

## 1. Surface pass — 83/83 projected

`--surface-only` 로 카탈로그 전체 model-facing 이름(83개)에 대해 offline 판정:

```
SURFACE_LINES=83
non-projected verdicts: (none)
verdict histogram: 83 projected
```

전 목록(JSONL 전문 83줄)은 커밋된 `task-362-surface.jsonl` 참조. `operator_only`·`aliased`·`withheld_by_schema_error` 는 0건 — 이 revision 의 카탈로그에는 모델에게 숨겨지거나 별명으로 접히는 keeper 도구가 없다.

## 2. Invocation pass — 두 official-client 레인 live

### claude_code (Claude Code subscription, team)

```
$ ... --runtime claude_code.claude-haiku-4-5 --tool keeper_time_now --repeat 1
{"phase":"invocation","runtime":"claude_code.claude-haiku-4-5","lane":"claude_code",
 "tool":"keeper_time_now","model_facing_name":"keeper_time_now","attempt":1,
 "wall_s":13.467,
 "outcome":{"ok":{"kind":"tool_invoked","tool":"keeper_time_now","elapsed_s":13.467}}}
```

### codex_app_server (Codex subscription)

```
$ ... --runtime codex_subscription.gpt-5.4-mini --tool keeper_time_now --repeat 1
{"phase":"invocation","runtime":"codex_subscription.gpt-5.4-mini","lane":"codex_app_server",
 "tool":"keeper_time_now","model_facing_name":"keeper_time_now","attempt":1,
 "wall_s":11.165,
 "outcome":{"ok":{"kind":"tool_invoked","tool":"keeper_time_now","elapsed_s":11.164}}}
```

양쪽 모두 recording dynamic tool 콜백이 실제로 불렸다(`tool_invoked`) — transcript 디코딩이 아니라 콜백 도착으로 관측된 값이다.

## 3. Context truth — 무엇이 로드되지 않았는가

official-client probe(`probe_official_client_invocation`, `lib/keeper/keeper_capability_probe.ml`)가 claude_code 턴을 구성할 때:

- `setting_sources = []` → `Runtime_native_tools.claude_setting_sources_arg` 가 `--setting-sources=` 를 낸다 (`lib/runtime/runtime_native_tools.ml:118`). 빈 목록은 "어떤 레이어도 로드 안 함": user/project/local 설정, CLAUDE.md, hooks, subagents, skills 전부 꺼진다.
- `system_prompt = None` → probe 프롬프트가 유일한 지시.
- `native = Runtime_native_tools.claude_code_default` → 클라이언트 내장 도구 posture 는 기본값.

즉 위 두 `tool_invoked` 는 순수한 "카탈로그 projection → 클라이언트 → 콜백" 체인의 실측이며, 호스트 디스크의 컨텍스트가 개입할 여지가 없다. 이것이 이 문서가 "context truth" 라고 말하는 근거다.

## 4. Runtime lane 지도 (같은 바이너리에서)

`--list-runtimes` 로 이 revision 이 아는 전체 레인:

- `claude_code` — 7 runtime (claude-sonnet-5, opus-5 3종, fable-5, haiku-4-5, opus-5-low/high/max)
- `antigravity_cli` — 12 runtime (gemini-3-x, claude-agy, gpt-oss-120b)
- `agent_core` — 36 runtime (local_llama_server, ollama_cloud*, mlx_server, ollama, glm-coding*, kimi_coding*)
- `codex_app_server` — 11 runtime (gpt-5.3~5.6 계열)

(전체 목록은 커밋된 `task-362-runtimes.txt` 참조. 개수는 해당 시점 runtime.toml 기준.)

## 산출물

- `docs/evidence/task-362-official-client-live-truth.md` — 이 문서
- `docs/evidence/task-362-surface.jsonl` — surface pass 전문 (83줄)
- `docs/evidence/task-362-live-claude-code.jsonl` / `task-362-live-codex.jsonl` — invocation pass 원문
- `docs/evidence/task-362-runtimes.txt` — 레인 지도

## 재시도 조건

- revision 이 바뀌면 surface/live 전부 다시 측정해야 한다(이 문서는 `8ef224aa` 에만 성립).
- live pass 는 구독 레인 실제 턴을 소비한다(각 1턴). 반복 측정은 필요한 (runtime, tool) 쌍만.
