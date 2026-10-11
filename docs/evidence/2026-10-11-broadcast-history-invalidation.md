# Broadcast invalidates in-flight history authority

Reproduced failure: an older forced history request remained eligible to merge after a newer keeper_chat_appended notification, until the debounced replacement request began. A deferred response resolved in that interval and replaced the current transcript with stale rows.

Fix: admitted notifications immediately invalidate the existing request token. The forced replacement fetch remains debounced; only its token may publish history/error or settle hydration. No snapshot text inference or new timing limit is introduced.

Validation: actual action fixture supplies deferred responses and fake timers. Both superseded success and failure retain current history/no stale error, leave busy state until replacement, and merge the replacement with busy state cleared. Full keeper-actions suite passed 75 tests; TypeScript noEmit and diff checks passed. Source review is distinct from GitHub approval. Actual network ordering, provider runtime and screenshots remain unverified.
