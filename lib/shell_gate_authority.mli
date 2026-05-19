(** RFC-0131 PR-5 — per-caller authority flip for [Shell_command_gate].

    [MASC_SHELL_GATE_AUTHORITY] is an opt-in operator knob that promotes
    the {!Shell_command_gate.validate_allowlist} verdict to authoritative
    for the selected callers; the legacy {!Worker_dev_tools} path is
    retained only as a fallback on [Cannot_parse] (parser coverage gap).
    Unset / empty leaves every caller disabled — the rollback target in
    RFC-0131 §4.4 ("Unset [MASC_SHELL_GATE_AUTHORITY]") and the default
    posture until parity evidence over a rolling 7-day window says
    otherwise.

    Value is a comma-separated list of caller tags, matched
    case-insensitively after [String.trim]:

    {v
      worker_dev_tools  → matches [Shell_command_gate.Worker_dev_tools]
      tool_code_write   → matches [Shell_command_gate.Tool_code_write]
      keeper_shell_bash → matches [Shell_command_gate.Keeper_shell_bash]
      all               → matches every caller (test convenience)
    v}

    Tag names mirror the field shape of
    {!Legendary_counters.shell_gate_<caller>_<verdict>} so an operator
    reads the same identifier in both the env knob and the dashboard
    counter row.  Unknown tags are silently ignored; empty entries
    (e.g. trailing comma) are tolerated.

    Each call to {!authority_enabled} reads [Sys.getenv_opt] fresh.  An
    operator can flip a caller during a long-running session by
    exporting the env var in a new shell and signalling the daemon to
    re-read its environment; there is no in-process cache.  Per-test
    isolation comes from [Unix.putenv] / [Unix.unsetenv] in the test
    setup — see [test_shell_gate_authority.ml]. *)

val authority_enabled : Shell_command_gate.caller -> bool
(** [authority_enabled c] returns [true] when the operator has opted in
    to authority for caller [c] via [MASC_SHELL_GATE_AUTHORITY].  When
    [false], {!Worker_dev_tools.validate_command_coding_with_allowlist}
    keeps its legacy verdict regardless of the facade's parallel
    verdict (which is still emitted to
    {!Legendary_counters.incr_shell_gate} for parity measurement). *)
