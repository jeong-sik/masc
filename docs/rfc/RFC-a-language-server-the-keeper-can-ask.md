---
rfc: "a-language-server-the-keeper-can-ask"
title: "A language server the Keeper can ask"
status: Draft
created: 2026-08-25
updated: 2026-08-25
author: vincent
supersedes: []
superseded_by: null
related: ["spawn-a-process-that-outlives-the-call"]
---

# A language server the Keeper can ask

## 1. Problem

A language server is running in this repository right now. A Keeper cannot
reach it.

**1.1 It works.** Measured 2026-08-25 by opening the proxy and sending one
request:

```
GET /api/v1/ide/lsp        ->  HTTP/1.1 101 Switching Protocols
initialize (langId: ocaml) ->  {"jsonrpc":"2.0","id":1,"result":{"capabilities":
                                 {"textDocumentSync":2,
                                  "completionProvider":{"resolveProvider":true},
                                  "hoverProvider":...
```

`ocamllsp` starts and answers. This is not a proxy that accepts a socket and
stalls; the language server is on the other end of it.

**1.2 Only the dashboard can talk to it.** `server_ide_lsp_proxy.ml` registers
one endpoint, `/api/v1/ide/lsp`, and the client is
`dashboard/src/components/ide/ide-lsp-client.ts`. Of the 126 tool definitions
under `config/tools/`, none names a symbol, a reference, or a definition. A
Keeper has no way to ask.

**1.3 So Keepers read code as text.** Over 25 days of recorded tool calls:

```
Grep        8,193 calls   3,303 s
Read       14,015 calls
Execute    33,589 calls
```

Classifying the 8,187 `Grep` calls that carried a pattern:

```
  other (regex, prose, path)     5,943   72.6%
  bare identifier                1,826   22.3%
  constructor / module             261    3.2%
  definition (let name)            138    1.7%
  qualified symbol (Mod.fn)         19    0.2%
```

About 27% -- 2,244 calls -- name a thing a language server answers exactly.
The rest are regexes, prose and paths, which it does not.

The cost is not mainly seconds. `rg 'selectedChild'` returns comments,
strings, and same-named bindings in unrelated modules; `textDocument/references`
returns that symbol's references. The Keeper then reads the difference.

**1.4 The languages line up, except one.** Of the files Keepers name in
`Grep` and `Read`:

```
  .ml    60.4%      .mli    5.4%      .ts    9.1%
```

And of the five servers `lsp_process_manager` maps, this host has:

```
  ocamllsp                     installed
  rust-analyzer                installed
  typescript-language-server   not installed
  pylsp                        not installed
  gopls                        not installed
```

The language Keepers touch most already has its server. The second one has no
server on this host, which §4 takes as a reason to scope rather than to wait.

**1.5 This was tried once, in the other direction.** `LspCall` was a gRPC rpc
whose proto comment described it as the IDE dashboard's route to hover,
codeLens and inlayHint "over the gRPC-web transport instead of a separate
WebSocket". It was removed (#28773) with:

> LspCall has no caller anywhere. (…) That client was never built; the
> dashboard's LSP surface is the WebSocket proxy at `/api/v1/ide/lsp`.

It was a second transport for the client that already had one. It carried a
defect too, which §3.2 treats as the design's first constraint rather than as
history.

## 2. Boundary & invariants

- The Keeper asks; it does not manage. Starting, reusing and stopping a
  language server stays inside the process manager.
- A question has one answer or one typed error. "No server for this language"
  and "the server has not indexed yet" are different answers and neither is an
  empty list.
- No new transport. The proxy exists and works; a Keeper tool calls the same
  process manager the proxy calls.
- The Keeper's sandbox bounds the question. A path outside `allowed_paths` is
  refused before a language server sees it.

## 3. Design

### 3.1 Three questions, not a protocol

`textDocument/references`, `textDocument/definition`, `textDocument/hover`.
Those three cover the 27% in §1.3: where is this used, where does it come
from, what is its type.

Not completion (no one is typing), not codeLens or inlayHint (nothing is being
drawn), not rename (a write, and `tool_edit_file` already owns writes).

### 3.2 A server belongs to a workspace, not to a language

This is what `LspCall` got wrong, and the removal commit says so:

> the server-scoped process cache is keyed on lang_id alone
> (`Hashtbl.find_opt lsp_processes lang_id`) while the process is spawned with
> the first caller's `~workspace_root`, so every later request for the same
> language silently reuses a language server rooted in someone else's
> workspace

Keepers make that worse, not better: each has its own sandbox root, and they
run concurrently. The cache key is `(lang_id, workspace_root)`. A Keeper
asking about its own tree cannot be handed a server rooted in another's.

The process manager is not what needs fixing. `Lsp_process_manager.spawn`
already takes `~workspace_root`, and the proxy's own cache is inside
`conn_state`, one table per connection, with that connection's root beside it
-- so keying on `lang_id` there is correct. What `LspCall` added was a
*server-scoped* table over a per-caller root. A Keeper surface is server-scoped
by nature, which is why it carries the root in the key from the start.

One thing the proxy does that a Keeper surface should not copy:
`conn_state.workspace_root` is a `ref`, reassigned when `initialize` arrives,
while any language server already cached still holds the root it was spawned
with. LSP sends `initialize` once per connection, so the proxy is within the
protocol; a Keeper surface has no handshake to rely on and so must not depend
on the root being fixed after the fact.

### 3.3 What "no server" answers

`command_for_lang` returns `None` for an unmapped language, and a mapped
command may not be installed -- on this host three of five are not. Both are
answers the caller can act on, so both are typed:

- `Unsupported_language of string` -- nothing is mapped
- `Server_unavailable of { lang_id : string; command : string }` -- mapped and
  not on PATH

Neither is an empty result list. An empty list means the language server
looked and found nothing, which is a different fact and the one a Keeper would
otherwise mistake for the other two.

### 3.4 Position, not offset

The request carries a file path and a line/character position, the way LSP
does. Deriving a position from a regex match inside the tool would put a
second, weaker parser next to the language server, which is the thing this
replaces.

The Keeper gets the position from `Grep` or from a file it has read. That is
the honest sequence: find the line by text, then ask the language server about
that line.

## 4. Rejected alternatives

**Install the missing servers first.** `.ts` is 9.1% of what Keepers touch and
`typescript-language-server` is not on this host. Waiting for it makes the
whole surface depend on someone's PATH; §3.3 makes its absence a typed answer
instead, and the OCaml 65.8% is served on day one.

**Go through gRPC.** That is #28773 rebuilt. The proxy is already the thing
that works, and gRPC's own subscribers have been zero for its whole life
(#30370).

**Give the Keeper the raw LSP socket.** Then the Keeper owns the JSON-RPC
lifecycle, the initialize handshake, and the document-open bookkeeping. Three
questions do not need a protocol client.

**Ship LSAP instead.** [LSAP](https://github.com/lsp-client/LSAP) argues for
exactly this -- one semantic request instead of a chain of LSP calls -- but as
of 2026-08 it specifies no transport, no method names, and no wire format.
Worth tracking; not yet a thing to implement against.

## 5. Test plan

- **Sandbox:** a path outside `allowed_paths` is refused before any language
  server is consulted, and the refusal names the path.
- **Workspace keying:** two callers with different `workspace_root` and the
  same `lang_id` do not share a server. Asserted on the process the manager
  hands back, not on a log line.
- **Unsupported vs unavailable:** an unmapped language answers
  `Unsupported_language`; a mapped language whose command is not on PATH
  answers `Server_unavailable` naming the command. Neither answers `[]`.
- **Found nothing:** a valid position with no references answers an empty list,
  distinct from both errors above.
- **Against ocamllsp:** references for a symbol with a known count in this
  tree returns that count. The one test that needs a real server, skipped by
  the same PATH check the tool uses, so a host without `ocamllsp` runs the
  rest.

## 6. Verification (closed) & open questions

Closed by measurement, 2026-08-25:

- The proxy answers `initialize` for `ocaml` with capabilities.
- 126 tool definitions, none for code navigation.
- `Grep`: 8,193 calls, 3,303 s, ~27% naming a symbol.
- `.ml`/`.mli` 65.8%, `.ts` 9.1% of files named.
- `ocamllsp` and `rust-analyzer` present; three of five mapped commands absent.

Open:

- **Does a Keeper ask better than it greps?** The 27% is what a language
  server *could* answer, not what a Keeper *would* ask. The tool records its
  own calls, so the same corpus answers this a month after it ships; nothing
  here should be widened before it does.
- **Who stops the server?** The proxy's servers live with a dashboard
  connection. A Keeper's question is shorter than a turn. Whether a Keeper's
  server is turn-scoped, like `Spawn_turn_registry`, or shared per workspace
  across turns, is the same question RFC
  spawn-a-process-that-outlives-the-call §6 answered for spawn, and it needs
  its own evidence here.

## 7. Non-goals / future

- Not an editor. No completion, no formatting, no code actions.
- Not a writer. Rename and code actions change files; `tool_edit_file` owns
  that boundary.
- No index of its own. The language server holds the index; this surface asks
  it questions.

## 8. Workaround self-check (CLAUDE.md bar)

- **Telemetry-as-fix?** No. It answers questions rather than counting them.
- **String classifier?** It removes one: the 27% currently answered by regex
  gets a typed answer from a parser that knows the language.
- **N-of-M?** Three methods are the whole surface, chosen by measurement, not
  a first slice of a bigger list. §7 says what is not coming.
- **Cap / cooldown / dedup / repair?** None. §3.3's two errors are typed
  dispositions, not suppression.
