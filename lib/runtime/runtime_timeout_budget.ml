(** Timeout budget defaults: one owner for admission vs turn timeouts.

    This module is the single owner for the per-adapter defaults; each
    adapter aliases the budget rather than redeclaring a literal, and
    [Runtime_toml_providers] reads through it. ACP has no entry: none of
    its requests has a silence deadline. *)

let antigravity_default_turn_timeout_s = 300.0
let antigravity_default_admission_timeout_s = 300.0

let claude_default_turn_timeout_s = 300.0
let claude_default_admission_timeout_s = 300.0

let codex_default_turn_timeout_s = 300.0
let codex_default_admission_timeout_s = 300.0
