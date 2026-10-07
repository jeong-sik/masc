---
description: MCP 서버 instructions — 프로필별 도구 발견 안내(full / managed_agent / operator_remote / seat)
category: mcp
operator_surface: primary
---

### full [primary: 공개 MCP 프로필의 도구 발견 안내]
MASC (Multi-Agent Shared Context) enables AI agent collaboration.
PROJECT: Agents sharing the same base path (.masc/ folder) align together.
CLUSTER: Set MASC_CLUSTER_NAME for multi-machine workspace (otherwise tool
surfaces use the configured cluster/default label).
READ: use resources/list + resources/read (status, tasks, who, messages,
events, library, tool-help-index) for snapshots.
WRITE: task state changes are CAS-guarded; pass expected_version.

### managed_agent [primary: managed-agent MCP 프로필의 도구 발견 안내]
MASC managed-agent profile exposes the internal agent control surface. Do not
assume that the public /mcp surface and the managed-agent surface have the same
inventory.

### operator_remote [primary: 원격 운영자 MCP 프로필의 도구 발견 안내]
MASC remote operator profile exposes six operator tools:
masc_operator_snapshot, masc_operator_digest, masc_operator_action,
masc_operator_board_attention_quarantine_requeue,
masc_operator_task_recovery_resolve, and masc_operator_confirm.
masc_operator_board_attention_quarantine_requeue accepts only with the exact
Keeper, partition, candidate, and quarantine id observed from durable state; it
never auto-retries. masc_operator_task_recovery_resolve accepts only the exact
task owner and backlog version observed from Task state; it performs no liveness
inference. When confirm_required=true, you must call masc_operator_confirm with
the returned confirm_token before the action executes. Do not assume access to
any other MASC tool from this endpoint.

### seat [primary: 초대받은 참가자 MCP 프로필(/mcp/play)의 도구 발견 안내]
MASC seat profile: you were invited to play the shared DOS machine with other
players, people and Keepers, one turn at a time. Your tools are the ones this
endpoint lists: read the screen, press keys, type text, run the machine, and
hand the turn on. No other MASC tool or MCP method is available here.
The screen answer names the controller: only the controller's press, type and
step move the machine; anyone else's are refused. When the controller is you,
play your turn, then pass it to the next player with masc_dos_pass. When it is
someone else, wait and read the screen again later.
