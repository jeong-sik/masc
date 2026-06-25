---- MODULE RFC0061CacheInvalidationBroadcast ----
\* Boundary spec for RFC-0061: Cache-invalidation broadcast envelope.
\*
\* Runtime truth being modelled (lib/workspace/workspace_broadcast.ml):
\*   - When a broadcasting agent's current_task is terminal,
\*     the original broadcast content is rewritten to a
\*     "[cache_invalidated] ... stale broadcast suppressed" notice.
\*   - Mention tokens are extracted from the *original* content
\*     (via Mention.extract) to drive downstream wake decisions.
\*   - Current code extracts [pre_extract_mention] before any rewrite and uses
\*     the same original-content view for mention dedup.  A dedup skip is a
\*     terminal skip (no message/callback), not a successful delivery with empty
\*     mention tokens.
\*   - SpecBuggy is retained as the historical counterexample: rewrite happens
\*     before mention extraction, the rewritten content contains no @mention
\*     tokens, and downstream wake decisions see mention=None even when the
\*     original message had one.
\*
\* What this spec deliberately abstracts away:
\*   - The actual filesystem / JSON serialization of messages.
\*   - The dedup gate (RFC-0040) — modelled as a non-deterministic terminal
\*     skip.  Safety properties below deliberately exclude [dedup_skipped]
\*     from delivered-message obligations so dedup cannot mask a rewritten
\*     delivery with empty mention tokens.
\*   - The exact regex for Mention.extract — modelled as a boolean
\*     "original_has_mention".
\*
\* Bug Model (CLAUDE.md "TLA+ Bug Model pattern"):
\*   - Spec       (clean): pre_extract_mention runs on original_content
\*     before any rewrite; mention_tokens are preserved.
\*   - SpecBuggy: BroadcastRewriteSwallowsMention rewrites content
\*     *before* mention extraction, so mention_tokens become empty.
\*
\* Expected TLC outcome:
\*   - Clean .cfg:  MentionTokensExtractedBeforeRewrite holds (no error).
\*   - Buggy .cfg: MentionTokensExtractedBeforeRewrite violated
\*     within <= 2 steps.

EXTENDS TLC, Naturals, Sequences

CONSTANTS
    AgentNames,          \* Set of agent names, e.g. {"alice", "bob"}
    MaxRewrites          \* Upper bound on rewrite events per broadcast

ASSUME AgentNamesNonEmpty == AgentNames # {}
ASSUME MaxRewritesPos == MaxRewrites \in Nat /\ MaxRewrites >= 1

VARIABLES
    phase,               \* {"idle", "building", "extracted", "rewritten", "delivered", "dedup_skipped"}
    original_content,    \* the raw content before any rewrite
    current_content,     \* content after rewrites (may differ from original)
    mention_tokens,      \* list of mention targets extracted from content
    rewrites,            \* sequence of rewrite_event labels applied so far
    msg_type,            \* {"broadcast", "cache_invalidated"}
    original_has_mention \* boolean: does original_content contain an @mention?

vars == << phase, original_content, current_content, mention_tokens,
           rewrites, msg_type, original_has_mention >>

PhaseSet == {"idle", "building", "extracted", "rewritten", "delivered", "dedup_skipped"}
MsgTypeSet == {"broadcast", "cache_invalidated"}
RewriteLabelSet == {"cache_invalidation", "dedup_guard", "sanitize"}

(* ── Type invariant ─────────────────────────────────────── *)

TypeOK ==
    /\ phase \in PhaseSet
    /\ original_content \in AgentNames
    /\ current_content \in AgentNames
    /\ mention_tokens \in Seq(AgentNames)
    /\ rewrites \in Seq(RewriteLabelSet)
    /\ msg_type \in MsgTypeSet
    /\ original_has_mention \in BOOLEAN

(* ── Initial state ──────────────────────────────────────── *)

Init ==
    /\ phase = "idle"
    /\ original_content = "none"
    /\ current_content = "none"
    /\ mention_tokens = << >>
    /\ rewrites = << >>
    /\ msg_type = "broadcast"
    /\ original_has_mention = FALSE

(* ── Helpers ────────────────────────────────────────────── *)

MentionFromOriginal ==
    IF original_has_mention
    THEN << original_content >>
    ELSE << >>

(* ── Actions (clean model) ──────────────────────────────── *)

\* A broadcast is initiated with some original content.
\* The agent may or may not have included an @mention.
StartBroadcast(agent, has_mention) ==
    /\ phase = "idle"
    /\ agent \in AgentNames
    /\ has_mention \in BOOLEAN
    /\ phase' = "building"
    /\ original_content' = agent
    /\ current_content' = agent
    /\ original_has_mention' = has_mention
    /\ UNCHANGED << mention_tokens, rewrites, msg_type >>

\* CLEAN: mention extraction happens on the *original* content,
\* before any rewrite.  This preserves the mention token even if
\* a later rewrite replaces the content with a cache-invalidation
\* notice that contains no @mention.
ExtractMentionsClean ==
    /\ phase = "building"
    /\ phase' = "extracted"
    /\ mention_tokens' = MentionFromOriginal
    /\ UNCHANGED << original_content, current_content, rewrites, msg_type,
                    original_has_mention >>

\* A rewrite is applied (e.g. cache invalidation).  The rewrite
\* is stamped in [rewrites] but the original content is preserved.
ApplyRewrite(label) ==
    /\ phase \in {"extracted", "rewritten"}
    /\ label \in RewriteLabelSet
    /\ Len(rewrites) < MaxRewrites
    /\ phase' = "rewritten"
    /\ rewrites' = Append(rewrites, label)
    /\ IF label = "cache_invalidation"
       THEN /\ current_content' = "cache_notice"
            /\ msg_type' = "cache_invalidated"
       ELSE /\ current_content' = current_content
            /\ UNCHANGED msg_type
    /\ UNCHANGED << original_content, mention_tokens, original_has_mention >>

\* The broadcast is delivered.  Subscribers use [original_content]
\* for wake decisions (mention extraction) and [current_content]
\* for UI display.
Deliver ==
    /\ phase \in {"extracted", "rewritten"}
    /\ phase' = "delivered"
    /\ UNCHANGED << original_content, current_content, mention_tokens,
                    rewrites, msg_type, original_has_mention >>

\* Non-deterministic dedup skip (RFC-0040 abstraction).
SkipDedup ==
    /\ phase = "building"
    /\ phase' = "dedup_skipped"
    /\ UNCHANGED << original_content, current_content, mention_tokens,
                    rewrites, msg_type, original_has_mention >>

Next ==
    /\ \E agent \in AgentNames, has_mention \in BOOLEAN :
         StartBroadcast(agent, has_mention)
    \/ ExtractMentionsClean
    \/ \E label \in RewriteLabelSet : ApplyRewrite(label)
    \/ Deliver
    \/ SkipDedup

Spec == Init /\ [][Next]_vars

(* ── Safety invariants ──────────────────────────────────── *)

\* I1: If the original content had a mention and the broadcast proceeded past
\* the sender-side dedup gate, the extracted tokens must be non-empty.  Dedup
\* skip is terminal and intentionally creates no delivered message; every other
\* post-building phase must preserve the original mention before rewrite.
MentionTokensExtractedBeforeRewrite ==
    (phase \in {"extracted", "rewritten", "delivered"} /\ original_has_mention)
        => Len(mention_tokens) > 0

\* I2: Once delivered, the mention tokens are consistent with the
\* original content (not the rewritten content).
DeliveredMentionsConsistent ==
    phase = "delivered" =>
        (original_has_mention <=> Len(mention_tokens) > 0)

\* I3: Rewrites are stamped and bounded.
RewritesBounded ==
    Len(rewrites) <= MaxRewrites

\* Combined safety invariant referenced by the .cfg.
Safety ==
    /\ TypeOK
    /\ MentionTokensExtractedBeforeRewrite
    /\ DeliveredMentionsConsistent
    /\ RewritesBounded

(* ── Bug Model ──────────────────────────────────────────── *)

\* Bug action: rewrite happens *before* mention extraction.
\* This models the historical buggy shape where cache_invalidated rewrite ran
\* before [pre_extract_mention].  The rewritten content ("cache_notice") has no
\* mention, so extraction yields empty.
BroadcastRewriteSwallowsMention ==
    /\ phase = "building"
    /\ phase' = "extracted"
    /\ mention_tokens' = << >>
    /\ rewrites' = Append(rewrites, "cache_invalidation")
    /\ current_content' = "cache_notice"
    /\ msg_type' = "cache_invalidated"
    /\ UNCHANGED << original_content, original_has_mention >>

NextBuggy ==
    /\ \E agent \in AgentNames, has_mention \in BOOLEAN :
         StartBroadcast(agent, has_mention)
    \/ BroadcastRewriteSwallowsMention
    \/ \E label \in RewriteLabelSet : ApplyRewrite(label)
    \/ Deliver
    \/ SkipDedup

SpecBuggy == Init /\ [][NextBuggy]_vars

====
