type gate_diff_tag =
  [ `Agree
  | `Legacy_allow_shadow_deny
  | `Legacy_deny_shadow_allow
  | `Shadow_cannot_parse
  ]

let gate_diff_total = Atomic.make 0
let gate_diff_agree = Atomic.make 0
let gate_diff_legacy_allow_shadow_deny = Atomic.make 0
let gate_diff_legacy_deny_shadow_allow = Atomic.make 0
let gate_diff_shadow_cannot_parse = Atomic.make 0
let auto_bg_observed = Atomic.make 0
let auto_bg_would_have_promoted = Atomic.make 0

let incr a = ignore (Atomic.fetch_and_add a 1)

let incr_gate_diff tag =
  incr gate_diff_total;
  match tag with
  | `Agree -> incr gate_diff_agree
  | `Legacy_allow_shadow_deny -> incr gate_diff_legacy_allow_shadow_deny
  | `Legacy_deny_shadow_allow -> incr gate_diff_legacy_deny_shadow_allow
  | `Shadow_cannot_parse -> incr gate_diff_shadow_cannot_parse

let incr_auto_bg_observed ~promoted_candidate =
  incr auto_bg_observed;
  if promoted_candidate then incr auto_bg_would_have_promoted

let reset () =
  Atomic.set gate_diff_total 0;
  Atomic.set gate_diff_agree 0;
  Atomic.set gate_diff_legacy_allow_shadow_deny 0;
  Atomic.set gate_diff_legacy_deny_shadow_allow 0;
  Atomic.set gate_diff_shadow_cannot_parse 0;
  Atomic.set auto_bg_observed 0;
  Atomic.set auto_bg_would_have_promoted 0

type snapshot = {
  gate_diff_total : int;
  gate_diff_agree : int;
  gate_diff_legacy_allow_shadow_deny : int;
  gate_diff_legacy_deny_shadow_allow : int;
  gate_diff_shadow_cannot_parse : int;
  auto_bg_observed : int;
  auto_bg_would_have_promoted : int;
}

let snapshot () =
  {
    gate_diff_total = Atomic.get gate_diff_total;
    gate_diff_agree = Atomic.get gate_diff_agree;
    gate_diff_legacy_allow_shadow_deny =
      Atomic.get gate_diff_legacy_allow_shadow_deny;
    gate_diff_legacy_deny_shadow_allow =
      Atomic.get gate_diff_legacy_deny_shadow_allow;
    gate_diff_shadow_cannot_parse =
      Atomic.get gate_diff_shadow_cannot_parse;
    auto_bg_observed = Atomic.get auto_bg_observed;
    auto_bg_would_have_promoted = Atomic.get auto_bg_would_have_promoted;
  }

let snapshot_to_json (s : snapshot) : Yojson.Safe.t =
  `Assoc [
    ("gate_diff_total", `Int s.gate_diff_total);
    ("gate_diff_agree", `Int s.gate_diff_agree);
    ("gate_diff_legacy_allow_shadow_deny",
     `Int s.gate_diff_legacy_allow_shadow_deny);
    ("gate_diff_legacy_deny_shadow_allow",
     `Int s.gate_diff_legacy_deny_shadow_allow);
    ("gate_diff_shadow_cannot_parse",
     `Int s.gate_diff_shadow_cannot_parse);
    ("auto_bg_observed", `Int s.auto_bg_observed);
    ("auto_bg_would_have_promoted", `Int s.auto_bg_would_have_promoted);
  ]
