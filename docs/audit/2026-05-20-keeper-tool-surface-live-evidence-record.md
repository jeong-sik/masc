# Keeper Tool Surface Live Evidence Record

## 공통 헤더

- 날짜(ISO8601): 2026-05-20T19:26:33+09:00
- 작성자: Codex
- 결정 ID: keeper-tool-surface-public-alias-guidance-2026-05-20
- 적용 대상: `config/prompts/keeper.*`, `lib/keeper/keeper_tool_guidance.ml`, `lib/keeper/keeper_unified_prompt.ml`, `test/test_keeper_unified.ml`
- 결정 상태: 확정

## 근거

- 항목: 지난 6시간 live `WARN`/`ERROR` 중 Keeper/Bash tool-surface 오류가 반복되고, prompt/tool guidance가 내부 구현명(`keeper_bash`, `keeper_shell`)을 call example로 노출하면 같은 실패를 재생산한다.
- 출처: [근거] `jq -sr 'map(select((.level=="WARN" or .level=="ERROR") and (.ts >= "2026-05-20T04:24:00Z"))) | group_by(.level) | map({level: .[0].level, count: length})' /Users/dancer/me/.masc/logs/system_log_2026-05-20.jsonl`; [근거] `scripts/analyze-keeper-bash-failures.sh /Users/dancer/me 6`; [근거] `gh pr list --repo jeong-sik/masc-mcp --state open --limit 80 --json number,title,state,isDraft,headRefName,url`; [근거] `scripts/check-oas-pin.sh`
- 확인일시: 2026-05-20T19:26:33+09:00
- 신뢰도: High
- 제한조건: Live window is `/Users/dancer/me/.masc` only; cutoff was `2026-05-20T04:24:00Z`; results are time-sensitive and must be rechecked for later incidents.

Live findings:
- System log window: `ERROR=1146`, `WARN=2599`; top module bucket was `Keeper=3475` of `3745` WARN/ERROR rows.
- Bash census window: `total=3103`, `failed_or_semantic_failed=809`, `ok=2294`, `failure_pct=26.07`.
- Top Bash failure buckets: `shape_block:pipe_or_redirect=402`, `missing_path_or_wrong_cwd=109`, `command_not_allowed=105`, `wrong_tool_channel=25`.
- Tool-surface leaks were visible in live rows: `keeper_bash direct tool command blocked`, `tool_invoked_as_shell_command` for `keeper_tasks_list`, `keeper_bash_command_shape_blocked`, and `keeper:... tool_error: Bash`.
- Existing open PRs cover adjacent symptoms but not this prompt/tool-guidance root: `#16926` git ref determinism, `#16948` typed tool_error surface, `#16952` Bash scan integer parsing. OAS had `#1648` open for post-merge CI; local OAS pin check reported API fingerprint matched but pin drifted from `07297afa45e69c9d0138d62198ee02f3a89433e2` to upstream `071d01f28c5645a855ca22f440f99e350900486c`.

## 검증

- 1차: Live logs and Bash census were queried from `/Users/dancer/me/.masc` for the current six-hour window.
- 2차: GitHub open PRs were queried on `jeong-sik/masc-mcp`; OAS downstream pin was checked with `scripts/check-oas-pin.sh`.
- 3차: Prompt/code guidance was changed so model-facing hints render public aliases (`Bash`, `Read`, `Grep`, `Edit`, `Write`) and native PR tools instead of internal `keeper_bash`/`keeper_shell` call recipes.
- 재현 결과: `rg -n "keeper_fs_edit|keeper_fs_read|keeper_shell op=rg|keeper_bash \{ cmd|Use Bash/keeper_bash|keeper_bash examples|keeper_shell op=gh|Bash/keeper_bash|cmd=\"" config/prompts lib/keeper/keeper_unified_prompt.ml lib/keeper/keeper_tool_guidance.ml` returned no matches after the change. `ocamlformat --check lib/keeper/keeper_tool_guidance.ml lib/keeper/keeper_unified_prompt.ml test/test_keeper_unified.ml`, `git diff --check`, and this evidence-record validator passed. Focused Dune validation command was `scripts/dune-local.sh build ./test/test_keeper_unified.exe`, but it was not completed because `/tmp/me-dune-local.lock` was held by PID 5198 running `test/test_keeper_fd_pressure_fleet.exe` for another worktree; the waiting command was cancelled to avoid adding more queue pressure.

## 불확실성

- 미확인 항목: Whether live error volume drops requires redeploying a runtime that includes this prompt change and re-running the same six-hour census after enough keeper turns.
- 영향: Without redeploy/follow-up measurement, this record proves the root prompt/tool guidance fix and current live failure mix, not production reduction yet.
- 추가 확인 필요: After merge/deploy, rerun `scripts/analyze-keeper-bash-failures.sh /Users/dancer/me 6` and the system-log `jq` count, then compare `keeper_bash`/`keeper_shell` hidden-name and `wrong_tool_channel` rows.

## 적용범위

- 영향 받는 영역: Keeper prompt generation, dynamic preferred-tool hints, GitHub workflow guidance, unified prompt fallback strings, and focused prompt regression tests.
- 제약/배제: Does not change Bash parser/safety gates, GitHub credential bundles, cascade capacity, OAS provider behavior, or OAS pin state.
- 롤백 조건: Roll back if focused prompt tests fail, public alias routing is not active in the deployed OAS tool schema, or runtime policy intentionally exposes internal `keeper_bash`/`keeper_shell` as the only callable schema names.
