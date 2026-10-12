# Codex native action observation ownership

Base: `4d4ae1d41851e12319f0ab76b458542e11d7b71f`.

Review of the actual action consumer showed Skill ledger already deduplicates
identity within each activation. Repeated start events therefore do not blindly
count twice there. However each repeated start invokes the observer again using
the currently active delivery; a later activation has no prior record of that
identity and can receive a stale attribution.

Action observation now belongs to the existing native stream block claim. Only
a named identity first entering Open publishes an action observation. Replayed
Open/Closed starts remain in raw trace but do not call the semantic observer.
No additional identity set or body heuristic was added. Block start publishes
before action observation, so a yielding observer cannot allow a finish before
the bridge has seen the claimed block. Observers for unnamed or MCP-wrapper
observations still receive no invented action, through the existing exact_action
contract.

The native replay process fixture now collects action identities through the
actual Keeper run callback and requires native-1/native-2 once each despite
replayed starts. This fixture was not executed. Syntax-only parsing and whitespace
checks passed. No Dune build, CI, formal approval, installation or screenshot
verification is claimed. Independent source review requested.

Observer timing moves after block publication; active delivery is read by the
existing observer at invocation, not captured by a new protocol. Broader Skill
admission timing, other provider action paths and runtime/UI proof remain to be
verified. Previous scope-only statements about duplicate attribution are refined
by the actual ledger counterexample above.
