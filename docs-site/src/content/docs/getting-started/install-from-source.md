---
title: Build from Source
description: Build the MASC server and Terminal UI from the OCaml source, for contributors and unreleased builds.
---

Most users should install the [prebuilt binary](/getting-started/quickstart/).
Build from source when you are contributing, or when you need a build newer than
the latest [release](https://github.com/jeong-sik/masc/releases). A source build
compiles the OCaml server and dashboard and can take several minutes.

## Prerequisites

- **macOS or Linux**
- **OCaml** 5.5.0, with `opam`
- **Node.js** 22+ (only for the web dashboard)

## 1. Clone and install dependencies

```bash
git clone https://github.com/jeong-sik/masc.git
cd masc

# Pin and install the OCaml dependencies
scripts/opam-pin-external-deps.sh --install
opam install . --deps-only
```

## 2. Start the workspace server

`quickstart.sh` initializes a `.masc/` workspace under `~/masc-quickstart` and
starts the server:

```bash
./quickstart.sh
```

Endpoints on startup:

- **MCP endpoint**: `http://127.0.0.1:8935/mcp`
- **Dashboard**: `http://127.0.0.1:8935/dashboard/`
- **Health check**: `curl http://127.0.0.1:8935/health`

## 3. Open the Terminal UI

Build and run the TUI from the checkout:

```bash
dune build bin/masc_tui.exe
./_build/default/bin/masc_tui.exe --base-path ~/masc-quickstart
```

The keys and surfaces match the prebuilt binary — see the
[Terminal UI Guide](/guides/tui/).

## 4. Enable autonomous Keepers (optional)

As with the prebuilt install, Keepers need a model source and a command sandbox.
Export a provider key (or wire a local model) and start the full supervisor:

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
./start-masc.sh
```

See [Local Models](/runbooks/llama-server/) for the no-key option and
[Docker Sandbox](/runbooks/sandbox/) for the sandbox requirement.
