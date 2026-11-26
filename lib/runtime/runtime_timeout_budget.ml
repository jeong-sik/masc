(** Timeout budget defaults: one owner for admission vs turn timeouts.

    The four adapters shipped four [default_timeout_s] literals (ACP 180s,
    others 300s) and, except for ACP, conflated the admission and turn
    budgets into the same value.  This module is the single owner for the
    per-adapter defaults; each adapter aliases the budget rather than
    redeclaring a literal, and [Runtime_toml_providers] reads through it. *)

let acp_default_turn_timeout_s = 180.0
let acp_default_admission_timeout_s = 30.0

let antigravity_default_turn_timeout_s = 300.0
let antigravity_default_admission_timeout_s = 300.0

let claude_default_turn_timeout_s = 300.0
let claude_default_admission_timeout_s = 300.0

let codex_default_turn_timeout_s = 300.0
let codex_default_admission_timeout_s = 300.0
