# Overlapping approval inventory publication

Base: 8a37daaaa816fee95ef88356efd427fe64defe6b.

Actual fetch boundary reproduction: two same-account listings overlap. The newer listing returns no pending waits, then the older listing returns a finished wait. Old behavior resurrected that wait: 1 failed / 11 passed, /tmp/chat-tool-approval-request-red.log.

Hydration now publishes through one immutable current request owner containing authentication revision. Starting a newer global inventory query retires the older publication owner, and each row checks both that owner and authentication. The inventory endpoint lists all Keepers, so ownership is global rather than selected-Keeper-specific. Existing stream rows remain authoritative for gap filling.

Validation: 12 actual API/fetch and signals tests passed, /tmp/chat-tool-approval-request-green.log. TypeScript noEmit exit 0, /tmp/chat-tool-approval-request-types.log. No CI or runtime/screenshot evidence claimed.

Remaining: a stream settlement racing a single already captured listing can still resurrect a gap; inventory has no server event frontier. Existing rows are not globally partitioned by account. Backend wait incarnation, late stream settlement and publication/review/installation remain unfinished.
