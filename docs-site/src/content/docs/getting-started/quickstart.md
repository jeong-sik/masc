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

## 3. Start it

One command, from the second terminal you will keep using:

```bash
masc --base-path ~/masc
```

`masc` with no subcommand is the front door. In a terminal it hands over to the
Terminal UI, and the TUI starts the server behind it the first time it finds
nothing listening. You do not start the server yourself and you do not run two
commands.

It behaves differently where a person is not watching, and that is deliberate:

| Where you run it | What happens |
| --- | --- |
| A terminal | The Terminal UI opens; the server starts behind it |
| A pipe, a systemd unit, a CI step | The server runs in the foreground |
| With `--host` other than `127.0.0.1` | The server runs in the foreground |

So the same command is both the operator's cockpit and the service entry point.
To watch the server directly instead, pipe it: `masc --base-path ~/masc | cat`.

In the TUI:

- `Tab` / `Shift-Tab` move between surfaces (Keepers, Board, Approvals, …).
- `:` opens the command palette.
- `q` twice exits.

See the [Terminal UI Guide](/guides/tui/) for the full surface set and keys.

## 4. Check the server answered

From a third terminal, or after quitting the TUI:

```bash
curl http://127.0.0.1:8935/health
```

A healthy server replies `{"status":"ok",...}`. The dashboard is at
`http://127.0.0.1:8935/dashboard/`.

If you installed by hand rather than with `install.sh`, seed the workspace once
before any of this:

```bash
masc init --base-path ~/masc
```

That writes the configuration tree — runtime settings, prompts, tool
definitions, themes, connector declarations — out of the binary itself, so it
works on a machine that never had a checkout. It writes 271 files and leaves
`config/keepers/` empty on purpose; see below.

## 5. Connect an AI tool (level 1 is done)

The server speaks MCP at `http://127.0.0.1:8935/mcp`. Point Claude Code, Cursor,
or another MCP client at it and they share one `.masc/` workspace — no model key
required, because your existing tool brings its own model. The endpoint requires
a bearer token; the installer prints the `masc login` command that mints one.

Follow [Connecting External Tools](/guides/mcp-clients/) for the client setup.

The workspace keeps only a SHA-256 of each token, so the file
`.masc/auth/<agent>.token` (mode `0600`) is the one place the bearer itself
survives. To see what exists and retire one:

```bash
masc token list                 # agent, role, expiry, whether the secret is still on disk
masc token revoke --agent NAME  # delete a credential
masc token prune                # delete only the expired ones
```

Minting the same agent name again replaces the credential — that is how you
rotate. An unreadable expiry stamp counts as live, so a prune can never delete a
token that still works.

## 6. Enable autonomous Keepers (optional)

Keepers are agents MASC runs itself. A finished install has **no Keeper at all**
— the roster is per workspace, so neither the installer nor the server invents
one. Three things are missing on day one, and a Keeper needs all three.

**A model source.** The seeded catalog carries five providers, and only one of
them works without a key:

| Provider | Endpoint | Environment variable |
| --- | --- | --- |
| `ollama_cloud` | `ollama.com/v1` | `OLLAMA_CLOUD_API_KEY` |
| `deepseek` | `api.deepseek.com` | `DEEPSEEK_API_KEY` |
| `glm-coding` | `api.z.ai/api/coding/paas/v4` | `ZAI_API_KEY_SB` |
| `kimi_coding` | `api.kimi.com/coding/v1` | `KIMI_API_KEY` |
| `ollama` | `localhost:11434` | none — see [Local Models](/runbooks/llama-server/) |

The variable is read from the environment **the server was started in**, not
from a config file. MASC never asks for a key and never writes one to disk.

The catalog ships 31 provider/model bindings as documented examples, all declaring
`max-request-body-bytes` so any configured model can take a Keeper turn without
startup warnings. `[runtime].default` works as soon as its key is present.

**A sandbox image.** A Keeper runs every turn inside one, and MASC ships none:

```bash
masc sandbox-image
```

That builds `masc-sandbox:general` — Debian slim with `bash`, `ripgrep`, `git`,
`curl` and the handful of tools a shell turn reaches for. It is piped to
`docker build -` with no build context, so it builds the same from an installed
binary as from a checkout. A Keeper that has to *build* a project needs that
project's toolchain instead: point it at another image with `sandbox_image` in
its TOML.

**A sandbox runtime.** Docker, a microVM, or a remote host over SSH. There is no
option to run a Keeper on your own machine. See [Sandbox](/runbooks/sandbox/).

With all three in place, create the first Keeper from the TUI's **Keepers**
surface, or with `masc keeper-create --help`. The
[Running Keepers](/guides/keeper/) guide walks through it.

### Language servers are separate

A Keeper reaching for hover text or a definition needs a language server on the
sandbox `PATH`. MASC bundles none and starts none for you; when the program is
absent the tool reports it rather than failing quietly.

| Language | Program |
| --- | --- |
| OCaml | `ocamllsp` |
| TypeScript, JavaScript | `typescript-language-server` |
| Python | `pylsp` |
| Rust | `rust-analyzer` |
| Go | `gopls` |

## If something goes wrong

See [Troubleshooting](/runbooks/troubleshooting/). The most common first-run
snag is `masc: command not found` — that is the PATH step above. If the server
exits at startup instead of staying in the foreground, the Troubleshooting page
covers the usual causes.
