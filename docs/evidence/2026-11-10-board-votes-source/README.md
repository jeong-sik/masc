# Board votes source: Dashboard evidence

The Dashboard previously turned omitted vote fields into a known empty vote.
This change preserves the distinction between an unavailable voter observation
and a confirmed empty vote. The feed, full post, and comment show
`내 투표 확인 불가` and disable voting while the observation is unavailable.

The captures use real Chromium, the actual Dashboard components, and isolated
synthetic HTTP responses. Both PNGs were opened and visually inspected.
No live Board data or live backend write was used.

- [Unknown observation](unknown.png), [record](unknown.json): all six vote
  buttons are disabled and omit `aria-pressed`; an actual mouse click sends
  no vote request.
- [Known empty observation](known.png), [record](known.json): all six buttons
  begin enabled with `aria-pressed=false`. Clicking the feed Up button sends
  exactly one synthetic vote request; the actual Dashboard refresh path then
  renders the feed Up button pressed. The detail is a separate fixed fixture.

[manifest.json](manifest.json) retains the capture source pins, timestamps,
SHA-256 hashes, and Dashboard tree. The captured Dashboard tree
`6e0d31bc264147c2e1b97e1dd4d4ae0d9e30fd44` is identical after the delivery
restack onto `4f1ac0e89414b6f4ce668497e339cc03c40e71e3`.

The four focused frontend files passed 262 tests. Whole-Dashboard TypeScript
checking and targeted ESLint also passed. Four backend vote-source scenarios
are authored but were not executed. These captures do not establish an OCaml
build, vote-ledger durability, CI, installation, or deployment.
