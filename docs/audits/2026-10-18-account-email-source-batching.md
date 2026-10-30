# Account email inventories: one observation per selected client/file

Source baseline: `10df3c4bf9a96ec3db6f37cbb641cb923537ca6b` (#43668).

## As-Is / To-Be

| Boundary | Baseline | This layer |
| --- | --- | --- |
| Multiple provider rows selecting the same client login file | Each row independently stats/reads/interprets that file | One selected-source observation reused within the inventory |
| Selected login-content observations per response | N file-selecting providers | U distinct `(client interpretation, exact resolved path)` keys |
| A login changes while rows are being read | Later aliases may show another file observation | Aliases share the first observation for that response |
| Later refresh / another request | Reads the current file | Still re-resolves and rereads; no process cache |
| Missing, malformed or unreported email | Separate attempts for aliases | One typed missing result shared, separate provider rows retained |
| Same path, different client format | Independent interpretation | Remains independent; path alone cannot merge sources |
| Environment credential / no client account | Distinct missing row / absent row | Same distinction, decided before any login reader callback |
| Inherited source changes during login reading | Later rows resolve against changed environment | All source selections completed before the first login-content read |
| Reader cancellation/exception | Propagates at the existing boundary | Propagates without alias retry or conversion into empty rows |

N and U describe selected login-source observation attempts, not all providers,
all filesystem calls, measured latency or total CPU work. U equals N when no
sources share the exact typed key. Existing path selection and legacy-file
existence checks remain per provider; symlink/path aliases are not merged using
inode heuristics. Distinct keys remain sequential through the existing IO
boundary; this layer does not claim new parallelism.

## Scope and ownership

The raw runtime config response calls `Runtime_account_email.inventory_json`
for its exact parsed config. Setup/Usage account-email and inventory paths use
the same producer. Batching is implemented there, so these callers keep their
wire shape and inherit one response-local observation per selected client/file.
The single-provider `of_provider` API still selects and reads one current source.

Closed internal source variants distinguish Codex auth, Claude account, Muse
auth and Google OAuth interpretations. Provider IDs and email text are never
cache identity. Source selection retains existing explicit/inherited-home,
legacy Claude file and environment-credential rules. An immutable local map
retains successes and typed missing results only until the response finishes.
There is no global cache, timer, work cap or credential/routing/permission knob.
No email or credential contents are logged by the new batching path.

The existing reader keeps its regular-file restriction, IO offload and expected
file-error classification. Unexpected exceptions and Eio cancellation propagate;
a function that entered and raised is never retried for another alias. Frozen
source selections and metadata observations grant no authentication, routing,
quota ownership or task-admission authority. Email remains display text.

## Evidence and remaining work

Five feature scenarios are authored and **unexecuted**: alias consistency during
file rotation plus next-request refresh; shared malformed data with independent
missing/environment/no-account outcomes and recovery; same-path different-client
parsing; inherited source selection frozen before a read effect changes the
client home; cancellation with no alias retry. These use synthetic fixture login
files/read adapters and verify read counts, stored observations and protocol
rows; no TUI wording/layout/snapshot/PTY checks are added.

Only parser-only checks, diff hygiene and changelog validation run. Types, test
execution, independent current-head approval, CI, native/model runs, installation,
restart, runtime, paint and timing remain unverified. No live login/config/prompt
file was read or written as part of this source implementation.

The server raw-config path also separately parses one source for Keeper settings
and Runtime config, and performs synchronous preparation on its HTTP fiber.
Those remain separate follow-up work, requiring preservation of validation,
overlay and original revision semantics. This source-batch layer does not claim
to fix every source of loading or duplicate parsing.

The complete preparation/first-usable-input/readability/visibility/observability,
Ask-to-original-Task-to-useful-work, resource-owned ordinary/nested/dynamic/
effectful Composition, held-job/shared-backend and matched Before/After objective
remains open. Future comparisons must retain failed, cancelled, interrupted and
unfinished observations. No measured speedup or goal completion is claimed.
