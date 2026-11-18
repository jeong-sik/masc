# Declared readers for retained host media

Retained host tool results carry attachment identities even when the model
receives only text. This change connects their preparation to the declared
media reader, the original request store and Gate approval replay.

Turn setup captures the reader declarations once and supplies the existing
turn sandbox factory. The producer uses the existing SSH or microVM endpoint
lifecycle, prepares a single bound stdio request, verifies the complete source
bytes and retains the original and approval intent before requesting an effect.
It does not construct a replacement sandbox factory or claim permission from a
reader's MCP annotations.

Every observation starts with the original inventory, before reader selection,
built-in memo or cache lookup. A retained reply can be interpreted without
launching its reader again. An unreadable original, ambiguous approval or
unknown invocation does not become an empty inventory. Multiple unresolved
originals retain their separate IDs and dispositions. Only an inventory that
permits fresh work reaches declaration selection: no match uses the built-in
reader, one match selects it, and overlap remains an explicit error.

The MarkItDown adapter requires the declared `convert_to_markdown` tool's
string `uri` contract. The actual MCP channel initializes, reads its tool
catalog and calls it with the original's complete captured arguments. The full
SDK result is offered for retention before channel cleanup; interpretation
requires a retained reply. Conversion
accepts nonempty text content and preserves its order; a reported tool error,
invalid shape or nontext result remains an explicit failure. The existing SDK
catalog operation reads one page; this change is not generic paginated MCP
discovery.

Approval replay requires the same unconsumed approval ID and an actual one-shot
grant. The current declaration and prepared launch must still match the
original. A consumed grant never falls back to a changed Always-allow policy.
Recovery reads the original-owned response and transport evidence without a
new RPC. Persistence or reconciliation errors leave replay evidence repairable
instead of permanently recording an unknown result that hides a readable reply.

The response and transport result remain separate. A known text reply can be
used while process cleanup is unknown; that reading is not proof of successful
process exit. Full SDK and transport blobs remain private retained artifacts.
The public replay output carries the reading and a small typed transport
summary, excluding raw shim diagnostics, syscall lists and SDK metadata.

Within a walk, a proven no-send attempt is not invoked again. A later walk can
admit a new original through fresh Gate authority. Denial, unknown effects and
unconfirmed publication do not authorize another invocation. A retained
original whose initial publication failed is reconciled under the same
identity while its captured data remains in the walk.

After a normal session return, the producer finishes retention of the same held reply
and transport values without another RPC. If their bytes or links still cannot
be stored, recovery is not guaranteed after that replay call or process ends.
The missing durable response remains unknown; it cannot justify resending the
request.

The retained-host carrier reads on its owning fiber before encoding or sizing.
It then freezes the exact receipt snapshot and output for that run; retries
do not invoke the reader again or acknowledge the host's original result.
Early history projections use the declared reader's observation port. Agent Core
requests prepare declared readings only after selecting their carried history,
then reuse those outcomes during prefix inspection; see
[selected-history media preparation](2026-11-17-farm-selected-history-media.md).
Official-client history projection continues using that observation port;
existing built-in extraction can still perform I/O.

Validation is source review and full-file syntax parsing. Authored cases cover
original inventory precedence, explicit observation/effect ports, mixed pending
identities, carrier reuse, actual approval consumption and consumed-result
recovery. Test execution and type-checking are not claimed. Actual deployed
MarkItDown, valid DOCX extraction and SSH/microVM end-to-end behavior still need
execution evidence; no runtime installation accompanies this source change.
