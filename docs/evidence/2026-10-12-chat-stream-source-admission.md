# Scoped stream source admission precedes sequence publication

Base: 7a2079fd756d297db4e99daa28c536a4b3280e59.

Four parent projection fixtures failed: foreign operation Saying, exposed Thinking and Tool-start frames changed an owned response; a different autonomous turn changed the original autonomous response. They also published the foreign source's sequence (99), potentially suppressing later legitimate lower-sequence frames. RED: /tmp/chat-stream-source-admission-red-20261012.log.

The common entry boundary now checks an operation source against existing canonical delivery provenance using the producer/continuation relation, and autonomous source against its exact autonomous turn. It refuses mismatches before sequence acknowledgement, trace buffer creation or content publication. Initial unbound operation admission remains handled by the acceptance boundary. A positive fixture confirms an owning operation can append native continuation content without rewriting its exact continuation storage key.

The keeper-stream suite passed 109 tests; TypeScript noEmit exited 0 and diff check passed. Log: /tmp/chat-stream-source-admission-focused-20261012.log. These public projection counterexamples do not prove a live provider or wrapper routed them incorrectly. No actual provider/runtime/browser screenshots, CI, formal approval or installation evidence is claimed. Cross-domain initially unbound sources and actual installed continuity remain to be examined.
