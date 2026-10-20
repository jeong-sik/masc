# TUI first canonical-page delivery

Cold chat entry requests the existing canonical physical history page in parallel
with aggregate history and the memory journal. The first page can populate the
conversation before the aggregate read returns. Received history, including an
empty history, does not trigger this extra read on ordinary refreshes.

The page uses the existing strict v2 decoder, fixed existing page window and
opaque cursor. It has its own typed atomic result slot in the same refresh owner.
The finite owned-result drain retains the original workspace/read epoch, Keeper
and generation. The page slot stays pending through offering and releases only
at UI admission or explicit retirement; unrequested page slots start settled.
GET pre/post identity checks have their own contact sequence. Source decoding
still uses the existing shared CPU worker.

The page and aggregate can contain different raw/role-filtered windows. Keep the
identity union, preferring an already received aggregate copy. A page response
owns its physical cursor and has-more observation; aggregate success does not
clear a page failure or invent its cursor. First-page failure retains other rows
and is not a cursor-stale verdict against a separate successful aggregate.
An explicit/resumed older-page read retires any initial-page admission before
it starts, so a delayed initial page cannot rewind the later cursor. This retires
UI authority, not the already running worker.

While the initial page is pending, the existing paging loading state prevents
normal duplicate older-page requests. Workspace suspension distinguishes automatic
cold-page preparation from explicit older-page demand using that actual page
slot. Only explicit demand is stored in the older-page resume slot. Automatic
preparation can be re-created by the existing eligible history dispatch. Recovery
while scrolled does not force an extra history request: cached rows remain and
explicit refresh/paging or later eligible dispatch acquires fresh authority.

## Evidence and limits

```sh
python3 docs/evidence/2026-10-20-tui-history-independent/flow_probe.py
```

The existing extracted-flow probe was extended for the typed page slot. It
executes the production request module, launch body, source-view setter, owned
collection and result-application arms with real Eio fibers/promises. All six
arrival orders of page/aggregate/memory pass; page-only rows appear before an
unreleased aggregate, the aggregate copy wins shared identities, distinct windows
and canonical rows with Memory display role survive, and the cursor is preserved.
Two failure orders preserve the page failure through aggregate success. An already
offered initial page is rejected after explicit retirement. Received empty history
requests no initial page. Existing eight two-source arrival/system-role/empty-memory
cases, cold forced refresh, stale owner/generation/Keeper/workspace and refused
launch cases continue passing.

HTTP, workspace checks/admission, row projection/merge, state types and workspace
job registration are fixtures in this probe. Its success does not establish actual
network/renderer latency, full native linkage or real workspace cancellation.
Native fixtures add real cold-vs-explicit suspension and retirement decisions;
they were added/updated and syntax-parsed, not executed. Changed ML/MLI syntax,
constructor/interface comparison and diff whitespace were checked. No local Dune
build, native suite, CI wait, installation or visible TUI speed result is claimed.

Independent draft review found that aggregate success erased a prior page failure;
this was fixed by letting only a successful physical-page read clear that source
failure. Review also checked retirement, all direct async constructor consumers
and the cold/explicit suspension distinction. Final exact-head review follows
publication.
