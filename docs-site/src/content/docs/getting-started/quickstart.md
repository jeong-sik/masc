---
title: Quickstart
description: Connect your model runtime and talk to imp in its default sandbox.
---

Install the latest published binary for macOS or Linux; no OCaml or Node.js
build tools are required. Check [Releases](https://github.com/jeong-sik/masc/releases)
for the available version and platform requirements.

```bash
curl -fsSL https://github.com/jeong-sik/masc/releases/latest/download/install.sh \
  -o /tmp/masc-install.sh &&
bash /tmp/masc-install.sh
```

With a terminal, the wizard enabled and no `--base-path`, the installer asks
which directory should hold your workspace. Without that prompt or an explicit
path, it uses the current directory. Keep the same path when resuming;
`--base-path` names the directory **containing** `.masc`.
To inspect the script, download it successfully, read it with
`less /tmp/masc-install.sh` (`q` exits), then run the `bash` command.
To pin a release, download its installer and also pass `--version TAG`; see the
[installation guide](https://github.com/jeong-sik/masc/blob/main/docs/INSTALL.md#install).

## First conversation with `imp`

1. Prepare one model connection: a supported CLI subscription and its login,
   an API credential, or a local model server with tool support. Claude Code and
   Codex use their official CLI accounts; an API key is not required for those
   subscription connections. Setup offers sign-in and retry when a connection
   check fails and reports account limits separately.
2. Choose a sandbox in setup. Docker, supported microVM backends and remote SSH
   are different choices; you do not have to install Docker before installing
   MASC. Setup checks prerequisites and offers available installation/startup
   actions. Image preparation and a successful Keeper start are separate checks.
3. Complete setup to prepare the workspace server and `imp`, then open the TUI.
   Optional voice and host tools can be configured along the way or later.

If setup did not open, or you chose to finish later, run:

```bash
"$HOME/.local/bin/masc" setup
```

Use your chosen binary directory if you changed `--prefix`. To select the
workspace explicitly, append `--base-path /path/to/your/workspace` using the
same directory you chose during installation. A new terminal finds `masc` after
accepting the PATH prompt; for this terminal, use
`export PATH="$HOME/.local/bin:$PATH"` with the default prefix.

Setup preserves existing Keeper configuration. A freshly seeded `imp` defaults
to `activation_mode = "manual"`, `sandbox_profile = "docker"`,
`sandbox_image = "base"` and `network_mode = "inherit"`; setup can select another
backend. If another workspace occupies the port, add `--port 8936`.
In a terminal, `masc setup` without sandbox or network options opens the guided
journey. It prepares its server with `--no-tui` before opening the TUI separately,
so leaving that conversation does not stop the prepared server. When you pass
sandbox or network options directly to `masc setup`, leaving its TUI stops a
server that setup started itself. Add `--no-tui` to keep that server running and
connect separately. Setup does not stop a server it reused.
Use `masc doctor` for a read-only report on the same workspace.

In the TUI, select **Keepers → imp** and send these requests one at a time:

- “Hello. Please reply so I can check our conversation.”
- “Create a Board post titled First conversation and show its id.”
- “Create a Task titled Explore my sandbox, with a description, and show its id.”
- “Run `pwd` and `ls` in your sandbox and show the directory listing.”
- “Use WebFetch to retrieve https://example.com now and report the HTTP status and title.”

Confirm the reply, persisted Board post and Task, and successful sandbox and
web tool results. This checks conversation and basic capabilities; Task
completion is a separate workflow. Web fetch does not require a search API
key; web search needs its own configured search provider, and
`masc web-search-setup` shows which one is missing. If a tool is waiting
for approval, inspect its pending request in the chat or **Approvals** view.
Do not interpret a pending request or a listening HTTP server as successful
model inference or tool execution.

For platform prerequisites and upgrades, see the [installation guide](https://github.com/jeong-sik/masc/blob/main/docs/INSTALL.md). See [Terminal UI](/guides/tui/) for keys and [Connecting External Tools](/guides/mcp-clients/) for MCP-only clients.
