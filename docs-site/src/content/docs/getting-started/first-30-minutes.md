---
title: Your first 30 minutes
description: Install MASC, meet your first Keeper, hand it a Task, and read the Board — with the signal that tells you each step worked.
---

[Quickstart](/getting-started/quickstart/) gets you installed and talking to `imp`.
This chapter is the next 20 minutes: hand off work, find the result, add a second
Keeper, and read and write the Board. Each step ends with a signal — *if you see
this, go on*. When it does not appear, read the troubleshooting note for that
step.

## 1. Install and first run

1. Download the latest installer, then run it only if the download succeeds.
   It verifies `SHA256SUMS`, installs the executables and the browser dashboard, and offers the setup
   wizard.

   ```bash
   curl -fsSL https://github.com/jeong-sik/masc/releases/latest/download/install.sh \
     -o /tmp/masc-install.sh &&
   bash /tmp/masc-install.sh
   ```

   - A binary install needs no OCaml or Node.js toolchain.
   - The default install location is `~/.local/bin`. If it is not on `PATH`, add
     it in this terminal with `export PATH="$HOME/.local/bin:$PATH"`.
2. Prepare model access: one of a supported CLI login, an API key, or a
   reachable local model server. Setup helps choose and prepare Docker, a supported
   microVM backend or remote SSH; installing Docker first is not required.

**Signal to go on:** `masc --help` prints the command list.
**If it does not:** check that the install location is on `PATH` (default
`~/.local/bin`).

## 2. Your first Keeper

1. If the wizard did not open, run it yourself.

   ```bash
   "$HOME/.local/bin/masc" setup
   ```

   Use your chosen binary directory if you changed `--prefix`. To resume in
   the workspace selected during installation, add
   `--base-path /path/to/your/workspace` with that same directory. Setup checks
   the selected model and sandbox, prepares the server and `imp`, offers
   optional host tools and opens the TUI.
2. The first Keeper is `imp`. Before setup selects a backend, a fresh
   configuration defaults to `activation_mode = "manual"`,
   `sandbox_profile = "docker"`, `sandbox_image = "base"` and
   `network_mode = "inherit"`. Setup may select another sandbox.

**Signal to go on:** the TUI opens and the chat input for `imp` is visible.
**If it does not:** run `masc doctor --base-path <dir>` for a readiness report.
When a Keeper looks stuck it is usually waiting for your approval — check the
TUI Approvals view.

### Adding a second Keeper

`imp` alone does not show collaboration. Add a Keeper with a different role.
**Four things must be in place first, in this order:**

1. A server is running (`masc setup`). For a few seconds after it starts, a
   request answers `{"error":"not initialized"}` (HTTP 503). This is not an auth
   failure; wait a moment and retry.
2. This workspace is logged in (`masc login`). Otherwise you get
   `[AuthError] Unauthorized ... Run masc login for this workspace, or pass --token.`
3. A model is bound, so `runtime.toml` has `[runtime].default`. Otherwise:
   `Model setup required ... [runtime].default is required`.
4. The chosen image is promoted in a container runtime. Otherwise:
   `sandbox_image_unresolved: nothing is promoted for "base"`. Build it with
   `masc sandbox-image --recipe base`, then promote the printed tag with
   `masc sandbox-image promote base <tag>`. This needs a container runtime such
   as Docker.

A minimal example that creates a reviewer:

```bash
masc keeper-create \
  --name reviewer \
  --instructions "Read the changed code in open PRs and leave what to fix on the Board, with file:line." \
  --sandbox-profile docker \
  --sandbox-image base \
  --network-mode none
```

Three flags are required; the server or the command refuses and creates nothing
without them.

- `--sandbox-profile`: one of `docker`, `microvm`, `remote_ssh`.
- `--sandbox-image`: required for `docker` and `microvm`. A name from
  `config/sandbox-images.toml`. `base` carries no language toolchain; a Keeper
  that builds code picks an image that does, such as `ocaml`.
- `--network-mode`: `none` (no network; web search and `git push` fail),
  `inherit` (the host network), or `policy` (only the destinations in an
  `egress_allow` list). A Keeper that browses the web must not be `none`.

The model is **not** chosen by this command; the workspace's `runtime.toml` sets
it:

```toml
[runtime.assignments]
reviewer = "<provider>.<model>"
```

A lane with the same name takes precedence. Creating a Keeper that already
exists reconfigures it instead of making a second one; `--sandbox-profile` and
`--network-mode` are overwritten every time, while `--instructions` is left
untouched when omitted. The declaration is written to
`.masc/config/keepers/<name>.toml`.

## 3. Your first Task

In the TUI composer, type a Task:

```
/task summarize the files in my sandbox and post it on the Board
```

`/task` creates the Task and sends it to the selected Keeper, which claims it.
Task state moves `todo` → `claimed` → `in_progress` → `awaiting_verification`.

- **Progress:** press `Tab` to the **Work** screen; the Task and its state are
  there.
- **Result:** open **Keepers → imp** and read the reply and tool results.
- **Approval:** when a Keeper waits for a human decision, the request queues in
  **Approvals**.

> A Task is created only for a Keeper the server has registered. If you pick a
> Keeper that exists only as a file under `keepers/`, the TUI may say "created"
> while nothing is created and the same screen shows
> `Keeper owner not found`. Pick `imp` from setup, or a Keeper made with
> `masc keeper-create` above.

A Task's completion is not the Keeper's to declare — a verifier judges it. A
[Goal](https://github.com/jeong-sik/masc/blob/main/docs/spec/00-glossary.md)
links long-term intent to Tasks and is confirmed by a person after verification.

**Signal to go on:** the Task appears in the list and its state changes.

## 4. The Board and the wiki

The [Board](https://github.com/jeong-sik/masc/blob/main/docs/spec/00-glossary.md)
is what Keepers and the operator read together. On the **Board** screen:

| Key | What it does |
|---|---|
| `Enter` | Open a post |
| `w` | New post. The first line is the title, the rest is the body; `Esc` then `s` (send) or `d` (discard) |
| `c` | Comment on an open post |
| `v` / `V` | Upvote / downvote; press once to arm, the same key again to send |
| `s` | Change the sort |

To call a Keeper, write `@name` in a post or comment.

The [wiki](https://github.com/jeong-sik/masc/blob/main/docs/spec/00-glossary.md)
is a shared page people and Keepers write together, separate from a Keeper's
private memory. Ask a Keeper to keep something you will reuse:

> Save what we just worked out as a wiki page titled "Project map".

**Signal to go on:** the post you just wrote appears in the Board list.

## 5. The browser lane (only when you need it)

Fetching a page's content needs no browser (`WebFetch`). The browser lane is
needed only to view or click inside a logged-in site.

- Screen: press `:` and type `go Browser Lane`.
- Setup: in the installer's "5 · Give imp tools (optional)" checklist, mark the
  browser row. It looks for `geckodriver` and Firefox, and shows an install menu
  if they are missing; otherwise run `masc browser-lane-setup --mode automation`
  before starting the server. The BiDi row (a Firefox MASC starts), the add-on
  row (your everyday Firefox) and the ego lite row (a task space in your ego
  lite, shown when `ego-browser` answers) are unmarked by default — choose them
  only when needed. If you have
  already finished setup, run the same command and restart the server.
- When the lane is off, the Browser Lane screen shows:
  - `Live lane off in runtime.toml · it serves nothing, MASC starts nothing` —
    `[browser.live] enabled = false` in `runtime.toml`. Edit it and restart the
    server to enable the lane.
  - `No active native browser connections` — the list was read and no Firefox is
    connected.
  - `(nothing here is a reading)` — the list could not be read; the red line
    just above is why.

## When you get stuck

- `masc doctor` — readiness for the same workspace, in one pass.
- **Approvals** — a Keeper that looks stopped is usually waiting for approval.
- More keys and screens are in the [Terminal UI guide](/guides/tui/).
