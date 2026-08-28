---
rfc: "claude-setting-sources-opt-in"
title: "Claude Code settings layers as a keeper-profile opt-in"
status: Implemented
created: 2026-08-28
updated: 2026-08-28
author: vincent
supersedes: []
superseded_by: null
related: ["skills-as-tools"]
---

# Claude Code settings layers as a keeper-profile opt-in

## 1. Problem

The Claude Code lane hard-codes `--setting-sources=` (no layer at all) in the
argv builder. That one token turns off every disk-level capability of the
installed CLI at once: skills, hooks, subagents, and CLAUDE.md never load, on
every keeper, with no way to opt in. Of the three official-client lanes it is
the narrowest settings surface — codex passes `CODEX_HOME` through its
environment allowlist, and antigravity writes its own isolated
`settings.json` — so "run the native CLI at full power" fails first on this
lane.

The blanket-off stance was right as a default: a loaded settings layer can
carry hooks and skills, which are code the CLI executes inside the vendor
loop, outside the MASC approval gate. The problem is only that the default
was also the ceiling.

## 2. Decision

Expose the layers as a keeper-profile declaration with a closed vocabulary
and an admission bar, keeping the current behaviour as the default:

```toml
[keeper.tools]
claude-setting-sources = ["project"]   # any of: user, project, local
```

- **Closed variant** (`Runtime_native_tools.claude_setting_source`):
  `user | project | local`. A typo fails the profile load; it cannot
  silently select no layer. Duplicates are rejected.
- **Default `[]`** everywhere: absent declaration renders the same
  `--setting-sources=` byte-for-byte as before this RFC.
- **Admission = the RFC-0390 bar**: a non-empty list is admitted only for
  keepers whose tool-approval mode is `yolo`, for the same reason
  `native = "full"` is — the loaded code runs outside the approval gate.
  Under `auto` the declaration degrades to `[]` for the turn with a warn
  log, mirroring `resolve_native_posture` (degrade-not-fail: the approval
  mode is turn state an operator can flip mid-run). Profile load failures
  stay fail-closed.
- **Rendering**: `--setting-sources=user,project` (declaration order),
  owned by `Runtime_native_tools.claude_setting_sources_arg` so the argv
  builder and any future consumer share one spelling.

## 3. What this deliberately does not change

- The in-process MCP contract: `--mcp-config` still carries only the `masc`
  SDK server, `--strict-mcp-config` stays, and the initialize control
  request still sends `hooks: null` for SDK-level hooks. A `project` layer
  may declare CLI-file hooks; admitting that is exactly what the yolo bar
  is for.
- `--permission-mode dontAsk` and the credential-scrubbed environment
  allowlist stay as they are.
- Codex and antigravity lanes: their settings surfaces are already
  declarative in their own idioms.

## 4. Trade-offs

- A yolo keeper with `["user"]` trusts the operator's host-level
  `~/.claude` wholesale. That is the operator's call to make per keeper,
  which is why the knob is profile-scoped and not provider- or
  fleet-scoped.
- Degrade-with-log (rather than refuse-the-turn) means a keeper flipped
  from yolo to auto keeps running with fewer capabilities instead of
  stalling; the cost is that the operator must read the log line to learn
  why a skill stopped loading. This mirrors the existing native-posture
  choice so there is one behaviour to learn.

## 5. Verification

- Profile parsing: valid layers parse in order; a typo and a duplicate
  fail the load naming the key; absent stays `None`
  (`test_keeper_toml.ml`).
- Admission: empty passes under `auto`; non-empty refuses under `auto`
  naming the yolo requirement and passes under `yolo`
  (`test_keeper_official_client_host.ml`, mutation-checked).
- Argv: `[]` renders the bare historical token; a declared list renders
  comma-joined and drops the bare token (`test_runtime_claude_code.ml`).
