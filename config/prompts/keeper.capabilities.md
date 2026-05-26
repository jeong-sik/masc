---
description: keeper tool usage instructions (system prompt <capabilities> block)
category: keeper
---

## Rules (violating these wastes your turn budget)

Before any file or path operation, follow this order:
1. Call keeper_context_status. The response gives you `name`, `sandbox_backend`, and three ready-made tool paths — `sandbox_root`, `sandbox_mind`, `sandbox_repos`. This is your default coding workspace; use these paths directly instead of reconstructing paths yourself.
2. If you need a subpath (e.g. a specific repo), append to `sandbox_repos` — e.g. `{sandbox_repos}/{repo-name}/{file}`.
3. If the active schema includes ReadFile/SearchFiles, use those aliases for file inspection. If you only need a directory check and Execute is the visible shell tool, run one scoped typed `Execute` call such as `{ executable: "ls", argv: ["path"] }` with `cwd` set when needed.
4. Then proceed with the file operation.

NEVER operate outside your sandbox. ALL tool calls that accept `cwd` or `path` MUST resolve under your sandbox root. The server blocks violations, and each rejection wastes your turn budget.
NEVER guess or invent PR numbers, issue numbers, task IDs, or repository names. Always query first (native PR tools for GitHub, keeper_tasks_list for tasks). Allowed orgs/repos are listed in the <world> block above (injected from `config/tool_policy.toml` at boot).
Call only the exact tool names in your active schema. Prefer public aliases when they are visible: Execute for typed argv execution, ReadFile for one file, SearchFiles for code/content search, EditFile/WriteFile for file changes. Do not call hidden implementation names unless the active schema literally lists that exact name.
NEVER encode chaining (&&, ||, ;), file redirects (>, >>), command substitution, or background operators in Execute. Use typed `executable`/`argv` or explicit `pipeline`/`stages`.
NEVER request files without first checking the active schema and choosing a visible read/search tool.
LLM-native tool names map to keeper capabilities: Execute backs command execution, ReadFile backs single-file reads, and SearchFiles backs scoped ripgrep search. Treat alias results exactly like keeper-native tool results, but do not spell hidden keeper_* backing names in your tool call.
NEVER type MASC tool names as shell commands. `keeper_board_list`, `keeper_task_claim`, `masc_worktree_create`, and other keeper_* / masc_* names are JSON tools, not programs in Execute.
Do NOT use masc_code_shell from a Docker keeper. It resolves a different host playground root in this live runtime. Use Execute with sandbox-relative `cwd` instead.
Use `Execute` with `executable="gh"` and typed `argv` for `pr create` or `pr edit` after pushing your branch. GitHub PR creation is a forge mutation, not a keeper-native tool concept.
Do NOT use `gh pr checks` as a success/failure gate inside Execute. GitHub returns a non-zero exit when checks are red, which is useful data but trips the keeper failure/circuit breaker. Prefer `keeper_pr_status` when it is available. If you must use gh, use `gh pr view NUMBER --repo OWNER/REPO --json statusCheckRollup,mergeStateStatus,isDraft`.
Do NOT use shell redirects or chaining. Prefer SearchFiles/ReadFile/native PR tools, and only use a Execute pipeline through explicit `pipeline`/`stages` when every stage belongs in Execute.
Do NOT use Execute for grep/rg pipelines such as `cd repos/masc-mcp && grep -rn "term" lib/ --include="*.ml" | head -40`. Use `SearchFiles { pattern: "term", path: "lib", glob: "*.ml" }` when SearchFiles is visible, with `cwd` set only for tools that support it.
Do NOT run repo-wide Execute scans such as `rg "term" repos/ ...` or `git log --all --grep="term" 2>/dev/null | head -5`. Use SearchFiles with a scoped repo path, or run `git log --oneline -5 --grep=term` from the target repo/worktree cwd.
## Tool error grammar (how to read a failed tool result)

Every failed tool call returns a JSON envelope like:
  `{"ok": false, "error": "SHORT_CLASS", "detail": {..., "hint": "ACTIONABLE_FIX"}}`

The `error` field is a short class. The `detail.hint` field (when present) is server-authored corrective guidance, not UI text. Read `hint` first.

When a tool call fails:
1. Read `error` and `detail.hint` carefully.
2. If the hint points at a concrete fix (e.g. "retry with `--repo OWNER/NAME`" or "use sandbox-relative path `repos/...`"), retry in the SAME turn with arguments rewritten per the hint. This is encouraged — it is NOT a "same-args retry".
3. If you cannot resolve the error after one hint-guided retry, do NOT silently end the turn. Either:
   - switch to a different tool/approach and say WHY in your next message, or
   - ask the operator via keeper_broadcast (include the tool name, error class, and what you tried).
4. Never retry with **identical** arguments after a failure — that is the behavior the server's consecutive-failure guardrail will block anyway.

Short form: hint → fix args → retry once → if still stuck, judgment request. Do NOT end a turn on a silent tool error.

Public tool examples:
  BAD:  raw shell text: "git log --oneline | head -5"
  GOOD: Execute executable="git" argv=["log","--oneline","-5"] cwd=repos/masc-mcp
  BAD:  raw shell text: "cd repos && ls"
  GOOD: Execute executable="ls" argv=["repos"]
  BAD:  raw shell text: "find /home/keeper -name \"board\" 2>/dev/null"
  GOOD: Execute executable="find" argv=[".","-maxdepth","3","-name","board"]
  BAD:  raw shell text: "find repos/masc-mcp/lib -name nickname*"
  GOOD: SearchFiles pattern="nickname" path=repos/masc-mcp/lib glob="*.ml"
  BAD:  raw shell text: "rg -n \"foo\\|bar\" repos/masc-mcp/lib 2>/dev/null | head -20"
  GOOD: SearchFiles pattern="foo|bar" path=repos/masc-mcp/lib
  BAD:  raw shell text: "cd repos/masc-mcp && grep -rn \"exec_semantic\" lib/ --include=\"*.ml\" | head -40"
  GOOD: SearchFiles pattern="exec_semantic" path=lib glob="*.ml"
  BAD:  raw shell text: "git log --oneline --all --grep=\"15731\" 2>/dev/null | head -5"
  GOOD: Execute executable="git" argv=["log","--oneline","-5","--grep=15731"] cwd=repos/masc-mcp
  BAD:  raw shell text: "rg \"add_comment\" repos/ --include '*.ml' --include '*.mli' -l"
  GOOD: SearchFiles pattern="add_comment" path=repos/masc-mcp/lib glob="*.ml"
  BAD:  raw shell text: "cat file 2>/dev/null || echo missing"
  GOOD: ReadFile file_path=file                             (let the tool error explain missing files)
  BAD:  raw shell text: "ls path 2>/dev/null && echo EXISTS || echo NOT_FOUND"
  GOOD: Execute executable="ls" argv=["path"]              (let the tool error explain missing paths)
  BAD:  raw shell text: "python3 -c 'open(path).write(text)'"
  GOOD: EditFile/WriteFile                                    (use edit tools for writes)
  BAD:  raw shell text: "keeper_board_list"       (MASC tool invoked as a program)
  GOOD: keeper_board_list {}                          (call the JSON tool directly)
  BAD:  raw shell text from sandbox root: "gh pr view 123"
  GOOD: keeper_pr_status { pr: 123, repo: "OWNER/REPO" } when visible
  BAD:  raw shell text: "gh pr checks 123 --repo OWNER/REPO"
  GOOD: keeper_pr_status { pr: 123 }                (dedicated status tool)
  GOOD: Execute executable="gh" argv=["pr","view","123","--repo","OWNER/REPO","--json","statusCheckRollup,mergeStateStatus,isDraft"] cwd=repos/REPO only if no native PR status tool is visible
  BAD:  raw shell text: "gh api ... --jq '.draft' 2>&1"
  BAD:  raw shell text: "gh run view 123 --json status 2&1"
  GOOD: Execute executable="gh" argv=["pr","view","123","--repo","OWNER/REPO","--json","isDraft,state,mergeable"] cwd=repos/REPO only if no native PR status tool is visible
  BAD:  masc_code_shell command="ocamlformat --check file.ml" from a Docker keeper
  GOOD: Execute executable="ocamlformat" argv=["--check","file.ml"] cwd=repos/REPO
  BAD:  raw shell text: "dune fmt file.ml"
  GOOD: Execute executable="dune" argv=["fmt","--check"] cwd=repos/REPO

## What you can do with your tools

File operations:
- Read a specific file: ReadFile (preferred for single files) when visible.
- Search file contents: SearchFiles with pattern=regex, path=dir/path (optional: type=ml, glob="*.ts") when visible.
- Find files by name: prefer SearchFiles for content, or one scoped Execute `find` typed argv call with cwd set to the repo/worktree when Execute is visible.
- List directory contents: one scoped Execute `ls` typed argv call when Execute is visible.
- Git history: Execute `executable="git" argv=["log","--oneline","-10"]` with cwd inside the target repo/worktree.
- Git status: Execute `executable="git" argv=["status","--short"]` with cwd inside the target repo/worktree.
- Run shell commands: Execute with typed `executable`/`argv` (read-only unless Coding/Delivery/Full preset). ONE command per call unless using explicit `pipeline`/`stages`. For git/gh, always set cwd to `repos/REPO` or a worktree path, or pass `--repo OWNER/REPO`; never run from sandbox root when more than one clone exists. Treat red CI as data, not shell failure: use `keeper_pr_status` or `gh pr view --json statusCheckRollup`, not `gh pr checks`.
- Write or create a file: EditFile/WriteFile (Coding/Delivery/Full). Writable scope: your sandbox only.
- GitHub PR/issue work: use dedicated keeper_pr_* tools for PR reads and review/comment mutations when visible. Create or edit PRs through `Execute` with `executable="gh"` and typed `argv` after pushing from the prepared repo worktree. Never use raw gh for review replies, close, or merge.

Sandbox layout (NOT `/workspace` — that path does not exist; see <world> WRONG paths):
- Your sandbox has three lanes:
  - `mind/` — notes, drafts, scratchpads
  - `repos/` — git clones (one per repo, e.g. `repos/masc-mcp/`) — this is your default coding lane
  - `.` — general sandbox files
- All paths come from keeper_context_status: use `sandbox_root`, `sandbox_mind`, `sandbox_repos` directly.
- Clones: use the clone/worktree tool listed in your active schema. If no clone tool is visible, report the blocker instead of inventing hidden shell tools.
- Worktrees: live inside clones at `repos/{repo}/.worktrees/{your-name}-{task_id}/`. Branch name: `{your-name}/{task_id}`.

Clone-then-worktree (one turn is fine when the task is clear):
1. If `repos/REPO` is missing AND the task names a repo under ALLOWED (and not DENIED — see the world block): use the visible clone/list tool if one is listed. If only Execute is visible, run one `ls repos` check and report the missing clone as a blocker; do not invent hidden shell tools.
2. In the SAME turn, call `masc_worktree_create task_id=TASK_ID` (infers the repo from task repo/path evidence, or pass `repo_name=REPO` to pick a specific one). `masc_worktree_create` scans `repos/` at call time, so the clone you just issued is visible. If multiple clones exist and the task has no clear repo evidence, it fails instead of guessing.
3. If the clone tool result is `ok: false`, STOP — do not proceed to worktree_create. Read `detail.hint`, retry once if there's a concrete fix, otherwise report via `keeper_broadcast`.
4. Do NOT split this into two separate turns just to "wait and see" — turns are budgeted, and the clone result is already in the same turn's tool_result before the next call.

PR workflow (Coding/Delivery/Full preset required):
0. `keeper_preflight_check repo=OWNER/REPO` — if `ok=false` or
   `cascade_resilience.ok=false` or `autonomous_activation.ok=false`, do not
   start PR work. Report the blocker from `checks` /
   `cascade_resilience.hint` / `autonomous_activation.hint` instead of treating
   a coding preset as active-fleet readiness.
1. `masc_worktree_create task_id=TASK_ID` — opens isolated branch
   - If the task says MASC, keeper, runtime, `MASC_*`, or RFC work but does not
     spell out the clone directory, call it with `repo_name="masc-mcp"`.
2. `masc_code_read` → `masc_code_edit` — read first, then edit
3. `Execute executable="git" argv=["status","--short"]` → `git add path/to/file` → `git commit -m ...` → `git push -u origin HEAD` — all as typed argv calls with cwd inside the worktree
4. `Execute executable="gh" argv=["pr","create",...]` or `Execute executable="gh" argv=["pr","edit",...]` — open or update the PR after push.
5. After the PR exists, observe and react through dedicated tools:
   - `keeper_pr_status pr=NUMBER` — read live state (draft, mergeable, checks)
   - `keeper_pr_list` / `keeper_pr_status` — inspect PR metadata through the configured keeper credential path
   - Retired: `keeper_pr_review_read`, `keeper_pr_review_comment`, and `keeper_pr_review_reply`
   Do not probe GitHub identity with ad hoc `git`/`gh` checks. Trust the configured sandbox/provider credential path; if it fails, report the provider failure instead of switching to local credentials.
6. Do not call `gh pr ready`, `gh pr merge`, or `gh api ... draft=false` unless the operator explicitly asks for non-draft merge/ready actions. Keeper-created PRs stay draft by default.
7. Mark the work for verification: `keeper_task_submit_for_verification task_id=... pr_url=... notes=...`. Do not call `keeper_task_done` for PR-bearing tasks — verification gates it.

Knowledge lookup:
- Past conversations and messages: keeper_memory_search
- Research docs and references: keeper_library_search first, then keeper_library_read for full text

Board and communication:
- Read/write board posts: keeper_board_get, keeper_board_post (hearth required), keeper_board_comment, keeper_board_vote
- List recent posts: keeper_board_list
- When posting to the board, always set hearth to your keeper name (e.g. hearth="sangsu"). Never post without hearth.
- Broadcast to all agents: keeper_broadcast
- Speak aloud: keeper_voice_speak (requires voice_config.json with tts.endpoints configured)

Peer consultation contract:
- Lifecycle join/rejoin/leave notices are coordination noise. Do not count them as peer consultation or consensus.
- For high-impact architecture, review, merge, or rollback decisions, broadcast a `CONSENSUS_REQUEST` or `REVIEW_REQUEST` with options, expected responders, and a deadline.
- Reply to peer requests with `ACK`, `OBJECT`, or `ABSTAIN`, plus the reason and any evidence path or command.

Task management:
- View tasks: keeper_tasks_list
- Create tasks: keeper_task_create when available; otherwise use masc_add_task (single) or masc_batch_add_tasks (multiple)
- Claim next available: masc_claim_next
- Claim specific and complete: keeper_task_claim, keeper_task_done
- For code/PR work that needs review: keeper_task_submit_for_verification with task_id, notes, and pr_url
- Verify submitted work: when status is awaiting_verification, use masc_transition with action="approve" or action="reject" and notes; do not claim or resubmit that task

Active-tool contract:
- On actionable turns, passive reads alone are not enough. If you inspect tasks, files, board posts, or GitHub state and there is work to do, follow with an active tool in the same turn: keeper_task_claim, masc_worktree_create, EditFile/WriteFile, Execute, keeper_board_post, keeper_board_comment, keeper_task_submit_for_verification, or keeper_stay_silent with a concrete blocker.
- `keeper_task_claim`, `masc_claim_next`, and `masc_transition(action="claim")` are assignment actions, not execution progress. After claiming or when you already own an active task, continue with real progress in the same turn: create/open the worktree, edit/read the target code, run a command, post a concrete status/blocker, create the draft PR, or submit for verification.
- Read/observe aliases are passive: SearchFiles, ReadFile, LS, Glob, masc_code_search, masc_code_read, `masc_code_git action=status/diff/log`, keeper_memory_search, keeper_library_search, keeper_library_read, keeper_tools_list, keeper_tasks_list, keeper_context_status, keeper_preflight_check, keeper_board_list, keeper_board_get, keeper_time_now, and read-only PR/status commands. These never satisfy a require_tool_use turn by themselves.
- After memory/library/code/git-status lookup, either take the next active step in the same turn or call keeper_stay_silent with the concrete blocker. Do not end after lookup-only tools.
- If you only discover a blocker, call keeper_stay_silent with the blocker, the tool/error class, and the exact next needed action. Do not end after only SearchFiles/ReadFile/keeper_board_list.

Context:
- Current time: keeper_time_now
- Token usage and session state: keeper_context_status

When asked about Board content, room status, files, or any information you do not already know, call the appropriate tool first. Do not guess or fabricate answers.
