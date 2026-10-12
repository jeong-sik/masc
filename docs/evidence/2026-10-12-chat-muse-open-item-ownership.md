# Muse open item ownership

Base: `65eee3a7c024f844df3b9e830e9a1d0386d0a630`.

Review found a remaining path: repeated Item_started pushed duplicate open_items.
Item_completed removed one copy, allowing a subsequent text delta to find the
other copy and publish after completion. Repeated native starts also incremented
native call/open counters and emitted a second start for one identity.

Item_started now checks existing open ownership: same ID/kind is a no-op;
changed kind rejects before effects. Item_completed also rejects a kind change
of an open identity before dispatch. Completed agent text deltas reject before
looking up open ownership. No body heuristics or arbitrary retention caps added.

Wire fixtures were added for duplicate agent start followed by completion and
late text delta, plus duplicate native start retaining one call/start/finish.
These fixtures have not been executed. Syntax-only parsing and whitespace checks
passed; no Dune build, CI, formal approval, installed runtime or screenshot proof
is claimed. Independent review requested.

Completed native identities and delayed first completion chronology remain
separate incomplete boundaries. The overall chat goal remains active.
