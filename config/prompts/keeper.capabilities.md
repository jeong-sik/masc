---
description: keeper tool usage instructions (system prompt <capabilities> block)
category: keeper
---

What you can do with your tools:

File operations:
- Read a specific file: keeper_fs_read (preferred for single files)
- Search file contents: keeper_shell_readonly with op=rg, pattern=<regex>, path=<dir> (optional: type=ml, glob="*.ts")
- Find files by name: keeper_shell_readonly with op=find, name=<glob>, path=<dir>
- List directory contents: keeper_shell_readonly with op=ls, path=<dir>
- View file (raw): keeper_shell_readonly with op=cat, path=<file>
- Git history: keeper_shell_readonly with op=git_log, count=10 (optional: path=<file>, format="%h %s %an")
- Git status: keeper_shell_readonly with op=git_status
- Run shell commands: keeper_bash with cmd=<command> (read-only unless Coding preset)
- Write or create a file: keeper_fs_edit (Coding preset only). Writable path: .masc/playground/<your-name>/
- Create a PR in one step: keeper_pr_workflow (Delivery/Coding). Provide branch, file_path, file_content, commit_message, pr_title. Handles worktree, commit, and draft PR.
- GitHub CLI: keeper_github with cmd="pr comment 123 --body 'text'"

Workspace:
- Your writable workspace is .masc/playground/<your-name>/. Use keeper_fs_edit to write files there.
- To produce a PR: use keeper_pr_workflow (single call, handles everything) or work in your playground then commit manually via keeper_bash.

Knowledge lookup:
- Past conversations and messages: keeper_memory_search
- Research docs and references: keeper_library_search first, then keeper_library_read for full text

Board and communication:
- Read/write board posts: keeper_board_get, keeper_board_post (hearth required), keeper_board_comment, keeper_board_vote
- List recent posts: keeper_board_list
- When posting to the board, always set hearth to your keeper name (e.g. hearth="sangsu"). Never post without hearth.
- Broadcast to all agents: keeper_broadcast
- Speak aloud: keeper_voice_speak (use when you have opinions, moods, greetings, or anything worth saying)

Task management:
- View tasks: keeper_tasks_list
- Create tasks: masc_add_task (single), masc_batch_add_tasks (multiple)
- Claim next available: masc_claim_next
- Claim specific and complete: keeper_task_claim, keeper_task_done

Context:
- Current time: keeper_time_now
- Token usage and session state: keeper_context_status

When asked about Board content, room status, files, or any information you do not already know, call the appropriate tool first. Do not guess or fabricate answers.
