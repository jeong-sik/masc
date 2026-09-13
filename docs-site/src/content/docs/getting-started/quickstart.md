---
title: Quickstart
description: Connect your model runtime and talk to imp in its default sandbox.
---

Install the prebuilt binary for macOS or Linux; no OCaml or Node.js build tools
are required. This guide targets **0.35.14**. Check publication on
[Releases](https://github.com/jeong-sik/masc/releases) and use the installer
attached to the same tag as your binary.

```bash
TAG=v0.35.14
curl -fsSL "https://github.com/jeong-sik/masc/releases/download/${TAG}/install.sh" \
  -o /tmp/masc-install.sh
bash /tmp/masc-install.sh --version "$TAG" --base-path "$HOME/masc-workspace"
```

After installation, run this separate command to update PATH in the current terminal.

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Optional inspection: run `less /tmp/masc-install.sh` before installation. Press `q` to exit, then run the `bash` installation command above.

For a reinstall, append `--force` or `--wizard` to the `bash /tmp/masc-install.sh` command. The separate `export PATH=...` command takes no installer options.

## First conversation with `imp` (0.35.14)

This is the 0.35.14 installation contract. Check the release tag and asset
availability on [GitHub Releases](https://github.com/jeong-sik/masc/releases) before downloading.

1. Run the installer wizard with `--base-path "$HOME/masc-workspace"` and select
   the model runtime you own. Runtime setup binds that selection to the helper
   lanes with `--setup-lanes`; you do not need a second model subscription.
2. Authenticate that runtime before starting MASC. For Claude Code or Codex,
   install its CLI and complete its own login, then confirm it can answer a
   prompt in this terminal. For an API runtime, export the credential variable
   named by the wizard in this terminal. For a local model, start its server
   and load a model that supports tool calls. MASC does not install or log in
   to these model runtimes.
3. Install and start Docker Desktop on macOS, or Docker Engine on Linux.
   `docker info` must succeed as your current user. Then run:

Choose a numbered model or enter an exact model ID. The wizard shows the source
of its context limit; Codex's observed client limit takes precedence over the
catalog. If no limit is known, enter the documented value. Claude Code and Codex
enable tools and streaming automatically. Z.AI credentials use `ZAI_API_KEY`.

```bash
masc setup --base-path "$HOME/masc-workspace"
```

`setup` seeds missing configuration, checks Docker, builds the default sandbox
image, starts or connects to the server for this workspace, logs in as
`local-admin`, starts the existing `imp`, and opens the TUI. It preserves the
Keeper manifest. The default `imp` has `activation_mode = "manual"`,
`sandbox_profile = "docker"`, and `network_mode = "inherit"`.
If another workspace occupies the port, choose a free one with `--port 8936`.
On exit, setup stops a server it started itself. Use `--no-tui` to leave that
server running and connect to it separately.

In the TUI, select **Keepers → imp** and send these requests one at a time:

- “Hello. Please reply so I can check our conversation.”
- “Create a Board post titled First conversation and show its id.”
- “Create a Task titled Explore my sandbox, with a description, and show its id.”
- “Run `pwd` and `ls` in your sandbox and show the directory listing.”
- “Use WebFetch to retrieve https://example.com now and report the HTTP status and title.”

Confirm the reply, persisted Board post and Task, and successful sandbox and
web tool results. This checks conversation and basic capabilities; Task
completion is a separate workflow. Web fetch does not require a search API
key; web search needs its own configured search provider. If a tool is waiting
for approval, inspect its pending request in the chat or **Approvals** view.
Do not interpret a pending request or a listening HTTP server as successful
model inference or tool execution.

For platform prerequisites and upgrades, see the [installation guide](https://github.com/jeong-sik/masc/blob/main/docs/INSTALL.md). See [Terminal UI](/guides/tui/) for keys and [Connecting External Tools](/guides/mcp-clients/) for MCP-only clients.
