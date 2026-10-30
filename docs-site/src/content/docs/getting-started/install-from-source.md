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
- **OCaml** 5.5.1, with `opam`
- **Node.js** 22+ (only for the web dashboard)
- **Native libraries** (gmp, OpenSSL, zstd, SQLite, libpq, libev, libffi, zlib,
  ncurses, and a `protoc` that supports proto3 `optional`): the package lists per OS are in the
  [README](https://github.com/jeong-sik/masc#from-source)

## 1. Clone and install dependencies

```bash
git clone https://github.com/jeong-sik/masc.git
cd masc

# Create a local OCaml switch without resolving MASC's deps yet
opam switch create . ocaml-base-compiler.5.5.1 --no-install
eval "$(opam env)"

# Pin and install the OCaml dependencies at the versions CI uses
scripts/opam-pin-external-deps.sh
opam install ./masc.opam --deps-only --locked
```

## 2. Start the workspace server

`./quickstart.sh` initializes a `.masc/` workspace under `~/masc-quickstart`, writes the MCP bearer token to `.masc/config/mcp-client.env`, and starts the server. It starts no Keeper by default and needs no API key unless `--team classic` is passed:

```bash
./quickstart.sh
```

Endpoints on startup:

- **MCP endpoint**: `http://127.0.0.1:8935/mcp`
- **Dashboard (experimental)**: `http://127.0.0.1:8935/dashboard/`
- **Health check**: `curl http://127.0.0.1:8935/health`

## 3. Build and open the server & Terminal UI manually

To build both the server (`bin/main_eio.exe`) and the TUI (`bin/masc_tui.exe`) directly from the checkout:

```bash
dune build bin/main_eio.exe bin/masc_tui.exe
./_build/default/bin/masc_tui.exe --base-path ~/masc-quickstart
```

The keys and surfaces match the prebuilt binary — see the
[Terminal UI Guide](/guides/tui/).

## 4. Enable autonomous Keepers (optional)

As with the prebuilt install, Keepers need a model runtime and a command sandbox.
Install the source executables and their companions together before using the
`masc` command. Keep the same workspace used by quickstart above:

```bash
scripts/install-local-build.sh --base-path "$HOME/masc-quickstart"
"$HOME/.local/bin/masc" setup --base-path "$HOME/masc-quickstart"
# Or start the server directly once configured:
"$HOME/.local/bin/masc" start --base-path "$HOME/masc-quickstart"
```

The install script builds and installs the server, TUI, browser host and
deployment preflight tools in `~/.local/bin`. Use your chosen binary directory
if you pass `--prefix`. Setup helps configure model access and the selected
sandbox, then opens the TUI. For a browser dashboard, also follow the dashboard
build in the [README](https://github.com/jeong-sik/masc#from-source).

See [Local Models](/runbooks/llama-server/) for the no-key option and
[Docker Sandbox](/runbooks/sandbox/) for the sandbox requirement.
