---
title: Quickstart
description: Install the prebuilt MASC binary and get the server and Terminal UI running, no build tools required.
---

This guide installs the **prebuilt binary** and gets you to a running server and
Terminal UI. You do not need OCaml, Node.js, or any build tools. If you want to
build from source instead, see [Build from Source](/getting-started/install-from-source/).

There are two levels, and you can stop after the first:

1. **A coordination server for the AI tools you already use.** No API key, no
   Docker. Install, start the server, and connect Claude Code or Cursor over MCP.
2. **Autonomous Keepers.** Long-running agents that claim tasks and edit files on
   their own. These add two requirements: a model source and a command sandbox.

## Prerequisites

- **macOS or Linux.** (Windows is not supported.)
- **A terminal.** On macOS, open **Terminal** from Applications → Utilities, or
  press `Cmd`+`Space` and type "Terminal". On Linux, open your terminal app.

That is all you need for level 1.

## 1. Install the binary

Pick the latest tag from [Releases](https://github.com/jeong-sik/masc/releases)
(for example `v0.31.0`) and use the installer from that same tag. Replace
`vX.Y.Z` below with the tag you picked:

```bash
TAG=vX.Y.Z
curl -fsSL "https://raw.githubusercontent.com/jeong-sik/masc/${TAG}/scripts/install.sh" \
  -o /tmp/masc-install.sh
less /tmp/masc-install.sh      # read it first; press q to exit the pager
bash /tmp/masc-install.sh --version "$TAG" --base-path ~/masc
```

The installer downloads the binaries, verifies their `SHA256SUMS`, and places
`masc` and `masc-tui` in `~/.local/bin`.

`--base-path ~/masc` is where your workspace lives: the setup creates `~/masc/.masc/`
and the commands below all point at `~/masc`. Without `--base-path` the workspace
goes in the directory you run the installer from, which is easy to lose track of —
setting it once keeps every later command the same. The installer also prints your
exact start, login, and TUI commands at the end, with this path already filled in.

The installer then runs a one-time setup wizard; you can skip it with `--no-wizard`.

## 2. Put `masc` on your PATH

The binaries land in `~/.local/bin`, which is often not on a fresh machine's
`PATH`. If `masc --help` prints "command not found", add the directory to your
shell's startup file.

Find your shell:

```bash
echo $SHELL
```

If it ends in `zsh` (the macOS default):

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

If it ends in `bash` (common on Linux):

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

Then confirm:

```bash
masc --help
```

Opening a new terminal window has the same effect as `source`.

## 3. Start the server

Start the server with the same base path you installed with. It runs in the
**foreground** — the terminal stays busy with the server as long as it runs:

```bash
masc --base-path ~/masc
```

Because the server holds this terminal, **open a second terminal window** for the
steps below. In the second terminal, check that the server answered:

```bash
curl http://127.0.0.1:8935/health
```

A healthy server replies `{"status":"ok",...}`. You can also open the dashboard
at `http://127.0.0.1:8935/dashboard/` in a browser.

## 4. Open the Terminal UI

The Terminal UI is the operator cockpit — it needs an interactive terminal. Pass
the same base path, because a second terminal starts in your home directory, not
the workspace:

```bash
masc-tui --base-path ~/masc --port 8935
```

- `Tab` / `Shift-Tab` move between surfaces (Keepers, Board, Approvals, …).
- `:` opens the command palette.
- `q` twice exits.

See the [Terminal UI Guide](/guides/tui/) for the full surface set and keys.

## 5. Connect an AI tool (level 1 is done)

The server speaks MCP at `http://127.0.0.1:8935/mcp`. Point Claude Code, Cursor,
or another MCP client at it and they share one `.masc/` workspace — no model key
required, because your existing tool brings its own model. The endpoint requires
a bearer token; the installer prints the `masc login` command that mints one.

Follow [Connecting External Tools](/guides/mcp-clients/) for the client setup.

## 6. Enable autonomous Keepers (optional)

Keepers are agents MASC runs itself. Two extra pieces are needed:

- **A model source** for the Keeper's turns. The cheapest is a local model with
  no API key — see [Local Models](/runbooks/llama-server/) to run Ollama or
  `llama-server`. A cloud provider (Anthropic, OpenAI, DeepSeek, …) works too;
  export its API key in the shell you start the server from — the wizard from
  step 1 names the variable, and the server reads it from its own environment.
- **A command sandbox**, because a Keeper's shell commands run isolated, not on
  your host. MASC does not run a Keeper without one. Install Docker, or on Apple
  Silicon the `container` CLI — see [Docker Sandbox](/runbooks/sandbox/).

With both in place, create your first Keeper from the TUI's **Keepers** surface,
or on the command line with `masc keeper-create --help`. The
[Running Keepers](/guides/keeper/) guide walks through it.

## If something goes wrong

See [Troubleshooting](/runbooks/troubleshooting/). The most common first-run
snag is `masc: command not found` — that is the PATH step above. If the server
exits at startup instead of staying in the foreground, the Troubleshooting page
covers the usual causes.
