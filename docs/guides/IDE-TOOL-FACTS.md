# Canonical IDE tool facts

Keeper tool-result rows in `<base-path>/.masc/tool_calls/` own current tool
facts. The post-tool owner mints the canonical execution ID, captures immutable
repository attribution and the physical turn reference, and synchronously
commits them in the same row before invoking later observers. A failed required
commit propagates; queue admission and observation counters cannot acknowledge
the fact instead.

`GET /api/v1/ide/events` queries these actual rows through the existing disposable
read index. Codebase and optional Keeper filters precede pagination. Reading
never re-resolves Git or derives repository identity from a directory name.
The public `event_id` is the actual execution ID and `turn_id` is its captured
physical turn reference. Reopening the journal or rebuilding its index retains
those identities. The endpoint keeps its existing explicit workspace/codebase
scope and limit/offset page contract.

Invalid observation metadata or ambiguous execution identity produces HTTP 503
with code `tool_activity_unavailable`, rather than an empty successful page.
Raw index/storage details and private attribution-failure payloads are absent
from the public response. Pathless and explicitly unaddressed observations stay
in their canonical Keeper rows; they are not addressed IDE events.

The former `.masc-ide/by-url/*/tool_events.jsonl` copy, its bounded writer queue
and capacity-refusal metrics are retired. Neither full-queue rejection nor a
stalled duplicate writer can discard a newly committed work fact. There is no
new sidecar, replay ledger, in-memory work backlog, timeout or admission limit.
The transient neutral observation callback remains a separate observer, not
the persistence acknowledgement or the IDE read authority.

This is a source format cut. Earlier rows without producer-supplied immutable
attribution remain in the tool-result journal but cannot be assigned a guessed
repository address. Existing duplicate IDE files are left untouched and are
not read or migrated. No runtime data is reset. The old IDE `turn` kind had no
production producer; actual turn/activity facts remain in their existing
turn-record/activity owners and UI feed. The IDE event API accepts `tool` or
`all` and its current frontend requires canonical execution identity.

Primary-journal retention still applies. A successful append/read is not a
claim of fsync, power-loss recovery, provider execution, installed deployment,
or a live operator-visible feature. These require their own evidence.
