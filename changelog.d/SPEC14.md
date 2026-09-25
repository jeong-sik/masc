### Documentation

- Spec 14 §3 (Keeper runtime selection): the paragraph predated RFC-0457/0458
  and said nothing about lanes. It now names `[runtime.assignments]` /
  `[runtime.lanes]`, `resolve_assignment`'s lane-first resolution, demotion
  of timeout/5xx/network-failed candidates until they answer (#36935), and
  declaration-order fallback when an assignment names a slot the lane no
  longer lists (#39037) (#<PR번호>).
