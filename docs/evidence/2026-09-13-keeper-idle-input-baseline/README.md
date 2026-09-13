# Installed idle-turn input baseline

The owned 851f412 runtime served exact turn records for exhibit-editor turns
501 and 502 and the resolved provider input for turn 502. The input capture ID
joins to the latter raw trace worker ID, and both report a 381,108-byte request.
Both traces finish normally, contain no tool execution, and return substantially
similar waiting-state reports. This is a two-turn observation, not a claim that
all autonomous turns are idle or that the underlying Goal assertions are true.

Both requests include 110,254 bytes of unchanged Memory OS recall, 106,315 bytes
of historical tool-use content and 66,751 bytes of tool schemas. Turn 502 reports
118,501 input tokens, 118,464 cache-read tokens, and 1,039 output tokens. Cache
accounting and repeated context size are separate measurements. The resolved
snapshot reports Pre_dispatch_serialization; response completion is established
separately by its linked raw trace and TurnRecord.

Source inspection of keeper_memory_os_recall.ml and keeper_run_tools_hooks.ml
confirms that first-round recall deliberately renders every persisted current
fact. The workspace curator currently supplies an unverified proposal, not an
authorized replacement for this personal memory. Blindly truncating recall or
promoting that proposal would sacrifice continuity rather than demonstrate an
improvement. The next comparison must measure context relevance and repeated
reports together with accurate use of prior decisions, using the same records
and provider-input surface. No runtime policy was changed for this baseline.

The UTC-day report uses scripts/analysis/provider-token-baseline.py and documents
its projection and non-atomic snapshot limits. Full provider text remains in the
private operator response named by audit.json; its hash, message identities and
wire observation are archived without reproducing its historical tool bodies.
