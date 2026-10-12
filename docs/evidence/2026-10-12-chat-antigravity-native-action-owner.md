# Antigravity native action ownership

Base: `a0afe156de870e749d48470d35e70c250f88c089`.

Antigravity action observation now follows the existing first named native block
claim. Repeated Open/Closed starts, unnamed starts and starts after an unknown
finish do not create another semantic action. All received raw observations
remain recorded. MCP wrapper exclusion retains the existing exact_action rule.

Block publication precedes the action callback, protecting stream registration
before a yielding/reentrant observer can receive completion. Active Skill delivery
is still read by the existing callback at invocation, not snapshotted here.
There is no additional identity set or body heuristic.

The existing production projection test helper accepts an optional action
observer. A new registered behavioral case feeds repeat/closed/unknown-finish,
anonymous and wrapper events; it requires one built-in action and prior block
publication. This test was not executed. Interface, implementation and fixture
passed syntax-only parsing and whitespace checks. No Dune build, CI, formal
approval, installation or screenshot verification is claimed.

Independent source review requested. Claim-time Skill attribution and full
provider/runtime/UI proof remain incomplete. Skill ledger already deduplicates
within an activation, so this correction is about repeated callback admission,
not a claim that every previous duplicate was double-counted there.
